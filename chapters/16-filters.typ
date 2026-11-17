#import "../template.typ": *

= Compact Filters and Light Clients <ch:filters>

A full node downloads and validates every block. A _light client_, such as a
wallet on a phone, cannot afford to, yet it still needs to find the
transactions that pay to it or spend its coins. Decred serves such clients with
*compact block filters*: for every block, a small probabilistic summary of the
scripts the block creates and spends, from which a client can decide locally,
without revealing anything about its addresses, whether the block may concern
it. Only when a filter matches does the client fetch the whole block.

Since the activation of the `headercommitments` agenda (#dcp(5) @dcp0005),
every block header commits to its block's filter. A filter therefore can no
longer be forged or withheld by the peer that serves it, but it has also become
part of the consensus rules: every full node #MUST compute each block's filter
bit for bit as specified here, because a block whose header carries a different
commitment is invalid.

This chapter specifies the keyed hash function SipHash-2-4 as used by the
filters (@sec:filters-siphash), the Golomb-coded set that encodes a filter
(@sec:filters-gcs), exactly which data from a block enters its filter
(@sec:filters-contents), the header commitment and its inclusion proofs
(@sec:filters-commitments), and, informatively, how light clients use all of
this (@sec:filters-spv). Test vectors produced by dcrd close the chapter
(@sec:filters-vectors). The block header and the variable-length integer
encoding are defined in #chref("encoding")\; BLAKE-256 and the generic Merkle
tree construction in #chref("crypto")\; how the activation of an agenda is
determined in #chref("voting")\; and the encodings of the peer-to-peer messages
named here in #chref("p2p").

#pitfall[
  Decred's filters resemble Bitcoin's BIP158 filters @bip158 only in outline.
  The parameters, the reduction function, the serialization of the item count,
  the removal of duplicates, the encoding of the empty filter, the key, the
  contents and the commitment scheme all differ. Nothing in this chapter should
  be implemented from BIP158 or BIP157 @bip157.
]

== Overview and Constants <sec:filters-overview>

A filter is built in three steps. First, a list of byte strings (_items_),
almost all of them transaction scripts, is collected from the block and from
the outputs its inputs spend (@sec:filters-contents). Second, each item is
hashed with SipHash-2-4 under a 128-bit key taken from the block header, and
the 64-bit hashes are mapped into a range sized so that two different items
collide with probability about $1 slash M$. Third, the sorted values are
compressed with Golomb–Rice coding into a bit string (@sec:filters-gcs).
Hashing the serialized filter with BLAKE-256 gives the value the header
commits to (@sec:filters-commitments).

@tab:filters-constants lists every constant used. None of them is a
per-network parameter: the filter construction is identical on all networks.

