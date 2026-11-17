#import "../template.typ": *

= The Peer-to-Peer Protocol <ch:p2p>

Decred nodes exchange blocks, transactions, addresses and a few kinds of
ephemeral state over a peer-to-peer network of TCP connections. This chapter
specifies that protocol: the framing of every message, the encoding of every
message type, the protocol versions and how two peers agree on one, the
connection handshake, how a node synchronizes the chain from its peers and
relays new data, and how the reference implementation manages connections and
punishes misbehaviour.

The wire protocol descends from Bitcoin's, and many command names are the
same, but the two are not interoperable and differ in ways that are easy to
miss: the message checksum uses BLAKE-256 rather than double SHA-256, unknown
commands are a bannable offence rather than being ignored, blocks are
announced by header, and there are Decred-specific messages for the stake
system, compact filters and coin mixing. Nothing in this chapter should be
inferred from Bitcoin's behaviour.

== Normative Status <sec:p2p-status>

The peer-to-peer protocol is not part of consensus. Whether a block is valid
never depends on how it was received, and two nodes that implement the
messages in this chapter differently will still agree on the chain as long as
they can exchange blocks. For that reason this chapter contains no rule boxes:
the numbered rules of this document are reserved for block validity.

The protocol is nevertheless a wire format, and a node that encodes a message
incorrectly, or sends one that its peer does not expect, will be disconnected
and usually banned by every node running the reference implementation. The
requirements in this chapter therefore come in two strengths:

- *Interoperability requirements*, written with #MUST and #MUSTNOT, describe
  what a peer has to do so that dcrd will talk to it: byte layouts, size
  limits, version gating and message ordering. Violating one of them causes
  dcrd to disconnect the peer and, in most cases, to ban its IP address for a
  day (@sec:p2p-misbehaviour).
- *Implementation behaviour*, described in ordinary prose and labelled as
  policy, records what dcrd itself chooses to do: how many peers it connects
  to, which peer it syncs from, when it requests data, how long it waits. An
  independent implementation is free to choose differently, but it should
  understand these choices because its peers will apply them to it.

Where dcrd tolerates input that it would never produce itself, the text says
so, since an implementation that wishes to interoperate with older or
unusual peers needs to know the exact boundaries.

== Transport <sec:p2p-transport>

Peers communicate over TCP. A connection carries a sequence of messages in
each direction; there is no other framing, no encryption and no
authentication at the protocol level. Connections to Tor onion services and
connections through SOCKS5 proxies are supported by the reference
implementation as a transport detail and do not change the protocol.

The party that opens the TCP connection is the *outbound* side and the party
that accepts it is the *inbound* side. The distinction matters for the
handshake (@sec:p2p-handshake) and for several policies, because the
addresses a node connects to itself are chosen by it, while inbound peers are
chosen by others and are treated with more suspicion.

Each network has a default TCP port and a four-byte *network magic* that
begins every message. A message whose magic does not match the local network
is rejected (@sec:p2p-envelope). The values are listed in
@tab:p2p-networks; the parameter tables of #chref("parameters") give them as
#param("DefaultPort") and #param("Net").

#figure(
  caption: [Network identifiers. The magic is a `uint32` serialized
    little-endian, so the bytes on the wire are the reverse of the hexadecimal
    value.],
  table(
    columns: (auto, auto, auto, auto),
    table.header([Network], [Magic (`uint32`)], [Bytes on the wire], [Default port]),
    [Main network], [`0xd9b400f9`], [`f9 00 b4 d9`], [9108],
    [Test network 3], [`0xb194aa75`], [`75 aa 94 b1`], [19108],
    [Simulation network], [`0x12141c16`], [`16 1c 14 12`], [18555],
    [Regression network], [`0xdab500fa`], [`fa 00 b5 da`], [18655],
  ),
) <tab:p2p-networks>

The simulation and regression networks are meant for private testing. On
those networks dcrd neither answers nor processes address messages and never
contacts seeders, so that they cannot grow into public networks.

== The Message Envelope <sec:p2p-envelope>

Every message consists of a fixed 24-byte header followed by a payload whose
length the header gives. The header layout is in @tab:p2p-header.

#fieldtable(
  caption: [Message header (#const("MessageHeaderSize") $= 24$ bytes)],
  ("magic", "uint32", "4", [Network magic from @tab:p2p-networks, little-endian.]),
  ("command", "char[12]", "12", [ASCII command name identifying the message type, padded on the right with `0x00` bytes to 12 bytes (#const("CommandSize")).]),
  ("length", "uint32", "4", [Length of the payload in bytes, little-endian.]),
  ("checksum", "byte[4]", "4", [The first four bytes of BLAKE-256 of the payload.]),
) <tab:p2p-header>

The checksum is computed as

$ "checksum" = "BLAKE256"("payload")[0:4], $

a single application of BLAKE-256 (#chref("crypto")) over exactly the
`length` payload bytes, keeping the first four bytes of the digest in the
order the hash function outputs them. An empty payload therefore has checksum
#hex("716f6e86"), the first four bytes of BLAKE-256 of the empty string.

#pitfall[
  Bitcoin uses the first four bytes of double SHA-256 here. Decred uses
  _single_ BLAKE-256. It is also not the hash used for block or transaction
  identifiers in any particular serialization; it is simply BLAKE-256 of the
  raw payload bytes.
]

=== Command Strings

A command name is between 1 and 12 bytes of printable ASCII. When sending, the
name is copied into the 12-byte field and the remainder is filled with zero
bytes. When receiving, dcrd strips trailing zero bytes and requires every
remaining byte to be in the *strict ASCII* range `0x20` to `0x7e` inclusive.
A command that contains a zero byte followed by a non-zero byte is therefore
malformed. Commands are case-sensitive and compared exactly; there is no
normalization. All command strings defined at the reference commit are listed
in @tab:p2p-messages.

=== Size Limits

Two limits bound a payload. The global limit #const("MaxMessagePayload") is
$32 times 1024 times 1024 = 33554432$ bytes. In addition, each message type has
its own maximum, which may depend on the negotiated protocol version; the
values at the current protocol version are in @tab:p2p-messages, and a value
of zero means that the message has no payload or is not valid at that
version. A sender #MUSTNOT send a payload that exceeds either limit, and the
receiver checks both _before_ reading the payload, using only the length in
the header, so that a peer cannot make it allocate memory for an oversized
message.

=== Receiving a Message <sec:p2p-receive>

@alg:p2p-read gives the complete sequence of checks dcrd applies when it reads
a message. The order matters for interoperability in one respect: the checks
in steps 1 to 5 happen before the payload is read, so after any of those
failures the stream position is unknown and the connection cannot continue.

#algorithm("Reading one message from a connection", src: "wire/message.go · ReadMessageN")[
  ```python
  MAX_MESSAGE_PAYLOAD = 32 * 1024 * 1024

  def read_message(stream, pver: uint32, net: uint32):
      hdr = stream.read_exact(24)                # EOF here: connection closed
      magic    = le32_decode(hdr[0:4])
      command  = hdr[4:16]
      length   = le32_decode(hdr[16:20])
      checksum = hdr[20:24]

      if length > MAX_MESSAGE_PAYLOAD:                    # 1
          fail(ErrPayloadTooLarge)
      if magic != net:                                    # 2
          fail(ErrWrongNetwork)
      name = command.rstrip(b"\x00")
      if any(b < 0x20 or b > 0x7e for b in name):         # 3
          fail(ErrMalformedCmd)
      if name not in KNOWN_COMMANDS:                      # 4 (empty name included)
          fail(ErrUnknownCmd)
      if length > max_payload_length(name, pver):         # 5
          fail(ErrPayloadTooLarge)

      payload = stream.read_exact(length)                 # short read: I/O error
      if blake256(payload)[0:4] != checksum:              # 6
          fail(ErrPayloadChecksum)
      msg, consumed = decode(name, payload, pver)         # 7: per-message rules
      if consumed != length:                              # 8
          fail(ErrTrailingBytes)
      return msg
  ```
] <alg:p2p-read>

Every failure labelled with an `Err...` name in @alg:p2p-read, and every
decoding failure of the same kind inside step 7 (an oversized count, a
non-canonical variable-length integer, a non-ASCII string, a message type that
is not valid at the negotiated version, and so on), is a *wire protocol
violation*. dcrd responds to a wire protocol violation by banning the remote
peer and closing the connection (@sec:p2p-misbehaviour). A payload that ends
before the decoder has read every field it needs is an ordinary I/O error: the
connection is closed but the peer is not banned. A read that waits longer than
the idle timeout also closes the connection (@sec:p2p-timeouts).

The payload must be consumed exactly: trailing bytes after the last field are
a violation, even in the `version` message whose optional fields would
otherwise suggest that extra data is tolerated.

#pitfall[
  *Unknown commands are fatal.* Bitcoin nodes ignore messages with commands
  they do not recognize. dcrd treats an unknown command as a wire protocol
  violation and bans the sender. This includes `reject`, which dcrd's message
  reader no longer recognizes at any protocol version (@sec:p2p-reject).
  Likewise, a known message that is not valid at the negotiated protocol
  version (for example `addr` after both peers have negotiated version 12)
  causes a ban. A node #MUSTNOT send any message type that the negotiated
  protocol version does not define.
]

#vector[Envelope of a payload-less message (`verack`, main network)][
  ```
  f9 00 b4 d9                                   magic 0xd9b400f9
  76 65 72 61 63 6b 00 00 00 00 00 00           "verack" + six 0x00
  00 00 00 00                                   length 0
  71 6f 6e 86                                   BLAKE-256("")[0:4]
  ```
]

#vector[Envelope of `ping` with nonce `0x1122334455667788` (main network)][
  ```
  f9 00 b4 d9                                   magic
  70 69 6e 67 00 00 00 00 00 00 00 00           "ping"
  08 00 00 00                                   length 8
  ec 16 34 63                                   checksum
  88 77 66 55 44 33 22 11                       payload: nonce (uint64 LE)
  ```
]

== Common Encodings <sec:p2p-encodings>

Integers in payloads are little-endian unless stated otherwise. The
variable-length integer (`varint`), length-prefixed byte string (`varbytes`)
and the block header and transaction serializations are defined in
#chref("encoding")\; in particular, a varint that could have been encoded in
fewer bytes is rejected as non-canonical, which here is a wire protocol
violation. This section defines the remaining building blocks that several
messages share.

=== Strings

A `varstring` is a varint length followed by that many bytes. Where a field
is described as *strict ASCII*, every byte of the string #MUST lie in
#box[`0x20`--`0x7e`]; this applies to the user agent of `version`, the requested
types of `getinitstate`, and the command and reason of the obsolete `reject`
message. A varstring length larger than #const("MaxMessagePayload") is
rejected before any allocation, and individual fields impose smaller limits
that are stated with each message.

=== Timestamps

Three timestamp encodings occur, all counting seconds since the Unix epoch:

- `uint32` timestamps, in the legacy network address (`addr` message).
- `int64` timestamps, in the `version` message.
- `uint64` timestamps, in the version 2 network address (`addrv2` message).

For the two 64-bit encodings the receiver reads the eight bytes as an
unsigned integer $t$ and rejects the message (a wire protocol violation) when
$t > 2^63 - 1 - 62135596800$, the largest value that still fits a signed
64-bit count of seconds after shifting the epoch to the year 1. In effect,
negative `int64` timestamps are also rejected.

=== Legacy Network Address <sec:p2p-netaddr>

The legacy network address, used by `addr` and by the two address fields of
`version`, can only describe IPv4 and IPv6 hosts. It has a timestamped form
(30 bytes) used in `addr`, and an untimestamped form (26 bytes) used in
`version`.