#figure(
  caption: [Constants of the compact filter system],
  table(
    columns: (auto, auto, 1fr),
    table.header([Name], [Value], [Meaning]),
    [#const("B")], [19], [Golomb–Rice parameter: bit size of the remainder code, bin size $2^19$ (`blockcf2.B`).],
    [#const("M")], [784931], [Inverse of the false-positive rate for version 2 block filters (`blockcf2.M`).],
    [#const("KeySize")], [16], [Size in bytes of a SipHash key (`gcs.KeySize`).],
    [#const("MaxScriptSize")], [16384], [Largest script, in bytes, that may enter a filter (`txscript.MaxScriptSize`).],
    [#const("HeaderCmtFilterIndex")], [0], [Leaf index of the filter hash in the header commitment Merkle tree.],
    [#const("MaxCFiltersV2PerBatch")], [100], [Most filters in one batched reply (`wire`; policy of the wire protocol).],
    [#const("MaxCFilterDataSize")], [262144], [Largest filter accepted in a filter message, $256 times 1024$ bytes (`wire`).],
    [#const("MaxHeaderProofHashes")], [32], [Most proof hashes accepted in a filter message (`wire`).],
  ),
) <tab:filters-constants>

The last three constants belong to the wire protocol, not to consensus. They
are listed because a light client needs them.

#rationale[
  For a given false-positive rate $1 slash M$ the size of a Golomb-coded set is
  minimized near $M approx 1.497137 dot 2^B$, not at the traditional
  $M = 2^B$; $M = 784931 = ceil(1.497137 dot 2^19)$ is that optimum for
  $B = 19$. #dcp(5) reports that, measured on the main chain up to block
  382280, this pair gave the smallest total of filter bytes plus bytes wasted
  downloading blocks after false positives, among the alternatives tried.
]

== SipHash-2-4 <sec:filters-siphash>

Every item is hashed with SipHash-2-4 @siphash, a keyed pseudorandom function
designed by Aumasson and Bernstein that maps a 128-bit key and a message of any
length to a 64-bit value. Keying the hash with a per-block value prevents an
attacker from crafting scripts that collide in every block's filter and so
cause false positives for a chosen victim everywhere.

The key is supplied as 16 bytes. It is split into two 64-bit words, each read
*little-endian*: $k_0 = "LE"^(-1)("key"[0:8])$ and
$k_1 = "LE"^(-1)("key"[8:16])$. The result is used as an unsigned 64-bit
integer, not as a byte string. @alg:filters-siphash is the complete function;
it is the standard SipHash-2-4 with 2 compression rounds per message word and
4 finalization rounds, and an implementation #MAY use any conforming library
provided the key and output conventions just stated are respected.

#algorithm("SipHash-2-4 with 64-bit output", src: "github.com/dchest/siphash · Hash (called from gcs/gcs.go · newFilter)")[
  ```python
  def rotl64(x: uint64, b: int) -> uint64:
      return uint64((x << b) | (x >> (64 - b)))

  def int_le(b: bytes) -> int:          # little-endian value of 0..8 bytes
      return sum(b[i] << (8 * i) for i in range(len(b)))

  def siphash24(k0: uint64, k1: uint64, m: bytes) -> uint64:
      v0 = k0 ^ 0x736f6d6570736575
      v1 = k1 ^ 0x646f72616e646f6d
      v2 = k0 ^ 0x6c7967656e657261
      v3 = k1 ^ 0x7465646279746573

      def sipround():                    # all additions wrap modulo 2^64
          nonlocal v0, v1, v2, v3
          v0 = uint64(v0 + v1); v1 = rotl64(v1, 13); v1 ^= v0; v0 = rotl64(v0, 32)
          v2 = uint64(v2 + v3); v3 = rotl64(v3, 16); v3 ^= v2
          v0 = uint64(v0 + v3); v3 = rotl64(v3, 21); v3 ^= v0
          v2 = uint64(v2 + v1); v1 = rotl64(v1, 17); v1 ^= v2; v2 = rotl64(v2, 32)

      n = len(m)
      full = n - n % 8
      for i in range(0, full, 8):        # each complete 8-byte word
          w = int_le(m[i:i + 8])
          v3 ^= w
          sipround(); sipround()
          v0 ^= w
      # Final word: the 0..7 remaining bytes, little-endian, with the message
      # length modulo 256 in the most significant byte.
      w = ((n % 256) << 56) | int_le(m[full:n])
      v3 ^= w
      sipround(); sipround()
      v0 ^= w
      v2 ^= 0xff
      sipround(); sipround(); sipround(); sipround()
      return v0 ^ v1 ^ v2 ^ v3
  ```
] <alg:filters-siphash>

#vector[SipHash-2-4][
  ```
  key       000102030405060708090a0b0c0d0e0f
  k0, k1    0x0706050403020100, 0x0f0e0d0c0b0a0908
  message                                  result (uint64)
  (empty)                                  0x726fdb47dd0e0e31
  00                                       0x74f839c593dc67fd
  00010203040506                           0xab0200f58b01d137
  0001020304050607                         0x93f5f5799a932462
  000102030405060708                       0x9e0082df0ba9e4b0
  000102030405060708090a0b0c0d0e           0xa129ca6149be45e5
  00 01 02 ... 3e (63 bytes)               0x958a324ceb064572
  ```
  The 15-byte case is the reference vector of the SipHash paper, whose output
  bytes `e5 45 be 49 61 ca 29 a1` are the little-endian encoding of the
  integer shown.
]

== Golomb-Coded Sets <sec:filters-gcs>

A Golomb-coded set (GCS) is a compressed, sorted list of small hash values. To
test whether an item is in the set, one hashes it the same way and looks for
the value in the list. Items in the set always match; an item not in the set
matches with probability about $1 slash M$. The construction here is the one
dcrd calls a *version 2* GCS; the obsolete version 1 is described in
@sec:filters-v1.

A version 2 GCS is parameterized by the remainder bit size $B$
($0 <= B <= 32$), the false-positive parameter $M$ (an unsigned 64-bit
integer), a 16-byte SipHash key and the list of items. Block filters always use
$B = 19$ and $M = 784931$ (@rule:filters-params); the general algorithm is
given because the code is written for general parameters and because the test
vectors exercise them.

=== Construction <sec:filters-gcs-build>

#algorithm("Version 2 GCS construction", src: ("gcs/gcs.go · newFilter", "gcs/bits.go · bitWriter"))[
  ```python
  def gcs_build(B: int, M: uint64, key: bytes, items: list[bytes]) -> bytes:
      if len(items) > 2**31 - 1:          # counted before any item is dropped
          fail("ErrNTooBig")
      k0 = int_le(key[0:8]); k1 = int_le(key[8:16])

      # 1. Hash the non-empty items, keeping only the first occurrence of each
      #    distinct 64-bit hash value.
      hashes, seen = [], set()
      for x in items:
          if len(x) == 0:
              continue
          h = siphash24(k0, k1, x)
          if h in seen:
              continue
          seen.add(h)
          hashes.append(h)
      N = len(hashes)
      if N == 0:
          return bytes()                   # the empty filter is zero bytes long

      # 2. Map each hash into [0, N*M) with the multiply-and-shift reduction:
      #    the high 64 bits of the full 128-bit product.
      NM = uint64(N * M)
      values = sorted((h * NM) >> 64 for h in hashes)

      # 3. Golomb-Rice code the differences between consecutive values.
      bits = []
      prev = 0
      for v in values:
          d = v - prev                     # d >= 0; d == 0 is possible
          prev = v
          q = d >> B                       # quotient
          r = d & ((1 << B) - 1)           # remainder
          bits += [1] * q + [0]            # quotient in unary: q ones, then a zero
          bits += [(r >> i) & 1 for i in range(B - 1, -1, -1)]  # B bits, MSB first
      while len(bits) % 8 != 0:
          bits.append(0)                   # pad with zero bits to a whole byte
      body = bytes(sum(bits[8*j + i] << (7 - i) for i in range(8))
                   for j in range(len(bits) // 8))  # first bit -> bit 0x80

      # 4. Prefix the number of distinct hashes.
      return varint(N) + body
  ```
] <alg:filters-gcs>

Several details of @alg:filters-gcs are easy to get wrong and are spelled out
here.

/ Empty items: Zero-length items are discarded before hashing; they never
  affect the result.
/ Duplicates: Duplicates are removed by comparing the 64-bit SipHash values,
  before reduction. Identical items therefore count once, and so do distinct
  items whose SipHash values happen to collide. Two distinct hashes that
  reduce to the same value in $[0, N M)$ are *not* merged: both are coded, the
  second with a difference of zero (a single `0` bit followed by $B$ zero
  bits). $N$ is the number of distinct 64-bit hashes.
/ Item order: Because the hash values are sorted and duplicates are removed
  by value, the output depends only on the set of non-empty items, not on
  their order or multiplicity. An implementation may collect items in any
  order.
/ Reduction: $N dot M$ is computed as an unsigned 64-bit product. For block
  filters it cannot wrap, since $N < 2^31$ and $M < 2^20$. The reduced value is
  $floor(h dot N M slash 2^64)$, computed exactly with a 128-bit product; it is
  not $h mod N M$.
/ Bit order: Bits are written into each byte starting at the most significant
  bit (`0x80`) and ending at the least significant bit (`0x01`), and bytes are
  filled in order. The remainder is written most significant bit first.
/ Unary polarity: The quotient $q$ is written as $q$ one-bits followed by one
  zero-bit. A quotient of zero is the single bit `0`.
/ Padding: The final partial byte is filled with zero bits. No length or
  terminator other than $N$ is stored.
/ Count: $N$ is written with the variable-length integer encoding of
  #xref("sec:encoding-varint"), in its canonical (shortest) form. For
  $N < 253$ it is a single byte.
/ Empty set: If no item survives step 1, the serialized filter is the empty
  byte string. In particular it is *not* the one-byte string `00` that
  `varint(0)` would give.

The `ErrNTooBig` limit applies to the raw number of items, before empty
items and duplicates are removed. It cannot be reached by a block: even a
block made entirely of one-byte outputs is far smaller than $2^31$ items.
If it were reached, dcrd would reject the block (@rule:filters-prevscripts
describes the same failure path).

#figure(
  caption: [Golomb–Rice code word for a difference $d$ with $B = 19$. A
  filter body is the concatenation of the code words of all $N$ differences,
  followed by zero padding to a byte boundary.],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Part], [Length (bits)], [Content], [Example: $d = 1110803$]),
    [Quotient], [$q + 1$], [$q$ ones, then one zero, where $q = floor(d slash 2^19)$], [$q = 2$: `110`],
    [Remainder], [$B = 19$], [$r = d mod 2^19$, most significant bit first], [$r = 62227$: `0001111001100010011`],
  ),
) <tab:filters-rice>

=== Filter Hash <sec:filters-gcs-hash>

The *hash* of a serialized filter $F$ is

$ "FilterHash"(F) = cases(
  "32 zero bytes" & "if" |F| = 0,
  "BLAKE256"(F) & "otherwise",
) $ <eq:filters-hash>

where BLAKE-256 is applied to the complete serialization, including the
leading item count. The hash is a 32-byte string in internal byte order; its
display form is reversed like any other hash (#chref("conventions")).

#pitfall[
  The hash of the empty filter is 32 zero bytes, not BLAKE-256 of the empty
  string (`716f6e86...`). Conversely, a filter that some peer encodes as the
  single byte `00` hashes to `0ce8d4ef...` and will not verify against a
  commitment to an empty filter. Block filters are not empty in practice,
  since coinbase transactions carry non-empty output scripts, but the rule
  matters to general-purpose implementations and to tests. #dcp(5) does not
  state this exception: read literally, its construction steps write
  `varint(N)` even for $N = 0$ and its commitment is BLAKE-256 of that
  serialization. dcrd, which produces the empty string and the all-zero hash,
  is authoritative.
]

=== Matching <sec:filters-match>

Matching is performed only by light clients and is not part of consensus. It
is specified so that clients agree with dcrd on the meaning of a filter.

To test a single item $x$ against a serialized filter $F$ built with key $k$:
if $F$ or $x$ is empty, the result is _no match_. Otherwise read $N$ from the
front of $F$, compute $t = floor("siphash24"(k_0, k_1, x) dot N M slash 2^64)$,
and decode the code words in order, keeping a running sum $s$ of the decoded
differences. Each running sum is one of the set's values; report a match as
soon as $s = t$, and no match as soon as $s > t$ or the bits are exhausted.

#algorithm("GCS membership test for one or several items (informative)", src: ("gcs/gcs.go · filter.Match", "gcs/gcs.go · filter.MatchAny", "gcs/bits.go · bitReader"))[
  ```python
  def gcs_match_any(B: int, M: uint64, key: bytes, F: bytes, xs: list[bytes]) -> bool:
      xs = [x for x in xs if len(x) > 0]
      if len(F) == 0 or len(xs) == 0:
          return False
      N, off = read_varint(F)            # canonical varint; else the filter is malformed
      NM = uint64(N * M)
      k0 = int_le(key[0:8]); k1 = int_le(key[8:16])
      targets = sorted((siphash24(k0, k1, x) * NM) >> 64 for x in xs)
      reader = BitReader(F[off:])          # reads bits from 0x80 down to 0x01
      s, t = 0, 0
      for _ in range(N):
          q = 0
          while reader.bit() == 1:         # end of data: return False
              q += 1
          r = reader.bits(B)               # B bits, MSB first; end of data: False
          s += (q << B) + r
          while t < len(targets) and targets[t] < s:
              t += 1                       # this target is not in the set
          if t == len(targets):
              return False
          if targets[t] == s:
              return True
      return False
  ```
] <alg:filters-match>

A single-item test is the special case of a one-element list. The probability
that a given item not in the set matches is close to $1 slash M$, about one in
785 000 for block filters; testing $k$ items at once multiplies it by roughly
$k$.

#note[
  Two behaviours of dcrd's matcher are worth knowing about, although neither
  affects consensus. Its single-item matcher does not stop after $N$ values
  but reads until a value exceeds the target or the data ends; since the
  padding consists of zero bits, any extra values it decodes repeat the last
  value and cannot change the result. Its multi-item matcher, at the pinned
  commit, drops empty query items but bounds its walk through the remaining
  sorted query values by the length of the _unfiltered_ list. When the list
  contains an empty item, no query value matches, and some value in the
  filter exceeds every query value, it reads past the end of its value list
  and panics with an index-out-of-range runtime error instead of returning
  _no match_. Clients should not pass empty items.
]

=== Maximum Size <sec:filters-maxsize>

The largest filter that $N$ distinct items can produce occurs when every
difference but one is zero and the remaining one is $N M - 1$. It occupies

$ ceil((N + N B + floor((N M - 1) slash 2^B)) / 8) + |"varint"(N)| $

bytes (`gcs.MaxFilterV2Size`). For block filters this works out to about
$(N dot 20 + 1.5 N) slash 8$ bytes in the worst case. dcrd's tests evaluate
this bound for $N = floor(1310720 \/ 14) = 93622$, the number of outputs with
a 3-byte script (11 bytes of output framing plus the script) that fit in the
largest block any network's wire protocol accepts (`wire.MaxBlockPayload`),
ignoring header and transaction overhead, and obtain 251 581 bytes. That is
not the largest item count of a valid block, because an output may carry a
one- or two-byte script. The count is nevertheless bounded: a regular-tree
output script must parse as a version 0 script and contain no stake opcode
(#chref("transactions")), which leaves 174 one-byte and 30 533 two-byte
scripts (171 and 29 498 once the `treasury` agenda is active); those that
contain signature opcodes are limited by the 5000 signature operations of a
block; and a block of that size needs at least two transactions and 334
bytes outside its outputs. No block can therefore contribute more than
95 769 distinct items, for which the bound is 257 350 bytes; the bound first
exceeds the wire protocol's limit of $256 times 1024 = 262144$ bytes per
filter (@sec:filters-spv) at $N = 97554$. Every block filter thus fits in a
filter message on every network; on the main network, whose blocks are at
most 393 216 bytes, filters stay below 82 000 bytes. dcrd does not check the
size of a filter when it validates or stores a block: a larger filter would
not make the block invalid, but dcrd could not serve it, since encoding the
`cfilterv2` or `cfiltersv2` message fails and the requesting peer is
disconnected.
An ordinary filter takes about $B + 2.05 approx 21.05$ bits per distinct
item.

=== Version 1 Filters <sec:filters-v1>

#history[
  Before #dcp(5), dcrd built and served uncommitted *version 1* filters. They
  differ from version 2 in four ways: the false-positive parameter is tied to
  the bin size ($M = 2^P$ with a single parameter $P <= 32$); values are
  reduced with $h mod N M$ instead of the multiply-and-shift method; empty
  items and duplicate hashes are *not* removed, so $N$ is simply the number of
  items; and $N$ is serialized as a 4-byte big-endian integer. The filter hash
  was BLAKE-256 of the serialization (zero for an empty filter), and clients
  chained filters with a _filter header_
  $"BLAKE256"("FilterHash" || "previous filter header")$. The `gcs` package
  still implements version 1 GCS construction and the filter header, but the
  pinned dcrd no longer builds version 1 block filters, no longer advertises
  the `SFNodeCF` service flag, and answers the version 1 requests
  `getcfilter`, `getcfheaders` and `getcftypes` by disconnecting the peer (and
  banning it if its protocol version is at least 6 and banning is enabled).
  Version 1 filters have no current role and are not part of consensus.
]

== Block Filter Contents <sec:filters-contents>

This section defines the list of items that enters a block's filter. It is the
most intricate part of the construction and the part where a mistake splits
the chain: an item missing or extra, a stake tag not removed, or a script
included in the wrong form all change the filter hash.

The items are, almost exclusively, *public key scripts* (output scripts). For
each output the block creates, the filter normally contains that output's
script; for each input that spends an earlier output, it normally contains the
script of the output being spent. A light client can therefore find both the
payments it receives and the spends of its own coins by testing its own
scripts. The filter contains no transaction hashes, outpoints or amounts.

=== Parameters and Key <sec:filters-key>