#fieldtable(
  caption: [Legacy network address (`NetAddress`)],
  ("timestamp", "uint32", "4", [Last time the address was seen. Present only in the timestamped form.]),
  ("services", "uint64", "8", [Service flags of the host (@tab:p2p-services).]),
  ("ip", "byte[16]", "16", [IPv6 address in network byte order. An IPv4 address $a.b.c.d$ is written as the IPv4-mapped IPv6 address `::ffff:a.b.c.d`, that is ten `0x00` bytes, two `0xff` bytes and the four IPv4 bytes.]),
  ("port", "uint16", "2", [TCP port, *big-endian*.]),
) <tab:p2p-netaddr>

#pitfall[
  The port of the legacy network address is big-endian while every other
  integer in the protocol is little-endian, and the port of the version 2
  address (@tab:p2p-netaddrv2) is little-endian. The legacy timestamp is a
  `uint32` and wraps in the year 2106.
]

=== Version 2 Network Address <sec:p2p-netaddrv2>

Protocol version 12 introduced a variable-length network address that also
carries Tor version 3 onion services. A one-byte type selects the length of
the encoded address.

#fieldtable(
  caption: [Version 2 network address (`NetAddressV2`)],
  ("timestamp", "uint64", "8", [Last time the address was seen, subject to the range check above.]),
  ("services", "uint64", "8", [Service flags of the host.]),
  ("type", "uint8", "1", [Address type from @tab:p2p-addrtypes.]),
  ("addr", "byte[n]", "4/16/32", [Encoded address; its length $n$ is fixed by the type.]),
  ("port", "uint16", "2", [TCP port, *little-endian*.]),
) <tab:p2p-netaddrv2>

#figure(
  caption: [Version 2 network address types],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Value], [Name], [Length], [Encoded address]),
    [0], [Unknown], [--], [Not encodable. Receiving it is a wire protocol violation (`ErrUnknownNetAddrType`).],
    [1], [IPv4], [4], [The four IPv4 address bytes in network order.],
    [2], [IPv6], [16], [The sixteen IPv6 address bytes in network order. #MUSTNOT be an IPv4-mapped address (see below).],
    [3], [Tor v3], [32], [The 32-byte Ed25519 public key of the onion service. The `.onion` name is the lowercase base32 encoding of `pubkey || checksum || 0x03`, where `checksum` is the first two bytes of SHA3-256 of the ASCII string `.onion checksum`, the public key and the byte `0x03`.],
    [4--255], [--], [--], [Reserved. Receiving any of them is a wire protocol violation.],
  ),
) <tab:p2p-addrtypes>

The type and the bytes have to agree in canonical form. When dcrd converts a
received address it reduces an address of type IPv6 that is an IPv4-mapped
address to its four-byte form and then finds that the derived type, IPv4, does
not match the claimed type; it bans the sender (@sec:p2p-addrv2).

=== Inventory Vectors <sec:p2p-invvect>

An *inventory vector* names one object a peer has, wants or does not have. It
is 36 bytes.

#fieldtable(
  caption: [Inventory vector (`InvVect`)],
  ("type", "uint32", "4", [Object type from @tab:p2p-invtypes.]),
  ("hash", "byte[32]", "32", [Identifier of the object in internal byte order (not the reversed display form).]),
) <tab:p2p-invvect>

#figure(
  caption: [Inventory types],
  table(
    columns: (auto, auto, 1fr),
    table.header([Value], [Name], [Meaning of the hash]),
    [0], [`ERROR`], [Unused.],
    [1], [`MSG_TX`], [Transaction hash (#chref("encoding")). Used for every kind of transaction, including tickets, votes, revocations and treasury transactions.],
    [2], [`MSG_BLOCK`], [Block hash.],
    [3], [`MSG_FILTERED_BLOCK`], [Defined but unused; dcrd never sends or serves it.],
    [4], [`MSG_MIX`], [Hash of a mixing message (#chref("mixing")). Valid from protocol version 10.],
  ),
) <tab:p2p-invtypes>

The wire decoder does not restrict the type field; the restrictions are
applied by the message handlers and are described with `inv`, `getdata` and
`notfound` in @sec:p2p-messages.

=== Block Locators <sec:p2p-locators>

A *block locator* is a list of block hashes that lets a peer find the most
recent block two nodes have in common without either knowing the other's
chain. It starts at a chosen block and walks back towards the genesis block,
densely at first and then with exponentially growing gaps, so its length grows
only logarithmically with the height. The `getheaders` and `getblocks`
messages carry a locator and a *stop hash*. A locator #MUSTNOT contain more
than #const("MaxBlockLocatorsPerMsg") $= 500$ hashes, a bound that the
construction below never approaches.

@alg:p2p-locator gives dcrd's construction. The first entry is the block
itself; the next eleven are its eleven immediate ancestors; after that the
distance between entries doubles each time; and the genesis block is always
the last entry. When the starting block is on a side chain, the walk follows
that side chain's ancestors.

#algorithm("Block locator construction", src: "internal/blockchain/chainview.go · blockLocator")[
  ```python
  def block_locator(node) -> list[Hash]:
      locator = []
      step = 1
      while True:
          locator.append(node.hash)
          if node.height == 0:            # genesis reached
              break
          height = max(node.height - step, 0)
          node = ancestor(node, height)   # ancestor on node's own branch
          if len(locator) > 10:           # after 11 entries, double the step
              step *= 2
      return locator
  ```
] <alg:p2p-locator>

#vector[Heights of the blocks in a locator, by starting height][
  ```
  start 0        : [0]
  start 5        : [5 4 3 2 1 0]
  start 12       : [12 11 10 9 8 7 6 5 4 3 2 1 0]
  start 13       : [13 12 11 10 9 8 7 6 5 4 3 2 0]
  start 1000000  : [1000000 999999 999998 999997 999996 999995 999994 999993
                    999992 999991 999990 999989 999987 999983 999975 999959
                    999927 999863 999735 999479 998967 997943 995895 991799
                    983607 967223 934455 868919 737847 475703 0]   (31 entries)
  ```
]

The responder interprets a locator against its own best chain with
@alg:p2p-locate. Two special cases are part of the protocol: an empty locator
is a request for the single block named by the stop hash, and a locator with no
hash on the responder's best chain is answered from the block after genesis.
A stop hash of all zeros, or any hash not on the best chain at or after the
starting point, imposes no limit other than the per-message maximum.

#algorithm("Resolving a locator and stop hash", src: "internal/blockchain/chain.go · locateInventory")[
  ```python
  def locate(locator: list[Hash], stop: Hash, max_entries: int) -> list[Node]:
      stop_node = lookup(stop)                 # any known header, or None
      if len(locator) == 0:
          return [] if stop_node is None else [stop_node]

      start = genesis
      for h in locator:                        # first hash on the best chain wins
          n = lookup(h)
          if n is not None and best_chain_contains(n):
              start = n
              break
      start = best_chain_next(start)           # block after the common one
      if start is None:                        # common block is the tip
          return []

      total = tip.height - start.height + 1
      if (stop_node is not None and best_chain_contains(stop_node)
              and stop_node.height >= start.height):
          total = stop_node.height - start.height + 1
      total = min(total, max_entries)
      return [best_chain_at(start.height + i) for i in range(total)]
  ```
] <alg:p2p-locate>

#note[
  With an empty locator the stop block is returned even if it is not on the
  best chain, because only the lookup, not best-chain membership, is checked
  in that branch.
]

== Protocol Versions and Services <sec:p2p-versions>

=== Version History

The protocol version is a small integer that each peer advertises in its
`version` message. It is incremented whenever a message is added, removed or
changed. @tab:p2p-pver lists every version defined by the reference
implementation and what it introduced.

#figure(
  caption: [Protocol versions],
  table(
    columns: (auto, auto, 1fr),
    table.header([Version], [dcrd name], [Change]),
    [1], [`InitialProcotolVersion`], [Initial protocol. (The name is misspelled in dcrd.)],
    [2], [`NodeBloomVersion`], [Adds the `SFNodeBloom` service flag. Bloom filtering was never implemented; the flag is unused.],
    [3], [`SendHeadersVersion`], [Adds `sendheaders`.],
    [4], [`MaxBlockSizeVersion`], [Raises the maximum `block` and `tx` payload from 1000000 to 1310720 bytes (#const("MaxBlockPayloadV3") to #const("MaxBlockPayload")).],
    [5], [`FeeFilterVersion`], [Adds `feefilter`.],
    [6], [`NodeCFVersion`], [Adds the `SFNodeCF` service flag and the version 1 committed filter messages `getcfilter`, `cfilter`, `getcfheaders`, `cfheaders`, `getcftypes`, `cftypes`.],
    [7], [`CFilterV2Version`], [Adds `getcfilterv2` and `cfilterv2`; the version 1 filter messages are deprecated from this version.],
    [8], [`InitStateVersion`], [Adds `getinitstate` and `initstate`, which replace `getminings` and `miningstate`.],
    [9], [`RemoveRejectVersion`], [Removes `reject`.],
    [10], [`MixVersion`], [Adds the eight mixing messages and inventory type `MSG_MIX`.],
    [11], [`BatchedCFiltersV2Version`], [Adds `getcfsv2` and `cfiltersv2`.],
    [12], [`AddrV2Version`], [Adds `addrv2` and removes `addr`. The handshake becomes strict: `verack` must immediately follow `version`.],
  ),
) <tab:p2p-pver>

The current version, #const("ProtocolVersion") in the wire package and the
maximum advertised by dcrd, is *12*. The *minimum version dcrd accepts* from a
peer is *9* (`RemoveRejectVersion`); a peer advertising anything lower is
disconnected during the handshake. Versions 1 to 8 therefore matter only for
reading the history; in particular, `reject`, `getminings` and `miningstate`
can never be validly exchanged with a current dcrd node. (dcrd's message
reader does not recognize `reject` at all, at any version, so it is treated
as an unknown command.)

=== Negotiation <sec:p2p-negotiation>

Each peer starts with its own maximum version as its working version. When it
receives the remote `version` message, it sets

$ "negotiated" = min("local maximum", "remote advertised"), $

and from that moment encodes and decodes every message at the negotiated
version. Both sides arrive at the same value because each computes the
minimum of the same two numbers. The one subtlety is the inbound side: dcrd
reads the remote `version` before writing its own, so the version an inbound
dcrd advertises is already the negotiated value rather than its maximum
(@sec:p2p-handshake). An implementation #MUST therefore not infer a peer's
maximum version from an inbound peer's `version` message.

The negotiated version determines, for each message type, whether it may be
sent at all and, for a few types, its maximum size. The gating is summarized
in the "Versions" column of @tab:p2p-messages.

=== Service Flags <sec:p2p-services>

The `services` field of `version` and of each network address is a 64-bit
bit field advertising optional capabilities.

#figure(
  caption: [Service flags],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Bit], [Value], [Name], [Meaning]),
    [0], [`0x1`], [`SFNodeNetwork`], [Full node: stores the full chain and serves blocks, headers and filters.],
    [1], [`0x2`], [`SFNodeBloom`], [Bloom filtering (never implemented; unused).],
    [2], [`0x4`], [`SFNodeCF`], [Version 1 committed filters (obsolete).],
  ),
) <tab:p2p-services>

dcrd advertises exactly `SFNodeNetwork`. It requires `SFNodeNetwork` of every
outbound peer and asks HTTPS seeders only for such peers; it does not require
any service of inbound peers. A peer without `SFNodeNetwork` is never chosen to
sync from and is skipped when relaying the early announcement of a new tip
block (@sec:p2p-relay-blocks). Unknown service bits are carried and stored but
otherwise ignored.