#rule("Version 2 block filter", src: ("gcs/blockcf2/blockcf.go · Regular", "gcs/blockcf2/blockcf.go · Key"))[
  The version 2 filter of a block #MUST be
  `gcs_build(19, 784931, key, items)` (@alg:filters-gcs), where `items` is
  the list produced by @alg:filters-items for the block, and `key` is the
  first 16 bytes, in internal byte order, of the block header's `MerkleRoot`
  field (header bytes 36 through 51).
] <rule:filters-params>

The key is taken from the `MerkleRoot` field _as it appears in the header_,
whatever that field means for the block: the regular-tree Merkle root before
#dcp(5) and the combined root of both trees afterwards
(#xref("sec:encoding-roots")). After #dcp(5) the key therefore depends on
every transaction in the block.

=== Predicates <sec:filters-predicates>

Two predicates on scripts govern which scripts are admitted and in what form.

*Excluded scripts.* A script with script version $v$ is _excluded_ if
$v != 0$, or it is empty, or it is longer than #const("MaxScriptSize") = 16384
bytes. The exclusion predicate is applied to regular-tree output scripts and
to every spent script; it is not applied to stake-tree output scripts, whose
forms are fixed by consensus (all of them have script version 0).

*Stake-tagged scripts.* Outputs of stake transactions carry a one-byte
_stake tag_ opcode in front of an otherwise ordinary pay-to-pubkey-hash or
pay-to-script-hash script (#chref("script")). So that a client need test only
its plain scripts, the tag is removed. A script $s$ with version $v$ is
_stake-tagged_ if and only if all of the following hold:

- $v = 0$ and $|s| >= 1$;
- $s[0]$ is one of `OP_SSTX` (`0xba`), `OP_SSGEN` (`0xbb`), `OP_SSRTX`
  (`0xbc`), `OP_SSTXCHANGE` (`0xbd`) or `OP_TGEN` (`0xc3`);
- $s[1:]$ is a pay-to-pubkey-hash script, exactly the 25 bytes
  `76 a9 14` $h_20$ `88 ac`, or a pay-to-script-hash script, exactly the 23
  bytes `a9 14` $h_20$ `87`, where $h_20$ is any 20 bytes.

`OP_TADD` (`0xc1`), `OP_TSPEND` (`0xc2`) and all other opcodes are not stake
tags for this purpose.

For a *spent* script the tag is removed only when the spending input's
outpoint names the stake tree *and* the script is stake-tagged. For a
*stake-tree output*, the first byte of the script is removed unconditionally,
whatever it is (@alg:filters-items, `add_stake_out`).

=== The Item List <sec:filters-item-list>

The spent scripts depend on the state of the unspent transaction output set,
which a full node has at hand when it connects the block. For an input $i$,
let $"prev"(i)$ be the script version and public key script of the output
that $i$ spends, that is, of the output named by $i$'s previous outpoint
(transaction hash, output index and tree), as it is found when the input is
validated. An output created by an earlier transaction of the same block
qualifies, and so does, in the historical blocks of
#xref("sec:transactions-sbss"), output 0 of a regular transaction of the same
block that a stake transaction spends, although the stake tree is processed
before the regular tree. An output restored to the set because the block
disapproves its parent's regular tree (#chref("blocks")) qualifies too. Being
spent does not remove an output's script from consideration: inputs of the
block that spend outputs created in the same block contribute those outputs'
scripts. An implementation that builds the item list only after all of the
block's transactions have been applied, as dcrd does, has every such output
at hand.

#algorithm("Items of the version 2 block filter", src: "gcs/blockcf2/blockcf.go · Regular, excludeFromFilter, isStakeOutput, commitmentConverter.paymentScript, Entries")[
  ```python
  STAKE_TAGS = {0xba, 0xbb, 0xbc, 0xbd, 0xc3}   # SSTX SSGEN SSRTX SSTXCHANGE TGEN
  TREE_REGULAR, TREE_STAKE = 0, 1

  def excluded(ver, s):
      return ver != 0 or len(s) == 0 or len(s) > 16384

  def is_p2pkh(s):
      return len(s) == 25 and s[0:3] == b"\x76\xa9\x14" and s[23:25] == b"\x88\xac"

  def is_p2sh(s):
      return len(s) == 23 and s[0:2] == b"\xa9\x14" and s[22] == 0x87

  def is_stake_tagged(ver, s):
      return (ver == 0 and len(s) >= 1 and s[0] in STAKE_TAGS
              and (is_p2pkh(s[1:]) or is_p2sh(s[1:])))

  def add_spent(items, txin):
      ver, s = prev(txin)                  # see Rule "Spent scripts"
      if excluded(ver, s):
          return
      if txin.prev_out.tree == TREE_STAKE and is_stake_tagged(ver, s):
          items.append(s[1:])
      else:
          items.append(s)

  def add_stake_out(items, s):
      if len(s) > 0:
          items.append(s[1:])              # drop the first byte, whatever it is

  def commitment_payment_script(c):        # c: a ticket commitment output script
      h = c[2:22]                          # 20-byte hash
      if c[29] & 0x80:                     # top bit of the 8-byte LE amount field
          return b"\xa9\x14" + h + b"\x87"                  # pay-to-script-hash
      return b"\x76\xa9\x14" + h + b"\x88\xac"              # pay-to-pubkey-hash

  def block_filter_items(block) -> list[bytes]:
      items = []
      for i, tx in enumerate(block.regular_txs):
          for out in tx.outputs:
              if not excluded(out.version, out.script):
                  items.append(out.script)          # unchanged, never stripped
          if i == 0:
              continue                              # coinbase: inputs skipped
          for txin in tx.inputs:
              add_spent(items, txin)

      for tx in block.stake_txs:
          t = stake_tx_type(tx)
          if t == TICKET:
              for txin in tx.inputs:
                  add_spent(items, txin)
              for j, out in enumerate(tx.outputs):
                  if j == 0:
                      continue                      # voting rights: never included
                  if j % 2 == 0:                    # change output
                      if out.value != 0:
                          add_stake_out(items, out.script)
                  elif len(out.script) > 0:         # commitment output
                      items.append(commitment_payment_script(out.script))
          elif t == VOTE:
              for out in tx.outputs[2:]:
                  add_stake_out(items, out.script)
          elif t == REVOCATION:
              for out in tx.outputs:
                  add_stake_out(items, out.script)
          elif t == TREASURY_ADD:
              for txin in tx.inputs:
                  add_spent(items, txin)
              if len(tx.outputs) == 2 and tx.outputs[1].value != 0:
                  add_stake_out(items, tx.outputs[1].script)
          elif t == TREASURY_SPEND:
              for out in tx.outputs[1:]:
                  add_stake_out(items, out.script)
          # TREASURYBASE: contributes nothing
      return items
  ```
] <alg:filters-items>

Here `stake_tx_type` is the classification of stake transactions of
#chref("staking") and #chref("treasury"), applied in dcrd's order: ticket,
vote, revocation, and then, only for transactions whose version is at least
3, treasury add, treasury spend and treasurybase. In a valid block every
transaction of the stake tree is of one of these six types, so the regular
type never arises there.

#rule("Spent scripts", src: ("gcs/blockcf2/blockcf.go · Regular", "internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/utxoviewpoint.go · UtxoViewpoint.PrevScript"))[
  For every input from which @alg:filters-items takes a spent script (every
  input of every regular-tree transaction except the first, every input of a
  ticket, and every input of a treasury add), $"prev"(i)$ is the script
  version and public key script of the output that input spends, in the
  unspent output set of the point of view in which the block's transactions
  are connected, including outputs created earlier in the same block, the
  outputs made spendable by #xref("rule:transactions-sbss"), and outputs restored by
  disapproval of the parent's regular tree. dcrd evaluates this after all of
  the block's transactions have been connected; an output stays available for
  this purpose after an input of the same block spends it. If that output
  does not exist, the filter cannot be built and the block #MUST be rejected
  (dcrd reports `ErrMissingTxOut`). Inputs of votes, revocations, treasury
  spends and treasurybases, and the input of the coinbase, are never looked
  up.
] <rule:filters-prevscripts>

Because every input of a valid block spends an existing output, the failure
case of @rule:filters-prevscripts is not reachable for a block that passes the
input checks of #chref("transactions"), which dcrd applies first.

@tab:filters-contents summarizes @alg:filters-items by transaction class.

#figure(
  caption: [Items contributed to the version 2 block filter by each transaction
  class. "Stripped" means that the first byte (the stake tag) is removed.],
  table(
    columns: (auto, 1fr, 1fr),
    table.header([Transaction], [Outputs], [Spent scripts]),
    [Coinbase (regular tree, index 0)], [Every output script not excluded, unchanged, including `OP_RETURN` scripts.], [None.],
    [Other regular-tree transaction], [Every output script not excluded, unchanged, including `OP_RETURN` scripts.], [Every input's spent script not excluded; stripped if the outpoint's tree is the stake tree and the script is stake-tagged.],
    [Ticket], [Output 0 (voting rights): never. Odd outputs (commitments): converted to the P2PKH or P2SH script they commit to. Even outputs $>= 2$ (change): stripped, but only if the value is non-zero.], [As for regular transactions.],
    [Vote], [Outputs 0 (block reference) and 1 (vote bits): never. All outputs from index 2 on, stripped. This includes the reward outputs and, when present, the trailing treasury-vote `OP_RETURN` output.], [None (neither the stakebase nor the ticket).],
    [Revocation], [Every output, stripped.], [None.],
    [Treasury add], [Output 0 (`OP_TADD`): never. Output 1 (change), if the transaction has exactly two outputs and its value is non-zero: stripped.], [As for regular transactions.],
    [Treasury spend], [Output 0 (`OP_RETURN`): never. Every output from index 1 on (`OP_TGEN` payments), stripped.], [None.],
    [Treasurybase], [None.], [None.],
  ),
) <tab:filters-contents>

The rules for a ticket's commitment outputs need a word of explanation. A
ticket commitment output (#chref("staking")) is an `OP_RETURN` script whose
bytes 2 to 21 are a 20-byte hash and whose bytes 22 to 29 are an 8-byte
little-endian amount; the most significant bit of that amount, bit 7 of byte
29, is set when the hash is a script hash. The filter does not contain the
commitment script itself but the plain script that a vote or revocation will
later pay: `OP_HASH160 OP_DATA_20` $h$ `OP_EQUAL` if the flag is set,
otherwise `OP_DUP OP_HASH160 OP_DATA_20` $h$ `OP_EQUALVERIFY OP_CHECKSIG`.
Only those fixed byte positions are read; consensus guarantees that a ticket's
odd outputs are at least 32 bytes long.

#rationale[
  The voting-rights output of a ticket, and the references to it in votes and
  revocations, are left out on purpose. A light client does not have the full
  blocks and cannot judge their validity, so it should not vote; leaving the
  voting rights out of the filters makes "SPV voting" impractical. A client
  can still discover its tickets through their commitment and change outputs
  (#dcp(5)).
]

#pitfall[
  The filter contents in dcrd differ from the text of #dcp(5) in three ways,
  and dcrd is authoritative:
  - A ticket change output with value zero is *not* included. #dcp(5) lists
    change outputs without qualification.
  - Treasury adds and treasury spends contribute items as listed above. They
    were introduced later by #dcp(6) and are not mentioned in #dcp(5).
  - A vote that carries treasury-spend votes has a final output of the form
    `OP_RETURN` _push_ `'T' 'V'` ... (#chref("treasury")). Because every
    vote output from index 2 on is passed to `add_stake_out`, this script
    enters the filter *with its first byte, `OP_RETURN`, removed*, so the item
    begins with the push opcode (for example `0x23` for one vote tuple pushed
    directly, or `0x4c` when `OP_PUSHDATA1` is used, as it must be for three
    or more tuples).
  In addition, #dcp(5) states its two special cases more broadly than dcrd
  applies them: it applies the exclusion of non-version-0, empty and oversized
  scripts to every item of both trees, whereas dcrd applies it only to
  regular-tree outputs and spent scripts; and it removes the stake tag of
  stake-tree outputs also when they are spent, whereas dcrd removes the first
  byte of a spent script only under the exact conditions of
  @sec:filters-predicates. The conditions of this chapter are dcrd's.
]

#pitfall[
  Further traps in @alg:filters-items:
  - Regular-tree output scripts are never stripped, even if they begin with a
    stake tag opcode, and are filtered with the exclusion predicate. Stake-tree
    output scripts are always stripped and are not checked against the
    exclusion predicate.
  - Whether a spent script is stripped depends on the *tree field of the
    spending input's outpoint* and on the exact tagged P2PKH/P2SH form. A
    stake-tree output whose script is not of that form is included unchanged.
  - `OP_RETURN` outputs of regular transactions, including the coinbase's,
    *are* included (the comment in dcrd's own summary of the rules says
    "provably unspendable" scripts are excluded; the code includes them,
    except for zero-value ticket change).
  - The first regular transaction's inputs are skipped by position, and its
    outputs are processed like any other regular transaction's.
  - The filter of a block always describes that block's own regular tree, even
    if a later block disapproves it. Disapproval of the *parent* affects only
    which outputs the block's inputs may spend.
  - Spent scripts are included even when the spent output was created in the
    same block; and an item that occurs several times (for example a script
    that is both created and spent in the block) counts once.
]

#history[
  Filters exist for every block, including blocks before the activation of
  `headercommitments`, and are computed with the same rules for all of them.
  Treasury transactions cannot occur before the `treasury` agenda
  (#dcp(6)) is active, so no special condition is needed for them. The
  genesis block's filter is computed by the same algorithm with no spent
  scripts (it has only a coinbase); it is stored and served but never
  checked, since the genesis block is valid by definition and predates the
  commitment.
]

== Header Commitments <sec:filters-commitments>