== The Connection Handshake <sec:p2p-handshake>

Before anything else, the two peers exchange `version` messages and
acknowledge each other's with `verack`. The handshake fixes the negotiated
protocol version and tells each side the other's services, best block height,
user agent and whether it wants transaction announcements.

=== The `version` Message <sec:p2p-version>

#fieldtable(
  caption: [`version` payload (maximum 358 bytes)],
  ("version", "int32", "4", [Protocol version of the sender: its maximum for an outbound sender, the negotiated value for an inbound dcrd sender.]),
  ("services", "uint64", "8", [Service flags of the sender.]),
  ("timestamp", "int64", "8", [Sender's current Unix time in seconds.]),
  ("addr_you", "NetAddress", "26", [Address of the receiver as seen by the sender, untimestamped form (@tab:p2p-netaddr).]),
  ("addr_me", "NetAddress", "26", [Address of the sender, untimestamped form. Optional on receipt.]),
  ("nonce", "uint64", "8", [Random value used to detect connections to self. Optional on receipt.]),
  ("user_agent", "varstring", "1+", [Software identification, strict ASCII, at most #const("MaxUserAgentLen") $= 256$ bytes. Optional on receipt.]),
  ("last_block", "int32", "4", [Height of the sender's best block. Optional on receipt.]),
  ("relay", "bool", "1", [`0x01` if the sender wants transaction and mix announcements, `0x00` if not. Any non-zero byte reads as true. Optional on receipt.]),
) <tab:p2p-version>

The maximum payload is $4 + 8 + 8 + 2 times 30 + 8 + 9 + 256 + 4 + 1 = 358$
bytes (the limit uses the 30-byte timestamped address size and the 9-byte
maximum varint, so it exceeds the largest encodable message, 344 bytes).

*Decoding.* The first four fields are mandatory. Each of the remaining fields,
in order, is decoded only if at least one byte of the payload remains, and a
field that is absent takes the value zero (empty user agent, `relay` true).
Once a field has started it must be complete: a payload that ends inside a
field is an I/O error. After the last field nothing may remain. A user agent
that is longer than 256 bytes or contains a byte outside #box[`0x20`--`0x7e`] is a
wire protocol violation. The receiver ignores `addr_me` and the services in
`addr_you`; it uses only the IP address and port of `addr_you` for discovering
its own external address (@sec:p2p-external).

A sender #MUST include all nine fields. The optional-field decoding exists only
for compatibility with very old software.

*What dcrd sends.* dcrd fills the fields as follows:

- `version`: 12 when outbound; the negotiated version when inbound.
- `services`: `SFNodeNetwork`.
- `timestamp`: the local clock, whole seconds.
- `addr_you`: the remote IP address and port of the connection with the
  remote peer's services (zero for outbound connections, whose services are
  not yet known). When dcrd connects through a proxy and the address would
  otherwise reveal the proxy, it sends the IPv4 address `0.0.0.0` and port 0
  instead. For an outbound connection to a Tor onion service, which has no IP
  address, the 16 IP bytes are all zero.
- `addr_me`: services `SFNodeNetwork`, IP address all zeros, port 0. The local
  address is advertised separately with an address message, because a
  connection from a node does not prove that the node accepts connections.
- `nonce`: a fresh random 64-bit value per connection. dcrd remembers the 50
  most recent nonces it has sent.
- `user_agent`: a sequence of `/name:version/` components, oldest layer first.
  The wire library contributes `/dcrwire:1.0.0/` and dcrd appends
  `dcrd:MAJOR.MINOR.PATCH/`, adding `(comment; comment)` before the closing
  slash for a pre-release tag. At the reference commit the string is
  `/dcrwire:1.0.0/dcrd:2.2.0(pre)/`. The format is a convention; receivers do
  not parse it.
- `last_block`: the height of the local best chain tip.
- `relay`: false only when dcrd runs in blocks-only mode, true otherwise.

=== Validation of the Remote `version` <sec:p2p-version-checks>

When dcrd receives the first message on a connection it applies the following
checks in order. Any failure aborts the handshake and closes the connection;
none of them leads to a ban unless the message was also a wire protocol
violation.

+ The message #MUST be a `version` message.
+ Its nonce #MUSTNOT be one of the 50 nonces most recently sent by the local
  node; otherwise the connection is to the node itself.
+ The negotiated version is set as in @sec:p2p-negotiation, and the remote
  services, best height, user agent and clock offset are recorded.
+ For outbound connections on the main and test networks, the services
  recorded for the address in the address manager are updated. This happens
  even if the peer is rejected below.
+ The advertised version #MUST be at least 9.
+ *Policy, outbound only.* dcrd wants at least $min(3, T)$ of its outbound
  peers to support mixing (version 10 or later), where $T$ is the target
  number of outbound peers (8 by default). It rejects an outbound peer with a
  version below 10 when it has fewer such peers than that and accepting the
  peer would leave too few free outbound slots to reach the quota, that is
  when $"outbound" + min(3, T) >= T$.
+ *Policy, outbound only.* The peer #MUST advertise `SFNodeNetwork`.

If all checks pass, the receiver records `addr_you` as a candidate for its own
external address, notes whether the peer disabled relay, and adds the remote
`timestamp` to the network time samples (@sec:p2p-adjtime).

=== Message Order <sec:p2p-handshake-order>

The outbound side speaks first. The full sequence, as seen on the wire, is in
@tab:p2p-handshake.

#figure(
  caption: [Handshake order. A peer sends `verack` only after it has accepted the
    other side's `version`.],
  table(
    columns: (auto, auto, 1fr),
    table.header([Step], [Direction], [Message and condition]),
    [1], [outbound #sym.arrow.r inbound], [`version` (outbound peer's maximum version).],
    [2], [inbound #sym.arrow.r outbound], [`version` (negotiated version), sent after the inbound side validated step 1.],
    [3], [inbound #sym.arrow.r outbound], [`verack`, sent immediately after step 2.],
    [4], [outbound #sym.arrow.r inbound], [`verack`, sent after the outbound side validated step 2 and received step 3.],
  ),
) <tab:p2p-handshake>

The rules each side enforces are:

- The first message received #MUST be `version`.
- At a negotiated version of 12, the second message received #MUST be
  `verack`. At negotiated versions 9 to 11, dcrd reads up to three messages
  looking for the `verack`; up to two other messages may precede it, and they
  are buffered and processed, in order, after the handshake completes. If the
  third message is not `verack` the handshake fails.
- The whole handshake #MUST complete within 30 seconds of its start
  (`negotiateTimeout`); each individual read is also subject to the idle
  timeout.
- After the handshake, a second `version` or a second `verack` causes an
  immediate disconnect.

A node that receives a `version` it does not accept simply closes the
connection without sending `verack` or any explanation. There is no
negative-acknowledgement message.

=== After the Handshake <sec:p2p-post-handshake>

As soon as the handshake succeeds, dcrd sends or schedules the following,
which an implementation should expect to receive right away:

+ `sendheaders`, to every peer, asking for block announcements as headers.
+ For outbound peers on the main and test networks: an `addr` or `addrv2`
  (by negotiated version) containing the local node's best external address,
  if the node accepts inbound connections, believes it is synced, and the
  address is routable; then `getaddr` if the address manager holds fewer than
  1000 addresses.
+ `getheaders`, to discover the peer's best chain (@sec:p2p-sync). During the
  initial header sync it is sent only to the chosen sync peer; afterwards it
  is sent to every new peer that advertises `SFNodeNetwork`.
+ `getinitstate` (at version 8 or later), once the local node believes it is
  synced, to learn the current tip candidates, their votes and the treasury
  spends in the remote mempool (@sec:p2p-initstate).
+ `ping` every 107 seconds thereafter.

=== Network-Adjusted Time <sec:p2p-adjtime>

The `timestamp` of each accepted `version` message is a sample of the remote
peer's clock. dcrd combines these samples into an offset that is added to the
local clock to form the *network-adjusted time*, which the block validation
code uses when it compares header timestamps against the present
(#chref("blocks")). The procedure, @alg:p2p-adjtime, deliberately reproduces a
quirk of Bitcoin Core: the offset is recomputed only when the number of samples
is odd, and the sample limit, 200, is even, so once 200 samples have been
collected the offset never changes again for the life of the process.

#algorithm("Adding a time sample", src: "internal/blockchain/mediantime.go · AddTimeSample")[
  ```python
  MAX_ENTRIES = 200
  MAX_OFFSET  = 70 * 60          # seconds
  offsets = []                   # in arrival order
  known_sources = set()
  offset_secs = 0                # current adjustment

  def add_time_sample(source_id: str, remote_time: int):
      global offset_secs
      if source_id in known_sources:       # one sample per remote "host:port"
          return
      known_sources.add(source_id)
      offset = tdiv_seconds(remote_time - now_seconds())   # truncated to seconds
      if len(offsets) == MAX_ENTRIES:
          offsets.pop(0)                   # drop the oldest
      offsets.append(offset)
      n = len(offsets)
      if n < 5 or n % 2 != 1:
          return
      median = sorted(offsets)[n // 2]
      offset_secs = median if abs(median) < MAX_OFFSET else 0

  def adjusted_time() -> int:
      return now_seconds() + offset_secs
  ```
] <alg:p2p-adjtime>

=== Worked Example <sec:p2p-example>

The following `version` message was produced by dcrd's wire package. The
sender advertises protocol version 12 and `SFNodeNetwork`, its clock reads
2025-01-01T00:00:00Z (`0x67748580`), it sees the receiver at `192.0.2.10`
port 9108, its nonce is `0x0123456789abcdef`, its user agent is that of dcrd
at the reference commit, its best height is 1000000 and it wants transaction
announcements.

#vector[`version` payload (117 bytes)][
  ```
  0c 00 00 00                                     version = 12
  01 00 00 00 00 00 00 00                         services = SFNodeNetwork
  80 85 74 67 00 00 00 00                         timestamp = 1735689600
  00 00 00 00 00 00 00 00                         addr_you.services = 0
  00 00 00 00 00 00 00 00 00 00 ff ff c0 00 02 0a addr_you.ip = ::ffff:192.0.2.10
  23 94                                           addr_you.port = 9108 (big-endian)
  01 00 00 00 00 00 00 00                         addr_me.services = SFNodeNetwork
  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 addr_me.ip = ::
  00 00                                           addr_me.port = 0
  ef cd ab 89 67 45 23 01                         nonce = 0x0123456789abcdef
  1f                                              user_agent length = 31
  2f 64 63 72 77 69 72 65 3a 31 2e 30 2e 30 2f    "/dcrwire:1.0.0/"
  64 63 72 64 3a 32 2e 32 2e 30 28 70 72 65 29 2f "dcrd:2.2.0(pre)/"
  40 42 0f 00                                     last_block = 1000000
  01                                              relay = true
  ```
]

#vector[`version` header (main network) and checksum][
  ```
  BLAKE-256(payload) = 588c8c560b1ab70e42bfad8f39b53db8d1dad0004115631aec8156d73b52a4dd

  f9 00 b4 d9                                     magic
  76 65 72 73 69 6f 6e 00 00 00 00 00             "version"
  75 00 00 00                                     length = 117
  58 8c 8c 56                                     checksum = digest[0:4]
  ```
  The complete 141-byte message is the header followed by the payload above.
]

== Message Reference <sec:p2p-messages>

@tab:p2p-messages lists every command defined at the reference commit. The
"Versions" column gives the range of negotiated protocol versions at which the
wire layer accepts the message; outside that range sending it is a wire
protocol violation. The "Max payload" column is the per-type limit at version
12, or at the last version at which the message is valid.

#figure(
  caption: [Message types. "Sent" and "Handled" describe dcrd's behaviour:
    whether it ever originates the message, and what it does on receipt.],
  table(
    columns: (auto, auto, auto, auto, 1fr),
    table.header([Command], [Versions], [Max payload], [Sent], [Handled on receipt]),
    [`version`], [all], [358], [yes], [Handshake only; later: disconnect.],
    [`verack`], [all], [0], [yes], [Handshake only; later: disconnect.],
    [`getaddr`], [all], [0], [yes], [Answered once, inbound peers only.],
    [`addr`], [1--11], [30003], [yes], [Stored in the address manager.],
    [`addrv2`], [12--], [51003], [yes], [Stored in the address manager.],
    [`inv`], [all], [1800003], [yes], [Requests needed transactions and mix messages.],
    [`getdata`], [all], [1800003], [yes], [Served asynchronously.],
    [`notfound`], [all], [1800003], [yes], [Clears requests; ban score.],
    [`getblocks`], [all], [16039], [no], [Answered with `inv` (legacy).],
    [`getheaders`], [all], [16039], [yes], [Answered with `headers`.],
    [`headers`], [all], [362003], [yes], [Header sync and announcements.],
    [`block`], [all], [1310720], [yes], [Processed only if requested.],
    [`tx`], [all], [1310720], [yes], [Processed (also if unsolicited).],
    [`mempool`], [all], [0], [no], [Answered with `inv`; ban score.],
    [`ping`], [all], [8], [yes], [Answered with `pong`.],
    [`pong`], [all], [8], [no#super[a]], [Updates round-trip statistics.],
    [`sendheaders`], [3--], [0], [yes], [Switches announcements to headers.],
    [`feefilter`], [5--], [8], [no], [Ignored.],
    [`reject`], [none#super[c]], [--], [no], [Unknown command: ban.],
    [`getminings`], [all#super[b]], [0], [no], [Ban.],
    [`miningstate`], [all#super[b]], [1546], [no], [Ban.],
    [`getinitstate`], [8--], [1057], [yes], [Answered once with `initstate`.],
    [`initstate`], [8--], [1763], [yes], [Requests the advertised data, once.],
    [`getcfilterv2`], [7--], [32], [no], [Answered with `cfilterv2`.],
    [`cfilterv2`], [7--], [263210], [yes], [Ignored (dcrd never requests it).],
    [`getcfsv2`], [11--], [64], [no], [Answered with `cfiltersv2`.],
    [`cfiltersv2`], [11--], [26321001], [yes], [Ignored (dcrd never requests it).],
    [`getcfilter`], [6--#super[b]], [33], [no], [Ban.],
    [`cfilter`], [6--#super[b]], [262182], [no], [Ignored.],
    [`getcfheaders`], [6--#super[b]], [16036], [no], [Ban.],
    [`cfheaders`], [6--#super[b]], [64036], [no], [Ignored.],
    [`getcftypes`], [6--#super[b]], [0], [no], [Ban.],
    [`cftypes`], [6--#super[b]], [259], [no], [Ignored.],
    [`mixpairreq`], [10--], [8476848], [yes], [#chref("mixing").],
    [`mixkeyxchg`], [10--], [17815], [yes], [#chref("mixing").],
    [`mixcphrtxt`], [10--], [552584], [yes], [#chref("mixing").],
    [`mixslotres`], [10--], [17318030], [yes], [#chref("mixing").],
    [`mixfactpoly`], [10--], [49291], [yes], [#chref("mixing").],
    [`mixdcnet`], [10--], [20988047], [yes], [#chref("mixing").],
    [`mixconfirm`], [10--], [1016520], [yes], [#chref("mixing").],
    [`mixsecrets`], [10--], [70831], [yes], [#chref("mixing").],
  ),
) <tab:p2p-messages>

#text(size: 8.6pt)[
  #super[a] dcrd sends `pong` only in reply to `ping`. #h(0.6em)
  #super[b] Accepted by the wire layer at these versions but not acted on by
  dcrd at any version it negotiates: `getminings`, `miningstate` and the
  three version 1 filter requests are answered with a ban (a plain disconnect
  if banning is disabled), and the three version 1 filter replies are
  ignored; see the individual entries.
  #h(0.6em)
  #super[c] Defined for versions 1--8 (maximum payload
  #const("MaxMessagePayload")), but dcrd's message reader has no decoder for
  it and reports an unknown command at every version.
]

The remainder of this section specifies each message. Unless a message is
described as having no payload, its payload is exactly the fields listed, in
order.

=== `getaddr` <sec:p2p-getaddr>

Requests known peer addresses. No payload.

dcrd sends `getaddr` to outbound peers after the handshake when its address
manager holds fewer than 1000 addresses. It answers a `getaddr` only if the
request comes from an inbound peer, only the first time on that connection,
and never on the simulation and regression networks; otherwise it silently
ignores it. The answer is an `addr` (versions 9 to 11) or `addrv2` (version
12) message described in @sec:p2p-addr-relay. A requester should not expect a
reply.

=== `addr` <sec:p2p-addr>

Announces peer addresses using the legacy encoding. Valid only at negotiated
versions below 12.

#fieldtable(
  caption: [`addr` payload (maximum 30003 bytes)],
  ("count", "varint", "1-3", [Number of addresses, at most #const("MaxAddrPerMsg") $= 1000$.]),
  ("addresses", "NetAddress[count]", "30 each", [Timestamped legacy addresses (@tab:p2p-netaddr).]),
) <tab:p2p-addr>

An `addr` with zero addresses decodes successfully but dcrd bans its sender.
Receipt is described in @sec:p2p-addr-relay.

=== `addrv2` <sec:p2p-addrv2>

Announces peer addresses using the version 2 encoding. Valid only at
negotiated version 12 or later.

#fieldtable(
  caption: [`addrv2` payload (maximum 51003 bytes)],
  ("count", "varint", "1-3", [Number of addresses, from 1 to #const("MaxAddrPerV2Msg") $= 1000$. Zero is a wire protocol violation.]),
  ("addresses", "NetAddressV2[count]", "21-51 each", [Version 2 addresses (@tab:p2p-netaddrv2).]),
) <tab:p2p-addrv2>

The per-type limit assumes the largest address (51 bytes, Tor v3). On
receipt, every address is converted to canonical form; if the type does not
match the canonical form of the bytes (an IPv4-mapped address sent as type
IPv6) the whole message is discarded and the sender is banned.

#vector[`addrv2` payload with an IPv4 and an IPv6 address][
  ```
  02                                              count = 2
  80 85 74 67 00 00 00 00                         timestamp = 1735689600 (uint64)
  01 00 00 00 00 00 00 00                         services = SFNodeNetwork
  01                                              type = IPv4
  c0 00 02 0a                                     192.0.2.10
  94 23                                           port = 9108 (little-endian)
  80 85 74 67 00 00 00 00                         timestamp
  01 00 00 00 00 00 00 00                         services
  02                                              type = IPv6
  20 01 0d b8 00 00 00 00 00 00 00 00 00 00 00 01 2001:db8::1
  94 23                                           port = 9108
  ```
]

=== `inv` <sec:p2p-inv>

Announces objects the sender has.

#fieldtable(
  caption: [`inv`, `getdata` and `notfound` payload (maximum 1800003 bytes)],
  ("count", "varint", "1-3", [Number of inventory vectors, at most #const("MaxInvPerMsg") $= 50000$.]),
  ("inventory", "InvVect[count]", "36 each", [Inventory vectors (@tab:p2p-invvect).]),
) <tab:p2p-inv>

dcrd announces transactions and mixing messages with `inv`. It never announces
blocks with `inv` to a peer that sent `sendheaders`, which every dcrd peer
does; it does still produce block inventory in answer to `getblocks`.

On receipt, an empty `inv` causes a ban. Otherwise each vector is processed
by type:

- `MSG_TX`: recorded as known to the peer. If the local node believes it is
  synced and needs the transaction (@sec:p2p-relay-tx), it is requested with
  `getdata`.
- `MSG_MIX`: likewise for mixing messages.
- `MSG_BLOCK`: recorded as known to the peer, and the last such vector is
  used to update the peer's best announced block. Nothing is requested;
  blocks are fetched on the basis of headers.
- Any other type: ignored.

In blocks-only mode, dcrd disconnects a peer that announces a transaction or
mixing message, since it told the peer in its `version` not to.

=== `getdata` <sec:p2p-getdata>

Requests objects by inventory vector. The payload has the same layout as
`inv` (@tab:p2p-inv). The responder sends, for each vector it can serve and
in the order requested, a `tx`, `block` or mixing message, and then a single
`notfound` listing every vector it could not serve.

dcrd serves:

- `MSG_TX` from a cache of transactions it announced in the last 45 seconds
  (up to 4500 entries), falling back to its mempool. Transactions already
  mined into blocks are not served unless they happen to still be in that
  cache.
- `MSG_BLOCK` for any block whose data it has, on the best chain or not.
- `MSG_MIX` from the mixing pool's recent messages.

A vector with any other type is skipped with no response at all, not even a
`notfound`. An empty `getdata` causes a ban.

*Limits (policy).* dcrd serves `getdata` asynchronously but bounds the work a
peer can queue. Each request adds $floor(99 n \/ 50000)$ to the peer's
decaying ban score, where $n$ is the number of vectors. A request for fewer
than 506 objects therefore adds nothing, while requesting about 50000 objects
twice within a minute crosses the ban threshold. A
peer is disconnected (not banned) when accepting a new `getdata` would leave
more than 1000 of its `getdata` messages, or more than 100000 individual
objects, waiting to be served.

=== `notfound` <sec:p2p-notfound>

Lists requested objects the sender does not have. Same layout as `inv`
(@tab:p2p-inv).

dcrd sends `notfound` as described under `getdata`. On receipt, a vector with a
type other than `MSG_TX`, `MSG_BLOCK` or `MSG_MIX` causes a disconnect. For
the others, the receiver removes the matching outstanding requests to that
peer so the objects can be fetched elsewhere, and increases the peer's ban
score: by 20 *persistent* points per block, and by 10 *decaying* points per
transaction or mixing message. Because the block penalty never decays, a
peer is banned at the latest when it has listed a sixth block in `notfound`
messages over the life of the connection.

=== `getblocks` <sec:p2p-getblocks>

Requests the hashes of best-chain blocks following a locator. This is the
legacy synchronization mechanism; dcrd never sends it but still answers it.

#fieldtable(
  caption: [`getblocks` and `getheaders` payload (maximum 16039 bytes)],
  ("version", "uint32", "4", [Protocol version of the requester. Ignored by the receiver; dcrd sends 0 in `getheaders`.]),
  ("count", "varint", "1-3", [Number of locator hashes, at most 500.]),
  ("locator", "byte[32][count]", "32 each", [Block locator (@sec:p2p-locators).]),
  ("stop", "byte[32]", "32", [Stop hash; all zeros for no stop.]),
) <tab:p2p-getblocks>

The response is a single `inv` with up to #const("MaxBlocksPerMsg") $= 500$
block vectors for the blocks returned by @alg:p2p-locate, omitting blocks the
requester is already known to have. If no vectors remain, nothing is sent.

When the response contains exactly 500 vectors, dcrd remembers the last
hash. When the requester later asks for that block with `getdata`, dcrd sends
the block followed by an `inv` containing the single hash of its current best
block, which prompts a legacy client to send the next `getblocks`.

=== `getheaders` <sec:p2p-getheaders>

Requests the headers of best-chain blocks following a locator. The payload is
identical to `getblocks` (@tab:p2p-getblocks).

The response is always exactly one `headers` message, possibly empty, with
the headers of the blocks returned by @alg:p2p-locate with a maximum of
#const("MaxBlockHeadersPerMsg") $= 2000$. If the cumulative proof of work of
the responder's own best chain is below the network's minimum known chain
work (#param("MinKnownChainWork")), it answers with an empty `headers`
message instead, because its chain is evidently not yet synced and its
headers would be of no use.

dcrd suppresses a `getheaders` it is about to send if its first locator hash
and stop hash equal those of the previous `getheaders` it sent to the same
peer.

=== `headers` <sec:p2p-headers>

Delivers block headers, in answer to `getheaders` or unsolicited as a block
announcement.

#fieldtable(
  caption: [`headers` payload (maximum 362003 bytes)],
  ("count", "varint", "1-3", [Number of headers, at most 2000.]),
  ("headers", "entry[count]", "181 each", [Each entry is a 180-byte serialized block header (#chref("encoding")) followed by a varint transaction count that #MUST be zero (a single `0x00` byte).]),
) <tab:p2p-headers>

A non-zero transaction count is a wire protocol violation. How the receiver
processes headers is the core of synchronization and is specified in
@sec:p2p-headers-processing.

=== `block` <sec:p2p-block>

Delivers a full block, serialized as in #chref("encoding"). The maximum
payload is #const("MaxBlockPayload") $= 1310720$ bytes (1000000 at versions
3 and below), and each of the two transaction trees may contain at most
$floor(floor(1310720 \/ 15) \/ 2) + 1 = 43691$ transactions (33334 at versions
3 and below), where 15 is the size of the smallest possible transaction. A
count above that bound is a wire protocol violation. These are wire limits
only; the consensus size limit is stricter (#chref("blocks")).

dcrd processes a `block` only if it requested that block from that peer; an
unrequested block causes an immediate disconnect. There is consequently no
unsolicited block propagation in Decred: new blocks are announced by header
and fetched by `getdata`.

=== `tx` <sec:p2p-tx>

Delivers one transaction, serialized as in #chref("encoding"), with maximum
payload 1310720 bytes (1000000 at versions 3 and below).

For historical reasons dcrd accepts unsolicited transactions: a `tx` that was
not requested is processed like any other. Transactions are submitted to the
mempool, whose acceptance rules are in #chref("policy")\; rejected
transactions are remembered (in a probabilistic filter of about 62500 entries)
and neither requested nor reprocessed until the next block extends the best
chain. In blocks-only mode received transactions are ignored.

=== `mempool` <sec:p2p-mempool>

Requests announcements of the responder's mempool. No payload.

dcrd responds by queuing an `inv` announcement for every transaction in its
mempool through the normal trickling mechanism (@sec:p2p-trickle), skipping
transactions the requester is known to have. Each `mempool` adds 33 to the
sender's decaying ban score, so more than three in quick succession lead to a
ban. dcrd never sends `mempool`.

=== `ping` and `pong` <sec:p2p-ping>

#fieldtable(
  caption: [`ping` and `pong` payload (8 bytes)],
  ("nonce", "uint64", "8", [Arbitrary value chosen by the sender of `ping` and echoed in `pong`.]),
) <tab:p2p-ping>

A peer #MUST answer every `ping` with a `pong` carrying the same nonce. dcrd
sends a `ping` with a random nonce every 107 seconds (the default idle timeout
of 120 seconds less 13), so that an otherwise idle but healthy connection
always has traffic before the idle timeout expires. A `pong` whose nonce
matches the most recent outstanding `ping` updates the round-trip statistics;
any other `pong` is ignored. dcrd does not set a response deadline for `ping`.

=== `sendheaders` <sec:p2p-sendheaders>

Asks the receiver to announce new blocks with `headers` messages instead of
`inv`. No payload. Valid from version 3.

dcrd sends `sendheaders` to every peer immediately after the handshake and
honours it from any peer for the rest of the connection.

=== `feefilter` <sec:p2p-feefilter>

#fieldtable(
  caption: [`feefilter` payload (8 bytes)],
  ("min_fee", "int64", "8", [Minimum fee rate, in atoms per kilobyte, below which the sender does not want transaction announcements.]),
) <tab:p2p-feefilter>

Valid from version 5. dcrd neither sends `feefilter` nor acts on it: a
received `feefilter` is decoded and discarded, and transaction announcements
are not filtered by fee.

=== `reject` (obsolete) <sec:p2p-reject>

Defined only for versions below 9 (`RemoveRejectVersion`), and therefore
never at a version dcrd negotiates. In fact dcrd's message reader no longer
maps the command string `reject` to any message type, so a received `reject`
fails with an unknown-command violation at every protocol version, before its
length or payload is examined, and leads to a ban. The layout, which the wire
library can still encode and decode at versions 1 to 8, is given for
completeness.

#fieldtable(
  caption: [`reject` payload (versions 1 to 8; maximum #const("MaxMessagePayload"))],
  ("command", "varstring", "1+", [Command of the rejected message, strict ASCII.]),
  ("code", "uint8", "1", [Reason code: `0x01` malformed, `0x10` invalid, `0x11` obsolete, `0x12` duplicate, `0x40` non-standard, `0x41` dust, `0x42` insufficient fee, `0x43` checkpoint.]),
  ("reason", "varstring", "1+", [Human-readable reason, strict ASCII.]),
  ("hash", "byte[32]", "0 or 32", [Present only when `command` is `block` or `tx`: the hash of the rejected object.]),
) <tab:p2p-reject>

=== `getinitstate` and `initstate` <sec:p2p-initstate>

These two messages, introduced at version 8, let a node that has just come
online learn ephemeral state that is not part of the chain: which blocks at
the tip are currently viable to build on, the votes cast on them, and the
treasury spend transactions awaiting votes. Without them a miner would have to
wait for the next block, and a voting wallet for new treasury spends to be
relayed, before learning this information.

#fieldtable(
  caption: [`getinitstate` payload (maximum 1057 bytes)],
  ("count", "varint", "1", [Number of requested types, at most #const("MaxInitStateTypes") $= 32$.]),
  ("types", "varstring[count]", "1-33 each", [Requested types: strict ASCII strings of at most #const("MaxInitStateTypeLen") $= 32$ bytes each.]),
) <tab:p2p-getinitstate>

#figure(
  caption: [Initial state types],
  table(
    columns: (auto, 1fr),
    table.header([Type string], [Requested data]),
    [`headblocks`], [Hashes of the blocks at the tip's height (the tip and any competing chain tips) that have enough votes to be built upon.],
    [`headblockvotes`], [Hashes of the votes for those blocks.],
    [`tspends`], [Hashes of the treasury spend transactions in the responder's mempool.],
  ),
) <tab:p2p-initstate-types>

#fieldtable(
  caption: [`initstate` payload (maximum 1763 bytes)],
  ("block_count", "varint", "1", [Number of block hashes, at most #const("MaxISBlocksAtHeadPerMsg") $= 8$.]),
  ("blocks", "byte[32][block_count]", "32 each", [Block hashes.]),
  ("vote_count", "varint", "1", [Number of vote hashes, at most #const("MaxISVotesAtHeadPerMsg") $= 40$.]),
  ("votes", "byte[32][vote_count]", "32 each", [Vote transaction hashes.]),
  ("tspend_count", "varint", "1", [Number of treasury spend hashes, at most #const("MaxISTSpendsAtHeadPerMsg") $= 7$.]),
  ("tspends", "byte[32][tspend_count]", "32 each", [Treasury spend transaction hashes.]),
) <tab:p2p-initstate>

*Requesting.* dcrd sends one `getinitstate` per connection, when the local
node first believes it is synced (immediately for peers that connect after
that point). It always requests `tspends` and, unless mining state
synchronization is disabled by configuration, also `headblocks` and
`headblockvotes`, in the order `tspends`, `headblocks`, `headblockvotes`. It
expects the `initstate` within the stall timeout (@sec:p2p-timeouts) and
disconnects a peer that does not answer.

*Responding.* A peer #MUSTNOT send more than one `getinitstate` per
connection; dcrd bans a peer that does. Unknown type strings are ignored and
duplicate strings are harmless. dcrd answers as follows:

- If its best chain height is below #param("StakeValidationHeight") $- 1$, an
  `initstate` with all three lists empty.
- Otherwise, if `headblocks` or `headblockvotes` was requested, it takes the
  current tip and every other known chain tip at the same height, keeps those for which its mempool holds at least
  $floor(#param("TicketsPerBlock") \/ 2) + 1$ votes (3 on the main network),
  sorts them by number of votes, most first (the order among equal counts is
  unspecified, except that if the current tip has as many votes as the first
  entry it is swapped into first place), and truncates the list to 8. If `headblockvotes`
  was requested, the vote hashes for every block in that list are
  concatenated in list order. The block list itself is sent only if
  `headblocks` was requested.
- If `tspends` was requested, all treasury spend hashes in its mempool, which
  holds at most 7.

*Receiving.* A peer #MUSTNOT send more than one `initstate` (or `miningstate`)
per connection; dcrd bans a peer that does. On receipt, dcrd requests with a
single `getdata` every listed block it neither has nor has already requested,
followed by every listed vote and treasury spend it does not already have.

=== `getminings` and `miningstate` (obsolete) <sec:p2p-miningstate>

The predecessors of `getinitstate` and `initstate`, used before version 8.
Note that the command string of the request is `getminings` (ten bytes), not
`getminingstate`. The wire layer accepts both at every version, but dcrd bans
any peer that sends either at a negotiated version of 8 or later, which covers
every version it accepts. `getminings` has no payload; `miningstate` is:

#fieldtable(
  caption: [`miningstate` payload (maximum 1546 bytes)],
  ("version", "uint32", "4", [Message version; dcrd used 1.]),
  ("height", "uint32", "4", [Height of the sender's best chain tip. (dcrd's handler intended an empty reply of height 0 while its best height was below #param("StakeValidationHeight") $- 1$, but its send helper returns without sending when the block list is empty, so no reply is produced in that case.)]),
  ("block_count", "varint", "1", [At most #const("MaxMSBlocksAtHeadPerMsg") $= 8$.]),
  ("blocks", "byte[32][block_count]", "32 each", [Block hashes.]),
  ("vote_count", "varint", "1", [At most #const("MaxMSVotesAtHeadPerMsg") $= 40$.]),
  ("votes", "byte[32][vote_count]", "32 each", [Vote hashes.]),
) <tab:p2p-miningstate>

=== Version 2 Compact Filter Messages <sec:p2p-cfilterv2>

Version 2 compact filters let light clients test whether a block may concern
them without downloading it. Their construction and the header commitment
that authenticates them are specified in #chref("filters")\; this section
gives only the messages.

#fieldtable(
  caption: [`getcfilterv2` payload (32 bytes, version 7 and later)],
  ("block_hash", "byte[32]", "32", [Block whose filter is requested.]),
) <tab:p2p-getcfilterv2>

#fieldtable(
  caption: [`cfilterv2` payload (maximum 263210 bytes)],
  ("block_hash", "byte[32]", "32", [Block the filter belongs to.]),
  ("data", "varbytes", "1+", [Serialized filter, at most #const("MaxCFilterDataSize") $= 262144$ bytes.]),
  ("proof_index", "uint32", "4", [Index of the filter's leaf in the header commitment tree; dcrd always sends 0.]),
  ("proof_count", "varint", "1", [Number of proof hashes, at most #const("MaxHeaderProofHashes") $= 32$.]),
  ("proof", "byte[32][proof_count]", "32 each", [Inclusion proof hashes, leaf to root.]),
) <tab:p2p-cfilterv2>

dcrd answers `getcfilterv2` with one `cfilterv2` for any block whose filter it
has, on the best chain or not, and silently ignores requests for unknown
blocks.

#fieldtable(
  caption: [`getcfsv2` payload (64 bytes, version 11 and later)],
  ("start_hash", "byte[32]", "32", [First block of the range.]),
  ("end_hash", "byte[32]", "32", [Last block of the range, inclusive.]),
) <tab:p2p-getcfsv2>

#fieldtable(
  caption: [`cfiltersv2` payload (maximum 26321001 bytes)],
  ("count", "varint", "1", [Number of filters, at most #const("MaxCFiltersV2PerBatch") $= 100$.]),
  ("filters", "cfilterv2[count]", "var", [Each entry is a complete `cfilterv2` payload (@tab:p2p-cfilterv2), in ascending height order from `start_hash` to `end_hash`.]),
) <tab:p2p-cfiltersv2>

dcrd answers `getcfsv2` with one `cfiltersv2` when both blocks are known, the
start block is the end block or an ancestor of it (on any branch), and the
range contains at most 100 blocks, that is
$"end.height" - "start.height" + 1 <= 100$, and it has the filter of every
block in the range. Otherwise the request is ignored without a response.

=== Version 1 Compact Filter Messages (obsolete) <sec:p2p-cfilterv1>

Protocol version 6 introduced a first generation of committed filters with
the messages below, and version 7 deprecated them. The wire layer still
decodes them at version 6 and later, but dcrd does not implement version 1
filters and does not advertise `SFNodeCF`: it bans any peer that sends
`getcfilter`, `getcfheaders` or `getcftypes` at a negotiated version of 6 or
higher (and disconnects it at lower versions), and ignores `cfilter`,
`cfheaders` and `cftypes`. The layouts, for completeness:

#figure(
  caption: [Version 1 filter message payloads. `filter_type` is a `uint8`: 0 regular, 1 extended.],
  table(
    columns: (auto, 1fr),
    table.header([Command], [Payload]),
    [`getcfilter`], [`block_hash` (32), `filter_type` (1).],
    [`cfilter`], [`block_hash` (32), `filter_type` (1), `data` (varbytes, at most 262144 bytes).],
    [`getcfheaders`], [`count` (varint, at most 500), `locator` (32 each), `stop` (32), `filter_type` (1).],
    [`cfheaders`], [`stop` (32), `filter_type` (1), `count` (varint, at most 2000), `filter_headers` (32 each).],
    [`getcftypes`], [No payload.],
    [`cftypes`], [`count` (varint, at most 256), `filter_types` (1 each).],
  ),
) <tab:p2p-cfilterv1>

=== Mixing Messages <sec:p2p-mixmsgs>

Protocol version 10 added eight messages that implement the StakeShuffle
coin-mixing protocol: `mixpairreq` (pair request), `mixkeyxchg` (key
exchange), `mixcphrtxt` (ciphertexts), `mixslotres` (slot reservation),
`mixfactpoly` (factored polynomial), `mixdcnet` (DC-net), `mixconfirm`
(confirmation) and `mixsecrets` (revealed secrets). Their payloads, their
signatures and hashes, and their validation are specified in
#chref("mixing")\; their per-type maximum payloads are in @tab:p2p-messages.

At the peer-to-peer layer they behave like transactions: they are announced
with `inv` vectors of type `MSG_MIX` whose hash is the message hash, requested
with `getdata`, and relayed to peers that negotiated version 10 or later and
did not disable relay in their `version` message. A peer #MUSTNOT send them at
a lower negotiated version. dcrd bans peers whose mixing messages fail
validation in ways the mixing chapter marks as bannable.

== Synchronization and Relay <sec:p2p-sync>

This section describes how dcrd obtains the chain from its peers and how new
blocks, transactions, votes and other data spread through the network. All of
it is implementation behaviour rather than a wire requirement, but a node that
does not follow the same request-and-response discipline will be disconnected,
because dcrd refuses unsolicited blocks and disconnects peers that do not
answer requests in time.

@fig:p2p-sync gives an overview; the subsections below specify each step.

#figure(
  kind: image,
  placement: auto,
  caption: [Messages exchanged with the sync peer during initial
    synchronization, and the announcement of a new block afterwards. In
    the steady state the announcing peer may be any peer. dcrd announces
    with `inv` (`MSG_BLOCK`) only to a peer that has not sent `sendheaders`,
    and does not itself request blocks announced that way.],
  block(width: 15.6cm, height: 8.40cm, {
    dg-box(2.1, 0, 3.0, 0.7)[*Node*]
    dg-box(11.1, 0, 3.0, 0.7)[*Peer*]
    dg-seg(3.6, 0.7, 3.6, 8.40, stroke: 0.6pt + palette.muted)
    dg-seg(12.6, 0.7, 12.6, 8.40, stroke: 0.6pt + palette.muted)
    dg-seg(0.15, 1.05, 0.15, 2.50, stroke: 1.6pt + palette.turquoise)
    dg-text(0.35, 1.60, 2.9, align-to: left, colour: palette.muted)[Header sync]
    dg-seg(0.15, 2.65, 0.15, 4.10, stroke: 1.6pt + palette.turquoise)
    dg-text(0.35, 3.21, 2.9, align-to: left, colour: palette.muted)[Block download]
    dg-seg(0.15, 4.25, 0.15, 5.70, stroke: 1.6pt + palette.turquoise)
    dg-text(0.35, 4.80, 2.9, align-to: left, colour: palette.muted)[Initial state]
    dg-seg(0.15, 5.85, 0.15, 8.10, stroke: 1.6pt + palette.turquoise)
    dg-text(0.35, 6.80, 2.9, align-to: left, colour: palette.muted)[Steady state]
    dg-text(3.6, 1.13, 9.0)[`getheaders` (locator from the parent of the best header, stop hash zero)]
    dg-arrow(3.6, 1.55, 12.6, 1.55)
    dg-text(3.6, 1.93, 9.0)[`headers` (up to 2000; repeated until the peer's tip is reached)]
    dg-arrow(12.6, 2.35, 3.6, 2.35)
    dg-text(3.6, 2.73, 9.0)[`getdata` (`MSG_BLOCK`, at most 16 outstanding)]
    dg-arrow(3.6, 3.15, 12.6, 3.15)
    dg-text(3.6, 3.53, 9.0)[`block` (one per request; refilled below 10 outstanding)]
    dg-arrow(12.6, 3.95, 3.6, 3.95)
    dg-text(3.6, 4.33, 9.0)[`getinitstate`]
    dg-arrow(3.6, 4.75, 12.6, 4.75)
    dg-text(3.6, 5.13, 9.0)[`initstate`]
    dg-arrow(12.6, 5.55, 3.6, 5.55)
    dg-text(3.6, 5.93, 9.0)[`headers` with one header]
    dg-arrow(12.6, 6.35, 3.6, 6.35)
    dg-text(3.6, 6.73, 9.0)[`getdata` (`MSG_BLOCK`)]
    dg-arrow(3.6, 7.15, 12.6, 7.15)
    dg-text(3.6, 7.53, 9.0)[`block`]
    dg-arrow(12.6, 7.95, 3.6, 7.95)
  }),
) <fig:p2p-sync>

=== State Used by Synchronization <sec:p2p-sync-state>

dcrd distinguishes three views of the chain:

- The *best header* is the tip of the header chain with the most cumulative
  proof of work that is not known to be invalid. Headers are validated and
  stored as soon as they arrive, before the blocks themselves.
- The *best chain* is the chain of fully validated blocks with the most
  cumulative work (#chref("blocks")). It lags behind the best header while
  blocks are being downloaded.
- The node is *current* when its best chain has at least
  #param("MinKnownChainWork") of cumulative work, has caught up with the best
  header, and its tip timestamp is at most 24 hours older than the
  network-adjusted time. Once current, the state latches and is lost again
  only if the tip becomes more than 24 hours old.

The synchronization manager additionally tracks a *sync height*, the highest
height any sync peer has claimed or any accepted header or block has reached,
and considers itself synced once the chain is current and its best height has
reached the sync height.

For each peer it tracks the *best announced block*, the announced block with
the most cumulative work that is also known locally, and the most recently
announced block that did not connect to any known header (an *orphan
announcement*), which is promoted to best announced block if its header later
becomes known.

=== Choosing a Sync Peer <sec:p2p-sync-peer>

Exactly one peer at a time is the *sync peer*. A peer is a candidate if it
advertises `SFNodeNetwork` and the best height it reported (initially the
`last_block` of its `version` message, later updated from its announcements)
is at least the local best header height. Among the candidates the one with
the greatest reported height is chosen. A new sync peer is chosen when the
current one disconnects, or, if there is none, when a new peer connects.

=== Initial Header Synchronization <sec:p2p-initial-headers>

A node that is not yet synced first downloads all headers from the sync peer
and only then starts downloading blocks. To begin, and whenever a new sync
peer is chosen during this phase, it sends the sync peer a `getheaders` whose
locator starts at the _parent_ of the local best header and whose stop hash is
zero. Starting one block back guarantees a non-empty answer even when both
peers already share the same tip, which lets the node learn the peer's real
best block. It then sets the sync height to the larger of the peer's reported
height and the local best header height.

Each `headers` reply is processed as in @sec:p2p-headers-processing. If it
contains the maximum of 2000 headers, the node immediately asks for more with
a `getheaders` whose locator starts at the last received header. The initial
header synchronization is complete when the sync peer delivers a `headers`
message whose final header's height plus 6 exceeds the sync height.

While this phase lasts, every `headers` message from the sync peer that
raises the best header height resets a *stall timer* of
$(3 + 2000 \/ 1000) times 2 = 10$ seconds. If the timer fires, the sync peer
is disconnected and another is chosen.

When the phase completes, the node sends a `getheaders` (from the parent of
its best header) to every peer that serves data and whose best announced
block is still unknown, so that it learns their chains as well.

=== Processing `headers` <sec:p2p-headers-processing>

@alg:p2p-headers gives the processing of a received `headers` message. Its
handling of headers that do not connect deserves attention: a short message
whose first header has an unknown parent is treated as an announcement of a
block the local node is missing parents for, while a long one is treated as
evidence that the peer is on an unrelated chain.

#algorithm("Processing a headers message", src: "internal/netsync/manager.go · OnHeaders")[
  ```python
  MAX_ANNOUNCE_HEADERS = 12        # fewer than this looks like an announcement
  MAX_ORPHAN_MSGS      = 10        # consecutive non-connecting announcements

  def on_headers(peer, headers):
      if len(headers) == 0:
          return                                   # peer has nothing more
      first = headers[0]
      if not have_header(first.prev_block):
          if len(headers) < MAX_ANNOUNCE_HEADERS:
              peer.orphan_msgs += 1
              if peer.orphan_msgs >= MAX_ORPHAN_MSGS:
                  disconnect(peer); return
              if initial_header_sync_done:
                  peer.push_getheaders(locator(best_header), ZERO_HASH)
              peer.orphan_announcement = hash(headers[-1])
              if not initial_header_sync_done:
                  peer.reported_height = max(peer.reported_height, headers[-1].height)
              return
          if initial_header_sync_done:
              disconnect(peer)                     # unrelated chain
          return                                   # ignored during initial sync

      for i in range(1, len(headers)):             # must form a single chain
          if (headers[i].prev_block != hash(headers[i - 1])
                  or headers[i].height != headers[i - 1].height + 1):
              disconnect(peer); return

      prev_best_height = best_header.height
      for h in headers:
          if not process_block_header(h):          # header validation, blocks chapter
              if not initial_header_sync_done and peer is sync_peer:
                  sync_height = best_header.height
              disconnect(peer); return
          peer.known_inventory.add((MSG_BLOCK, hash(h)))

      if (not initial_header_sync_done and peer is sync_peer
              and best_header.height > prev_best_height):
          reset_header_sync_stall_timer()          # 10 seconds
      peer.orphan_msgs = 0
      update_best_announced(peer, headers[-1])     # also updates reported height
      sync_height = max(sync_height, best_header.height)

      full = len(headers) == 2000
      if (not chain_is_current() and not peer.inbound and not full
              and chain_work(hash(headers[-1])) < MIN_KNOWN_CHAIN_WORK):
          disconnect(peer); return                 # outbound peer on a weak chain
      if full:
          peer.push_getheaders(locator(hash(headers[-1])), ZERO_HASH)
      maybe_finish_initial_header_sync(peer, headers[-1])
      if chain_is_current():
          request_blocks_not_held_or_requested(peer, headers)   # getdata
      if initial_header_sync_done and sync_peer is not None:
          fetch_next_blocks(sync_peer)              # Algorithm below
  ```
] <alg:p2p-headers>

The header validation performed by `process_block_header`, including the
proof-of-work, difficulty, timestamp and checkpoint checks, belongs to
#chref("blocks"). A header that fails validation causes a disconnect without a
ban.

=== Block Download <sec:p2p-block-download>

Once the headers are synced, blocks are downloaded from the sync peer along
the branch leading to the best header, oldest first, with a small window of
outstanding requests (@alg:p2p-fetch). The node keeps a look-ahead list of up
to 512 needed block hashes, refreshed when the best header changes or when
the list runs short.

#algorithm("Requesting the next blocks from the sync peer", src: "internal/netsync/manager.go · fetchNextBlocks")[
  ```python
  MAX_IN_FLIGHT = 16       # per peer
  MIN_IN_FLIGHT = 10       # refill threshold

  def fetch_next_blocks(peer):
      in_flight = count(r for r in requested_blocks.values() if r == peer)
      if in_flight >= MAX_IN_FLIGHT:
          return
      needed = next_needed_blocks()    # blocks on the path from the best chain tip
                                       # to the best header whose data is missing
      want = min(len(needed), MAX_IN_FLIGHT - in_flight)
      msg = []
      for h in needed[:want]:
          consume(h)
          if h in requested_blocks:    # already in flight from some peer
              continue
          requested_blocks[h] = peer
          msg.append(InvVect(MSG_BLOCK, h))
      if msg:
          peer.send(getdata(msg))

  # After a requested block from the sync peer has been processed:
  #     if len(requested_blocks) < MIN_IN_FLIGHT: fetch_next_blocks(sync_peer)
  ```
] <alg:p2p-fetch>

A block received from a peer #MUST have been requested from that peer;
otherwise dcrd disconnects the peer (@sec:p2p-block). Each received block is
fully validated and connected (#chref("blocks")); the use of checkpoints and
of the assume-valid block to skip script validation for old blocks is also
specified there and has no effect on the messages exchanged. If a block is
rejected and it was the block for the best header, the node resets its sync
height to the new best header and sends `getheaders` to every peer that serves
data, to rediscover a valid best chain.

The initial chain synchronization is complete when the chain becomes current.
At that point the node requests the initial state from every peer
(@sec:p2p-initstate).

When a peer disconnects, every block, transaction and mixing message that was
requested from it and not yet received is re-requested from another peer that
is known to have announced it, or forgotten if there is none. If the peer was
the sync peer, a new one is chosen and block download resumes from it.

#note[
  dcrd has no orphan block pool. Because blocks are only requested once their
  headers have been validated and connected, a block whose parent is unknown
  can only arrive unsolicited, and unsolicited blocks are refused. Missing
  ancestry is always resolved at the header level, by `getheaders`.
]

=== Steady-State Block Relay <sec:p2p-relay-blocks>

New blocks spread by header announcement:

+ When the node is current and a block whose parent is the current tip has
  passed its sanity and context checks (#chref("blocks")), and before it is
  fully connected, dcrd announces it immediately (not trickled) to every peer
  that advertises `SFNodeNetwork`. Relaying before the comparatively expensive
  connection checks is safe in practice because a block with valid proof of
  work rarely fails them.
+ When the block has been accepted into the block chain, dcrd announces it
  again to every peer, provided the node is current (or configured to mine
  while not synced). A peer that already received the announcement in step 1
  is skipped, because dcrd suppresses an announcement of the same block it
  announced last to that peer.
+ To a peer that sent `sendheaders`, the announcement is a `headers` message
  containing that single header. To any other peer it is an `inv` with one
  `MSG_BLOCK` vector.
+ The receiver processes the header (@alg:p2p-headers). Because it is current,
  it requests the block with `getdata` from the peer whose announcement
  arrived first. Side-chain blocks are requested in the same way, so that
  competing tips are available for the stakeholders to vote on.

=== Transaction Relay <sec:p2p-relay-tx>

Transactions, of every type, propagate by `inv` announcement followed by
`getdata` and `tx`. When a transaction is accepted to the mempool, from a
peer, from RPC or because it resolved an orphan, dcrd queues an announcement
to every connected peer that:

- has not disabled relay in its `version` message; and
- is not already known to have the transaction (it announced or sent it, or
  dcrd announced it to the peer, within the last 15 minutes, among the last
  1000 such objects).

Mixing messages are announced under the same conditions and only to peers that
negotiated version 10 or later.

When an announcement arrives, dcrd requests the transaction only if all of
the following hold: the local node is synced, the transaction is not in the
mempool or orphan pool, it is not among the transactions received from peers
and rejected since a block received from a peer last extended the best
chain, it was not
confirmed in one of the most recent blocks (about 23000 transactions are
remembered), and it is not already being requested from some peer. At most
50000 outstanding transaction requests are tracked; beyond that a random
outstanding entry is forgotten. Orphan transactions, those spending outputs
not yet known, are kept in the mempool's orphan pool tagged with the peer that
sent them and evicted when that peer disconnects (#chref("policy")).

Transactions submitted with `sendrawtransaction`, other than votes, are kept
in a rebroadcast set until they are mined, and the whole set is re-announced through the normal relay path five
minutes after the node starts and thereafter at intervals chosen uniformly at
random below 30 minutes. Each time a block is connected or disconnected,
tickets whose price
no longer equals the next stake difficulty or that have expired are removed
from the set, as are revocations whose ticket is not in the live ticket set.
(The code comment describes the last condition as a ticket that "has been
revived", but the test is that the ticket is _not_ live, which is the normal
state of a ticket being revoked, so a revocation is in practice dropped from
the set at the first connected block.)

=== Votes, Tickets and Treasury Spends <sec:p2p-relay-stake>

Ticket purchases, votes, revocations and treasury spends are transactions of
the stake tree (#chref("staking"), #chref("treasury")) and use the ordinary
transaction relay; there is no separate inventory type. Votes are
time-critical because a block cannot be built on the current tip until enough
votes for it are available, which is why new blocks are announced immediately
and why a node that comes online asks for the current tip candidates and their
votes with `getinitstate` (@sec:p2p-initstate). Treasury spends wait in the
mempool for many blocks while stakeholders vote on them, so a newly started
node learns of them through the `tspends` initial state type rather than by
waiting for a rebroadcast.

=== Inventory Trickling <sec:p2p-trickle>

dcrd does not announce transactions and mixing messages one by one. Each
peer has a queue of pending inventory that is flushed after a random delay
uniformly chosen between 100 and 500 milliseconds, re-chosen after every
flush. A flush sends as many `inv` messages as needed, each with at most 1000
vectors, skipping items that became known to the peer in the meantime. Block
announcements bypass the queue and are sent at once.

== Peer Management <sec:p2p-peers>

Everything in this section is policy of the reference implementation. It is
specified because other nodes will apply it to any implementation that
connects to them, and because its constants explain the limits an
implementation will encounter.

=== Connection Limits <sec:p2p-limits>

#figure(
  caption: [Connection limits (dcrd defaults)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Limit], [Default], [Meaning]),
    [Maximum peers], [125], [Total of inbound, automatic outbound and one-off manual connections, including pending ones. Persistent connections and inbound connections from whitelisted addresses do not count.],
    [Target outbound], [8], [Automatic outbound connections maintained (reduced to the maximum peers if that is smaller).],
    [Per host], [5], [Connections of any kind, including persistent ones, with the same IP address. Loopback and whitelisted addresses are exempt.],
    [Persistent peers], [8], [Manually configured peers that are kept connected and retried. They count towards neither the maximum peers nor the outbound target.],
    [Outbound per group], [1], [An automatic outbound connection is not made to a network group (below) that already has an outbound connection of any kind: automatic, manual or a registered persistent peer, pending ones included.],
  ),
) <tab:p2p-limits>

*Outbound selection.* To fill an outbound slot dcrd draws candidate
addresses from the address manager, which only returns routable addresses,
and makes up to 100 draws. It skips an address whose network group already
has an outbound connection; during the first 30 draws it also skips addresses
attempted in the last ten minutes, and during the first 50 it skips addresses
whose port is not the network's default port. Tor addresses are eligible only
when an onion-capable proxy is configured. After 25 consecutive failures (to
find a suitable address or to connect), automatic outbound connections pause
for 5 seconds before each further attempt until one succeeds. The *network
group* of an address is its /16 prefix for IPv4 (also for IPv6 addresses that
embed an IPv4 address: 6to4, Teredo and the translation prefixes), its /32
prefix for other IPv6 addresses (/36 inside the Hurricane Electric block
2001:470::/32), and the low four bits of the first byte of the public key for
Tor v3.

*Persistent peers* are retried with exponential backoff. When a dial fails,
or a connection ends, less than 5 seconds after the dial that produced it
was started, the retry count $r$ is incremented and the next attempt waits a
random time uniformly distributed in $[b\/2, b)$, where
$b = min(5 "s" times 2^(r-1), 5 "min")$. Otherwise $r$ is reset to zero and
the peer is redialed at once; this includes a dial that takes 5 seconds or
longer to fail, such as one that runs into the 30-second dial timeout.

*Inbound acceptance.* An inbound connection is accepted and then immediately
closed if any of the following applies, unless the address is whitelisted or
loopback where noted:

- The remote IP address is banned.
- *Rate limit* (not for whitelisted or loopback): each inbound group may open
  on average one connection every 5 seconds, with bursts of 3. The inbound
  group is the full IPv4 address or the /64 IPv6 prefix, coarsened to /24 and
  /56 while a flood is detected, that is while more than 300 connections were
  allowed through the rate limit in the last 60 seconds. During a flood,
  connections that pass the rate limit are additionally dropped at random with
  a probability rising smoothly from 0.2 to 0.85 as the flood intensity grows
  to 1200 allowed connections per minute.
- Another connection with the same IP address _and_ port exists.
- The per-host limit (not for whitelisted or loopback addresses) or the
  maximum peers limit (not for whitelisted addresses) would be exceeded.

=== Timeouts <sec:p2p-timeouts>

#figure(
  caption: [Timeouts and periodic actions],
  table(
    columns: (auto, auto, 1fr),
    table.header([Name], [Value], [Effect]),
    [Handshake], [30 s], [The `version`/`verack` exchange must finish within this time.],
    [Idle], [120 s], [Each read waits at most this long for a complete message; on expiry the peer is disconnected. Configurable, minimum 15 s.],
    [Ping interval], [107 s], [A `ping` is sent at this interval. Fixed; it does not follow a configured idle timeout.],
    [Response stall], [30 s], [Deadline for every object requested with `getdata` (answered by the object or `notfound`) and for the `initstate` answering `getinitstate`. Checked every 15 s; time spent processing messages from the peer extends the deadlines.],
    [Write stall], [20 s + 1 s per 256 KiB], [Deadline for writing one message to the socket.],
    [Header sync stall], [10 s], [Maximum time without header progress from the sync peer during initial header synchronization.],
    [Dial], [30 s], [Outbound connection attempt timeout.],
  ),
) <tab:p2p-timeouts>

Two queue limits complement the timeouts. A peer is disconnected if the
messages queued for sending to it exceed 40 MiB in total, and when the local
node is about to send it a `getdata` that would raise the number of objects
requested from that peer and not yet delivered (by the object or a
`notfound`) above 75000. No
response deadline is set for `ping`, `mempool`, `getblocks` or `getheaders`,
because a peer with nothing to report may legitimately not answer them, or may
answer after a long backlog.

=== Misbehaviour and Banning <sec:p2p-misbehaviour>

dcrd responds to misbehaviour in one of three ways:

- *Ban*: the peer's IP address (without port) is banned for 24 hours and the
  connection is closed. New connections to or from a banned address are
  closed as soon as they are established. A ban is not applied to whitelisted
  peers, and banning can be disabled by configuration.
- *Ban score*: a score is increased; when it exceeds the threshold (default
  100) the peer is banned.
- *Disconnect*: the connection is closed with no lasting consequence.

The ban score has a *persistent* part, which only grows, and a *decaying*
part, which halves every 60 seconds. @alg:p2p-banscore specifies it. This is
one of the few places where dcrd uses floating-point arithmetic, which is
acceptable because the score is local policy.

#algorithm("Dynamic ban score", src: "internal/connmgr/dynamicbanscore.go · DynamicBanScore")[
  ```python
  HALFLIFE = 60                        # seconds
  LIFETIME = 1800                      # seconds after which the decaying part is 0
  LAMBDA   = ln(2) / HALFLIFE

  persistent: uint32 = 0
  transient:  float  = 0.0
  last_unix:  int    = 0

  def increase(p: uint32, t: uint32, now_unix: int) -> uint32:
      persistent += p
      dt = now_unix - last_unix
      if t > 0:
          if dt > LIFETIME:
              transient = 0.0
          elif transient > 1 and dt > 0:
              transient *= exp(-LAMBDA * dt)
          transient += t
          last_unix = now_unix
      return persistent + uint32(transient)      # truncation toward zero

  # After an increase: if score > THRESHOLD / 2 a warning is logged, and if
  # score > THRESHOLD (default 100) the peer is banned unless whitelisted.
  ```
] <alg:p2p-banscore>

@tab:p2p-banscore lists the ban score increments and @tab:p2p-misbehaviour
the immediate consequences.

#figure(
  caption: [Ban score increments],
  table(
    columns: (auto, auto, auto),
    table.header([Event], [Persistent], [Decaying]),
    [`mempool` received], [0], [33],
    [`getdata` with $n$ vectors], [0], [$floor(99 n \/ 50000)$],
    [`notfound` listing $b$ blocks], [$20 b$], [0],
    [`notfound` listing $t$ transactions], [0], [$10 t$],
    [`notfound` listing $m$ mixing messages], [0], [$10 m$],
  ),
) <tab:p2p-banscore>

#figure(
  caption: [Misbehaviour with an immediate consequence],
  table(
    columns: (1fr, auto),
    table.header([Behaviour], [Consequence]),
    [Any wire protocol violation (@sec:p2p-receive): wrong magic, oversized payload, malformed or unknown command, bad checksum, trailing bytes, non-canonical varint, invalid string, count above a limit, message invalid for the negotiated version, out-of-range timestamp, unknown address type], [Ban],
    [Empty `inv`, empty `getdata`, empty `addr`], [Ban],
    [`addrv2` address whose type does not match its canonical form], [Ban],
    [Second `getinitstate`, or second `initstate`/`miningstate`], [Ban],
    [`getminings` or `miningstate` at version 8 or later], [Ban],
    [`getcfilter`, `getcfheaders` or `getcftypes` at version 6 or later], [Ban],
    [Mixing message failing validation in a bannable way (#chref("mixing"))], [Ban],
    [Second `version` or `verack`; first message not `version`; `verack` not where required; self-connection; version below 9; handshake timeout], [Disconnect],
    [Unrequested `block`], [Disconnect],
    [`notfound` containing an unknown inventory type], [Disconnect],
    [`headers` not forming a chain, containing an invalid header, or not connecting after the initial sync and not looking like an announcement; 10 consecutive non-connecting announcements], [Disconnect],
    [Outbound peer whose best chain has less than #param("MinKnownChainWork") during initial sync], [Disconnect],
    [Response, write or header-sync stall; idle timeout; queue limits exceeded], [Disconnect],
    [Transaction or mixing message announced to a blocks-only node], [Disconnect],
  ),
) <tab:p2p-misbehaviour>

=== The Address Manager <sec:p2p-addrmgr>

dcrd keeps the addresses it has learned in an *address manager* modelled on
Bitcoin Core's. Its exact bucketing is local policy, but its structure
explains which addresses a node shares and connects to.

Addresses are held in two tables. The *new* table, 1024 buckets of at most 64
addresses, holds addresses that have been heard of but never successfully
connected to; an address is placed in a bucket chosen by a keyed hash of its
network group and the network group of the peer that reported it, and a
frequently heard address may appear in up to 8 buckets. The *tried* table, 64
buckets of at most 256 addresses, holds addresses to which an outbound
connection has succeeded, placed by a keyed hash of the address and its
group. The hash key is random per node, so an attacker cannot predict the
placement. Unroutable addresses (private, link-local, documentation,
loopback, unspecified and similar reserved ranges) are never stored.

To choose an outbound address, the manager picks the tried or new table with
equal probability (when both have a matching entry), then a random bucket and
a random entry within it, and accepts the entry with probability
$min(1, f dot c)$, retrying otherwise. Here $f$ starts at 1 and is multiplied
by 1.2 after every rejected draw, and $c = max(1.5^(-a), 0.01)$, where $a$ is
the number of connection attempts since the last successful handshake, except
that $c = 0.01$ for an
address that was never attempted or was attempted in the last ten minutes.
The address's timestamp plays no part in the choice.

An address is *bad*, and is neither shared nor preferred, if it was not
attempted in the last minute and any of the following holds: its timestamp is
more than 10 minutes in the future; its timestamp is more than 30 days old; it
was attempted at least 3 times and never succeeded; or it has not succeeded in
the last 7 days and has failed at least 5 times. The manager reports that it
needs more addresses while it holds fewer than 1000, and saves its state to
disk every 10 minutes and on shutdown.

=== Address Relay <sec:p2p-addr-relay>

dcrd's address relay is deliberately conservative, to make it hard for others
to learn which addresses a node knows:

- *Answering `getaddr`.* Only for inbound peers, only once per connection.
  dcrd takes every known address of a type the negotiated version can encode
  (IPv4 and IPv6 below version 12, also Tor v3 at version 12) that is not bad
  and has connected successfully at least once, selects a random 23% of them
  rounded up (at most 2500), removes those the peer is already known to have,
  and sends the remainder, truncated at random to 1000, in one `addr` or
  `addrv2` message. If nothing remains, nothing is sent.
- *Self-advertisement.* After the handshake with an outbound peer, as described
  in @sec:p2p-post-handshake.
- *Receiving addresses.* Every address in a received `addr` or `addrv2` whose
  timestamp is more than 10 minutes in the future has its timestamp replaced
  by the current time minus 5 days. The addresses are recorded as known to
  the sending peer and added to the address manager with that peer as their
  source.
- *No forwarding.* Received addresses are never relayed to other peers. They
  reach other nodes only when those nodes send `getaddr`.

dcrd tracks, per connection, up to 10000 addresses the peer is known to have
(in a probabilistic filter with a false-positive rate of 1 in 1000), so that it
does not send them back.

=== External Address Discovery <sec:p2p-external>

A node that accepts inbound connections needs to know its own public address
to advertise it. Besides addresses configured explicitly or found on local
interfaces, dcrd learns it from the `addr_you` field of its peers' `version`
messages. Each report by an outbound peer of a routable, non-local address from which
that peer's own address is reachable gives that IP address (the port is
ignored) a point. Reports from inbound peers are
intended only to add points to an address already reported by an outbound
peer, but they are looked up under the address _and port_ while outbound
reports are stored under the bare IP address, so at the reference commit an
inbound report never matches and has no effect. When, after an outbound
report, the best-scoring address of a family (IPv4 or IPv6) has at least 60%
of the outbound target rounded up (5 with the default target of 8), it is
added as a local address, provided it matches a listening interface or is a
plausible external endpoint for one. This discovery is disabled when a proxy
is used, when an external address is configured or discovery is disabled by
configuration, when the node does not listen, and on the simulation and
regression networks.

=== Peer Discovery and Seeding <sec:p2p-seeding>

A node with an empty address manager finds its first peers through *HTTPS
seeders*, web services that crawl the network and return addresses of
reachable full nodes. The seeder host names for each network are in
#chref("parameters")\; the simulation and regression networks have none. The
legacy DNS seeds that also appear in the network parameters are deprecated and
no longer queried. Peers can also be configured manually; configuring
`--connect` peers disables automatic outbound connections entirely.

At start-up, unless seeding is disabled, dcrd queries every seeder in
parallel. The request is

```
GET https://<seeder>/api/addrs?services=1
```

where `services` is the decimal value of the required service flags. Two
further query parameters are defined by the client but not used by dcrd:
`ipversion` (4 or 6) and `pver` (a protocol version). The connection uses
the same dialer as peer connections, and so the same proxy settings, and the
request times out after one minute. Any status other than 200 is a failure.

The response body is a sequence of JSON objects, each of the form

```
{"host": "<ip>:<port>", "services": <uint64>, "pver": <uint32>}
```

separated by optional whitespace. It is _not_ a JSON array; an array is a
parse failure. dcrd reads at most 4096 bytes and at most 16 objects; a
truncated or malformed object fails the whole query, while an empty body is a
successful query that yields no addresses. Entries whose `host` is
not an IP literal with a valid port are skipped. Each accepted address is
added to the address manager with the reported services, a timestamp chosen
at random between 3 and 7 days in the past, and, as its source, the seeder's
own IP address on port 443. The `pver` field is parsed but not used.

If every seeder fails and the address manager still needs addresses, the
round is repeated after a delay that starts at 1 second and grows by one
second per round up to 10 seconds.

#note[
  Summary of the main departures from Bitcoin's protocol, for readers who know
  it: BLAKE-256 single-hash checksum; network magic and ports of their own;
  unknown commands and version-invalid messages are banned rather than
  ignored; no `reject` at any accepted version; minimum protocol version 9;
  `verack` must directly follow `version` at version 12; the inbound peer
  answers with the negotiated version; block announcements by header and no
  unsolicited blocks; `addrv2` with a little-endian port and no address
  forwarding; `getinitstate`/`initstate` for tip, vote and treasury spend
  state; version 2 compact filters with header-commitment proofs; mixing
  messages; HTTPS seeders instead of DNS seeds.
]