#dcp(5) introduced a general mechanism by which a block header commits to
arbitrary per-block data structures, and used it first for the block filter.
The header's `StakeRoot` field (header bytes 68 through 99), which until then
held the Merkle root of the stake transaction tree, was repurposed to hold the
*commitment root*: the Merkle root of a tree whose leaves are the hashes of
the individual commitments. The stake tree's root was folded into the
`MerkleRoot` field at the same time (#xref("sec:encoding-roots")). Future
agendas can add leaves without changing the header format.

=== Version 1 Commitment Root <sec:filters-cmt-root>

The leaves of the commitment tree are defined by a commitment _version_. The
only version so far, version 1, has a single leaf, the hash of the version 2
block filter, at leaf index #const("HeaderCmtFilterIndex") = 0. The Merkle root
of a one-leaf tree is the leaf itself (#chref("crypto")), so

$ "CommitmentRoot"_1 = "FilterHash"("block filter") $ <eq:filters-cmtroot>

with FilterHash from @eq:filters-hash.

#rule("Header commitment root", src: ("internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/headercmt.go · CalcCommitmentRootV1", "internal/blockchain/agendas.go · isHeaderCommitmentsAgendaActive"))[
  If the `headercommitments` agenda (#dcp(5)) is active for a block, as
  determined from the block's parent by the rules of #chref("voting"), the
  block header's `StakeRoot` field #MUST equal, byte for byte, the version 1
  commitment root of @eq:filters-cmtroot: the BLAKE-256 hash of the block's
  serialized version 2 filter (@rule:filters-params), or 32 zero bytes if that
  serialization is empty. A block that violates this rule is invalid (dcrd
  reports `ErrBadCommitmentRoot`).
] <rule:filters-cmtroot>

If the agenda is not active for the block, `StakeRoot` holds the stake-tree
Merkle root instead and no filter commitment is enforced (#xref("rule:encoding-roots-original")).
The point in block validation at which dcrd evaluates @rule:filters-cmtroot,
after all transactions of the block have been connected to the unspent output
view, is given in #chref("blocks")\; the result does not depend on it, except
that the spent scripts must be those of @rule:filters-prevscripts. dcrd builds
the filter, and checks the commitment when the agenda is active, as part of
the full validation of every block, including ancestors of the assumed-valid
block for which it skips script validation; no network, height or flag
exempts a block from @rule:filters-cmtroot once the agenda is active for it.

#history[
  `headercommitments` was voted in on the main network with block 431488 as
  the first block for which it is active (its parent, block 431487, has hash
  #hex("0000000000000000225b8f795704d4ebc484fad4ab09eec615fb44b4a95c3c26"));
  on testnet3 the first such block is 323328. An implementation must
  determine activation from the chain as described in #chref("voting").
]

#rationale[
  #dcp(5) chose to repurpose `StakeRoot` rather than add a field so that the
  header keeps its size and the offsets of all mining-related fields, leaving
  mining hardware and software unaffected. Building a Merkle tree over the
  commitments, even with one leaf, means that a client can later be given a
  short proof for any single commitment without receiving the others.
]

=== Inclusion Proofs <sec:filters-proofs>

An *inclusion proof* for a commitment consists of a 32-bit *proof index*, the
leaf index of the commitment, and a list of *proof hashes*, the sibling hashes
met on the path from that leaf to the root, ordered from the leaf upward. With
a single leaf, as in version 1, the proof index is 0 and the proof hash list is
empty, and verifying the proof reduces to comparing the filter hash with
`StakeRoot`. The general algorithms below follow #dcp(5) and dcrd; the
underlying Merkle construction (pairwise BLAKE-256 of the concatenation, with
the last node of an odd level paired with itself) is that of #chref("crypto").
Proofs are not consensus data, but light clients and servers must agree on
them.

#algorithm("Generating and verifying a commitment inclusion proof", src: ("blockchain/standalone/inclusionproof.go · GenerateInclusionProof", "blockchain/standalone/inclusionproof.go · VerifyInclusionProof"))[
  ```python
  def generate_proof(leaves: list[bytes], index: uint32) -> list[bytes]:
      if len(leaves) == 0 or index >= len(leaves):
          return []
      level, proof = list(leaves), []
      while len(level) > 1:
          if len(level) % 2 == 1:
              level.append(level[-1])          # duplicate the last node
          proof.append(level[index - 1] if index % 2 == 1 else level[index + 1])
          level = [blake256(level[j] + level[j + 1]) for j in range(0, len(level), 2)]
          index >>= 1
      return proof

  def verify_proof(root: bytes, leaf: bytes, index: uint32, proof: list[bytes]) -> bool:
      if len(proof) > 32:
          return False
      if index > (1 << len(proof)) - 1:        # index must fit in len(proof) bits
          return False
      cur = leaf
      for p in proof:
          cur = blake256(p + cur) if index % 2 == 1 else blake256(cur + p)
          index >>= 1
      return cur == root
  ```
] <alg:filters-proof>

#note[
  dcrd stores the commitment leaves of a block only if `headercommitments` is
  active for it. For earlier blocks it still serves the filter, with proof
  index 0 and an empty proof, but such a "proof" proves nothing: the header's
  `StakeRoot` is then the stake-tree root, and the filter cannot be checked
  against the header.
]

== Light Clients <sec:filters-spv>

_This section is informative._ It describes how a light client, often called
an SPV (simplified payment verification) client, uses headers, filters and
proofs, and what it can and cannot verify. dcrd implements the serving side;
the client side described here is an outline of how a light client works,
not a consensus requirement.

=== Synchronizing Headers <sec:filters-spv-headers>

The client first downloads the chain of block headers from its peers
(`getheaders` and `headers`, #chref("p2p")). For each header it can check
everything that depends only on headers: the link to the previous header, the
proof of work against the header's `Bits` and the difficulty schedule
(#chref("difficulty")), the timestamps, and the stake difficulty `SBits`,
whose calculation (#chref("difficulty")) uses only fields of earlier headers.
It follows the valid header chain with the most cumulative work.

Decred's hybrid design puts several facts in the header that a client without
the blocks cannot check: that the `Voters` count matches the votes actually
included and that those votes were cast by the tickets the lottery selected,
the `FreshStake`, `Revocations` and `PoolSize` counts, the lottery state
`FinalState`, and the treasury and agenda consequences of the votes. The
header-only checks above rest on these fields, which are verified only by full
nodes. A client therefore trusts, in addition to the proof of work, that the
stakeholders' votes that miners include are genuine; an attacker must control
both a majority of the hash power and enough tickets to vote on its blocks to
deceive it.

The `VoteBits` field of a block's header tells whether the block's votes
approved the regular transaction tree of its *parent* (bit 0 set means
approved; #chref("blocks")). A client that finds a relevant transaction in the
regular tree of block $h$ should treat it as confirmed only if the header of
block $h + 1$ approves the parent, since a disapproved regular tree has no
effect on the ledger.

=== Fetching and Verifying Filters <sec:filters-spv-fetch>

Filters are requested with the messages of @tab:filters-msgs, whose encodings
are given in #chref("p2p"). dcrd ignores, without replying, a request for a
block it does not have, a batched request whose start block is not an
ancestor of its end block, and a batch of more than 100 blocks.

#figure(
  caption: [Peer-to-peer messages for version 2 filters],
  table(
    columns: (auto, auto, 1fr),
    table.header([Message], [Since protocol version], [Contents and use]),
    [`getcfilterv2`], [7], [Block hash. Requests the filter of one block.],
    [`cfilterv2`], [7], [Block hash, serialized filter (at most 262144 bytes), proof index (`uint32`), proof hashes (at most 32). Reply to `getcfilterv2`.],
    [`getcfsv2`], [11], [Start and end block hashes. Requests the filters of a chain segment, both ends included, at most 100 blocks.],
    [`cfiltersv2`], [11], [A list of at most 100 `cfilterv2` bodies, in chain order from the start block. Reply to `getcfsv2`.],
  ),
) <tab:filters-msgs>

The same data is available from dcrd's JSON-RPC interface (`getcfilterv2`),
with the filter in hexadecimal.

For each received filter the client verifies the commitment against a header
it has already accepted:

#algorithm("Verifying a received filter against its header (informative)", src: ("blockchain/standalone/inclusionproof.go · VerifyInclusionProof", "internal/blockchain/headercmt.go · FilterByBlockHash"))[
  ```python
  def verify_received_filter(header, msg) -> bool:
      if msg.block_hash != block_hash(header):
          return False
      if not headercommitments_active_for(header):
          return False                     # nothing to verify against
      if msg.proof_index != 0:             # HeaderCmtFilterIndex
          return False
      leaf = bytes(32) if len(msg.data) == 0 else blake256(msg.data)
      return verify_proof(header.stake_root, leaf, msg.proof_index, msg.proof_hashes)
  ```
] <alg:filters-spv-verify>

A client must check the proof index itself: the proof only shows that the
hash sits at the stated index, and only index 0 holds the filter.

=== Matching and Downloading Blocks <sec:filters-spv-match>

The client tests, against each block's filter, the set of scripts it is
watching, using `gcs_match_any` (@alg:filters-match) with $B = 19$,
$M = 784931$ and the key formed from the first 16 bytes of the header's
`MerkleRoot`. The watched set contains the plain P2PKH and P2SH scripts of
its addresses, which match both payments to it and, because spent scripts
are included, spends of its outputs; stake outputs are matched by the same
plain scripts because their tags are removed. On a match it downloads the
block (`getdata`, #chref("p2p")), checks that the block's transactions hash to
the header's `MerkleRoot` (#xref("sec:encoding-roots")), and scans the
transactions. Since each filter is committed, a peer cannot hide a relevant
transaction by serving a filter that omits it: the client detects the
mismatch and can ask another peer.

=== Security Model <sec:filters-spv-security>

A light client using committed filters relies on: the validity of the header
chain with the most work, and through it on the honesty of the majority of
miners and of the voting stakeholders, since it cannot validate transactions
or votes itself and Decred has no fraud proofs; connection to at least one
honest peer, so that it learns of the best chain; and the collision resistance
of BLAKE-256, which binds filters to headers. Filters reveal nothing about the
client's interests to the peers that serve them, but downloading particular
blocks does leak some information, mitigated by false positives and by
fetching blocks from several peers. Blocks from before the activation of
`headercommitments` have uncommitted filters, which a client can only trust or
replace by downloading those blocks.

== Test Vectors <sec:filters-vectors>

All vectors in this section were produced by running dcrd's `gcs`, `blockcf2`
and `blockchain/standalone` packages at the pinned commit. Hashes are shown in
internal byte order unless labelled "display".

=== Reduction <sec:filters-vec-reduce>

#vector[Multiply-and-shift reduction with $N M = 3 dot 784931 = 2354793$][
  ```
  x (uint64)             high 64 bits of x * 2354793
  0x0000000000000000     0
  0x0123456789abcdef     10465
  0x8000000000000000     1177396
  0xffffffffffffffff     2354792
  ```
]

=== A Small Filter, Step by Step <sec:filters-vec-small>

#vector[GCS with $B = 19$, $M = 784931$, key `000102...0f`][
  ```
  items:  "Alex" 416c6578 | "Bob" 426f62 | "" (empty) | "Charlie" 436861726c6965
          | "Bob" 426f62

  1. hash (k0 = 0x0706050403020100, k1 = 0x0f0e0d0c0b0a0908)
     "Alex"     0x78c2a5d04dd7e946
     "Bob"      0xb207e659424ba11f
     ""         skipped (empty)
     "Charlie"  0x9a67bfa9c1907c07
     "Bob"      0xb207e659424ba11f   duplicate hash: dropped
     N = 3, N*M = 2354793

  2. reduce (high 64 bits of h * 2354793)
     "Alex" -> 1110803    "Bob" -> 1637600    "Charlie" -> 1420282

  3. sort, take differences, split at 2^19 = 524288
     value     difference   q   r        code word (unary q, 0, r in 19 bits)
     1110803   1110803      2   62227    110 0001111001100010011
     1420282   309479       0   309479   0 1001011100011100111
     1637600   217318       0   217318   0 0110101000011100110
     total 62 bits, padded with 2 zero bits:
     11000011 11001100 01001101 00101110 00111001 11001101 01000011 10011000

  4. serialize: varint(3) || bit string
     filter        03c3cc4d2e39cd4398
     filter hash   b9a61f8ba0d6ce4d68a65684405d66aed7aee53a3f2989bc375854d5b1df3236
       (display)   3632dfb1d5545837bc89293f3ae5aed7ae665d408456a6684dced6a08b1fa6b9

  matching: "Alex" yes, "Bob" yes, "Charlie" yes, "Dave" no, "" no
            any of {"Dave", "Charlie"} yes; any of {"Dave", "Eve"} no
  ```
]

#vector[Empty filter][
  ```
  items          none, or only empty items (e.g. a single empty item)
  filter         (zero bytes)
  filter hash    0000000000000000000000000000000000000000000000000000000000000000
  for contrast:
  BLAKE-256("")  716f6e863f744b9ac22c97ec7b76ea5f5908bc5b2f67c61510bfc4751384ea7a
  BLAKE-256(00)  0ce8d4ef4dd7cd8d62dfded9d4edb0a774ae6a41929a74da23109e8f11139c87
  ```
]

=== Genesis Block Filters <sec:filters-vec-genesis>

The genesis block of each network contains only a coinbase with a single
output, so its filter has exactly one item.

#vector[Main network genesis block filter][
  ```
  block (display)  298e5cc3d985bfe7f81dc135f360abe089edd4396b86d2de66b0cef42b21d980
  MerkleRoot       0dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb99174aa66
  key              0dc101dfc3c6a2eb10ca0c5374e10d28
  item             coinbase output 0, version 0, 32 bytes:
                   801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9
  SipHash          0xdcc0d8901bf41c47
  N = 1, N*M = 784931, reduced 676859 = 1 * 2^19 + 152571 (q = 1, r = 152571)
  code word        10 0100101001111111011 + 3 padding bits
  filter           01929fd8
  filter hash      47a29cecacd4456da3eafb80e7d8b018a758efcbfe2ae8d4be2aa026c44fa569
    (display)      69a54fc426a02abed4e82afecbef58a718b0d8e780fbeaa36d45d4acec9ca247
  ```
  The genesis header's `StakeRoot` is 32 zero bytes (the root of its empty
  stake tree), not this hash: the genesis block predates the commitment.
]

#figure(
  caption: [Filters of the other networks' genesis blocks],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Filter], [Filter hash (internal order)]),
    [testnet3], [`01922e18`], [#hex("14316678bb53f2d2eb21a1169c5d96712d18a7bc808544ab139ec55f4a63bb35")],
    [simnet], [`01927598`], [#hex("4047ebc912b70262c4bb991ba452327109fb9575667f9ce37d24cb77e19079b6")],
    [regnet], [`01929fd8`], [#hex("47a29cecacd4456da3eafb80e7d8b018a758efcbfe2ae8d4be2aa026c44fa569") (same `MerkleRoot` and output as the main network)],
  ),
) <tab:filters-vec-genesis>

=== A Block With Every Transaction Class <sec:filters-vec-block>

The following synthetic block exercises every rule of @alg:filters-items. It
was built with dcrd's `wire` package; each stake transaction was confirmed to
be classified as stated by dcrd's `stake.DetermineTxType`. The notation
`P2PKH(aa)` is the pay-to-pubkey-hash script whose 20-byte hash consists of
the byte `aa` repeated, `P2SH(aa)` likewise, and `[tag]` a stake tag prefix.

#vector[Synthetic block: transactions][
  ```
  header MerkleRoot = 11 repeated 32 times; key = 11 repeated 16 times
  regular tree
    0 coinbase   out0 v0 6a0c40420f000000000000000000      out1 v0 P2PKH(a1)
    1 regular    in0 spends regular-tree P2PKH(b1)
                 in1 spends stake-tree [OP_SSGEN]P2PKH(b2)
                 in2 spends regular-tree P2PKH(b3) with script version 1
                 out0 P2SH(c1)   out1 6a (bare OP_RETURN)   out2 empty script
                 out3 P2PKH(c2) with script version 2      out4 P2PKH(a1)
  stake tree
    0 treasurybase  out0 c1 (OP_TADD)   out1 6a0c40420f000102030405060708
    1 ticket        in0 spends regular-tree P2PKH(b4)
                    in1 spends stake-tree [OP_SSTXCHANGE]P2SH(b5)
                    out0 [OP_SSTX]P2PKH(d0)
                    out1 commitment hash d1..d1, amount 600, P2PKH flag clear
                    out2 [OP_SSTXCHANGE]P2PKH(d2), value 0
                    out3 commitment hash d3..d3, amount 400, P2SH flag set
                    out4 [OP_SSTXCHANGE]P2PKH(d4), value 5
    2 vote (tx version 3)
                    out0 6a24 00..00   out1 6a020100   out2 [OP_SSGEN]P2PKH(e1)
                    out3 6a 23 5456 (e2 x 32) 01        (one treasury vote)
    3 revocation    out0 [OP_SSRTX]P2SH(e3)
    4 treasury add  in0 spends regular-tree P2PKH(b8)
                    out0 c1 (OP_TADD)   out1 [OP_SSTXCHANGE]P2PKH(f1), value 7
    5 treasury spend
                    out0 6a20 00..00    out1 [OP_TGEN]P2PKH(f2)
  ```
]

#vector[Synthetic block: items and filter][
  ```
  items (18; "P2PKH(a1)" occurs twice, so N = 17)
    6a0c40420f000000000000000000    coinbase out0 (OP_RETURN, included)
    P2PKH(a1)                       coinbase out1
    P2SH(c1)                        regular tx out0
    6a                              regular tx out1 (OP_RETURN, included)
    P2PKH(a1)                       regular tx out4 (duplicate)
    P2PKH(b1)                       spent by regular tx in0
    P2PKH(b2)                       spent by regular tx in1, tag stripped
    P2PKH(b4)                       spent by ticket in0
    P2SH(b5)                        spent by ticket in1, tag stripped
    P2PKH(d1)                       ticket out1, commitment converted
    P2SH(d3)                        ticket out3, commitment converted
    P2PKH(d4)                       ticket out4, change, stripped
    P2PKH(e1)                       vote out2, stripped
    235456e2e2...e2e201             vote out3, OP_RETURN byte stripped
    P2SH(e3)                        revocation out0, stripped
    P2PKH(b8)                       spent by treasury add in0
    P2PKH(f1)                       treasury add out1, stripped
    P2PKH(f2)                       treasury spend out1, stripped
  not included: regular tx out2 (empty), out3 (version 2), in2 (version 1);
    ticket out0 and out2 (zero change) and the raw commitment scripts;
    vote out0, out1 and the vote and revocation inputs; treasurybase outputs;
    treasury add out0; treasury spend out0

  filter       11 9032506d092db48491849d6975300e60449351e14fe0574bb476c8a0
                  7c0124116756998ff2720ae47d8c12bac0
  filter hash  d3f85d41a099da29efbc3e6d6162dc01092fa574e8dc8f964b544312561692e6
    (display)  e69216561243544b968fdce874a52f0901dc62616d3ebcef29da99a0415df8d3
  commitment root (if headercommitments were active) = filter hash;
  inclusion proof: index 0, no proof hashes
  ```
  Rebuilding the filter from the 18 listed items alone with
  `gcs_build(19, 784931, key, items)` gives the same bytes, and every listed
  item matches while none of the excluded scripts does.
]

=== Inclusion Proofs <sec:filters-vec-proofs>

The version 1 commitment has one leaf, so its proofs are empty. The following
vector illustrates @alg:filters-proof on a three-leaf tree, the shape a future
commitment version with three leaves would have.

#vector[Inclusion proofs over three leaves][
  ```
  leaf i = BLAKE-256 of the single byte i
  leaf 0    0ce8d4ef4dd7cd8d62dfded9d4edb0a774ae6a41929a74da23109e8f11139c87
  leaf 1    4a6c419a1e25c85327115c4ace586decddfe2990ed8f3d4d801871158338501d
  leaf 2    49af37ab5270015fe25276ea5a3bb159d852943df23919522a202205fb7d175c
  root      0135cd60725091a8795118c7ed50b8bf8a272707938a9fa7b24f0399bbe4a048
  proof for index 0:
            4a6c419a1e25c85327115c4ace586decddfe2990ed8f3d4d801871158338501d
            6eda2f28b5a79a4c793914418c1b337cf36f806cefb3a10163db703400fc4951
  proof for index 1:
            0ce8d4ef4dd7cd8d62dfded9d4edb0a774ae6a41929a74da23109e8f11139c87
            6eda2f28b5a79a4c793914418c1b337cf36f806cefb3a10163db703400fc4951
  proof for index 2:
            49af37ab5270015fe25276ea5a3bb159d852943df23919522a202205fb7d175c
            ad204769bc6f9a916299fe1af8d54828b7403e2dbe65c8888e16e9fa1deae0c5
  proof for index 3 (out of range): empty
  each of the three proofs verifies against the root
  ```
  Leaf 2 is paired with itself at the first level, so its first proof hash is
  the leaf itself.
]

#note[
  The test vectors of #dcp(5) for combined Merkle roots, commitment roots and
  inclusion proof generation and verification (in display byte order there)
  all pass against dcrd's `blockchain/standalone` package at the pinned
  commit, including the case of a 33-hash proof, which is rejected.
]
