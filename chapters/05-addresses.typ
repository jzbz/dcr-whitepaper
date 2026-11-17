#import "../template.typ": *

// A two-column key/value table for test vectors: arguments alternate between
// item and value. Long hex values wrap anywhere (use #hex).
#let kv(w: auto, ..cells) = table(
  columns: (w, 1fr),
  table.header([Item], [Value]),
  ..cells.pos()
)

= Keys and Addresses <ch:addresses>

An *address* is a short, checksummed text string that tells a payer how to
construct the output script that pays a particular recipient. Decred
addresses, private-key strings and hierarchical deterministic (HD) extended
keys all use the same building blocks: a 2- or 4-byte prefix that identifies
the network and the kind of object, a payload, a checksum built from
BLAKE-256, and the Base58 text encoding.

#note[
  *Nothing in this chapter is a consensus rule.* Blocks and transactions
  never contain addresses; consensus code sees only output scripts
  (#chref("script")). An address is a human-facing encoding of a script, and
  two nodes that disagree about addresses still agree about every block.
  The chapter must nevertheless be followed exactly by any software that
  exchanges addresses, keys or signed messages with other Decred software: a
  wrong prefix or template sends funds to a script nobody can spend. Where
  the keywords #MUST and #SHOULD appear below they express interoperability
  requirements, not validity of blocks. There are therefore no rule boxes in
  this chapter.
]

The reference behaviour is that of dcrd's packages `txscript/stdaddr`
(addresses and the scripts they produce), `dcrutil` (private keys, message
verification, amounts), `hdkeychain` (HD keys), `chaincfg` (per-network
prefixes) and the external module `github.com/decred/base58` v1.0.6, which
dcrd pins in its `go.mod`. Where wallet behaviour is described, it is that of
dcrwallet @dcrwallet and is labelled as a convention.

Throughout, $"BLAKE256"$ is the hash function of #chref("crypto") and
$ "HASH160"(x) = "RIPEMD160"("BLAKE256"(x)). $
This differs from Bitcoin's HASH160, which uses SHA-256 in place of
BLAKE-256, so Decred's key hashes, addresses and HD fingerprints differ
from their Bitcoin counterparts for the same key.

== Overview <sec:addresses-overview>

@tab:addresses-objects lists the encoded objects defined in this chapter.
All are Base58 strings over the same alphabet; they differ in prefix width,
payload and checksum.

#figure(
  caption: [Text-encoded objects],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, left, right),
    table.header([Object], [Prefix], [Payload], [Checksum (4 bytes)], [Chars]),
    [P2PK address (@sec:addresses-p2pk)], [2], [33], [$"BLAKE256"^2$], [53],
    [P2PKH or P2SH address], [2], [20], [$"BLAKE256"^2$], [35],
    [WIF private key (@sec:addresses-wif)], [2], [33], [$"BLAKE256"$ (single)], [53],
    [Extended key (@sec:addresses-hd)], [4], [74], [$"BLAKE256"^2$], [111 #super[a]],
  ),
) <tab:addresses-objects>

#text(size: 0.85em)[#super[a] 112 on regnet, whose extended-key version bytes begin with `0xea`.
All lengths are exact for every payload under the prefixes of
@tab:addresses-prefixes (verified by encoding all-zero and all-`0xff`
payloads).]

== Base58 and Base58Check <sec:addresses-base58>

=== The alphabet

Base58 represents a byte string as a number in base 58, written with the
58-character alphabet

```
123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
```

in which the character at (zero-based) position $i$ has value $i$. The
digits `0`, the capitals `I` and `O`, and the lowercase `l` are absent to
avoid visual confusion. This is the same alphabet Bitcoin uses @base58.

=== Encoding and decoding

The encoding treats the input as a big-endian unsigned integer and writes it
in base 58, most significant digit first. Because leading zero bytes do not
change the integer, each leading `0x00` byte is written as one leading `1`
(the digit for zero) so that the encoding is reversible.

#algorithm("Base58 encoding and decoding", src: "github.com/decred/base58 · Encode, Decode")[
  ```python
  ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  def base58_encode(b: bytes) -> str:
      n = int_from_be(b)                  # 0 for the empty string
      digits = ""
      while n > 0:
          digits = ALPHABET[n % 58] + digits
          n = n // 58
      zeros = count_leading(b, 0x00)      # number of leading zero bytes
      return "1" * zeros + digits

  def base58_decode(s: str) -> bytes:
      if s == "":
          return b""
      zeros = count_leading(s, "1")       # number of leading '1' characters
      n = 0
      for c in s[zeros:]:
          if c not in ALPHABET:
              return b""                  # invalid character: empty result, no error
          n = n * 58 + ALPHABET.index(c)
      body = be_minimal(n)                # big-endian, no leading zeros; b"" if n == 0
      return b"\x00" * zeros + body
  ```
] <alg:addresses-base58>

#pitfall[
  The decoder reports an invalid character by returning an empty byte
  string, not an error. Every caller in dcrd then rejects the result because
  its length is wrong, so the observable effect is a "malformed" or "invalid
  format" error rather than an "invalid character" error.
]

#vector[Base58][
  #table(
    columns: (1fr, 1fr, 1fr, 1fr),
    table.header([Bytes (hex)], [Base58], [Bytes (hex)], [Base58]),
    [(empty)], [(empty)], [`61`], [`2g`],
    [`00`], [`1`], [`626262`], [`a3gV`],
    [`0000`], [`11`], [`00010203`], [`1Ldp`],
    [`000001`], [`112`], [`ffffffff`], [`7YXq9G`],
    [`0000ffff`], [`11LUv`], [`31323334353938373630`], [`3mJr7AoUXx2Wqd`],
  )
  Decoding `z` yields `39`; decoding `21` yields `3a`; decoding `0OIl`
  yields the empty string (all four characters are outside the alphabet).
]

=== Base58Check <sec:addresses-base58check>

*Base58Check* adds a type prefix and a checksum. Decred's variant differs
from Bitcoin's in two ways that make the encodings incompatible: the prefix
(called the *version* or *network identifier*) is *two* bytes, and the
checksum is the first four bytes of a *double BLAKE-256*, not of a double
SHA-256.

#algorithm("Base58Check", src: "github.com/decred/base58 · CheckEncode, CheckDecode")[
  ```python
  def checksum(b: bytes) -> bytes:
      return BLAKE256(BLAKE256(b))[0:4]

  def check_encode(payload: bytes, version: bytes) -> str:     # len(version) == 2
      b = version + payload
      return base58_encode(b + checksum(b))

  def check_decode(s: str) -> (bytes, bytes):
      d = base58_decode(s)
      if len(d) < 6:
          error("invalid format")      # also the result of any invalid character
      if d[len(d)-4:] != checksum(d[0:len(d)-4]):
          error("checksum")
      return d[2:len(d)-4], d[0:2]     # (payload, version)
  ```
] <alg:addresses-base58check>

#vector[Base58Check][
  #kv(
    [Version], [`073f` (main-network P2PKH)],
    [Payload], [`0102030405`],
    [$"BLAKE256"$(version ‖ payload)], [#hex("1d6b06142d26b2ad114a8ddafc2a140a8156dbe167d74aab8ba677273b5fe666")],
    [$"BLAKE256"$ of that], [#hex("a5867abf3983ffa4aded66332f4d689decd0ab28a8b1076f47c10b2872984ff7")],
    [Checksum], [`a5867abf`],
    [Encoded], [`2oDcdouVBocLC4W`],
    [Last character altered], [`2oDcdouVBocLC4a` → checksum error],
    [`1111`], [decodes to 4 zero bytes → invalid format],
    [`Ds0abc`], [`0` is not in the alphabet → invalid format],
  )
]

== Network Prefixes <sec:addresses-prefixes>

Each network has its own set of prefixes, so a string encoded for one network
fails to decode on another. The prefixes are chosen so that the first one or
two characters of the text form are constant and identify the network and
type: on the main network, addresses begin with `D`, P2PKH addresses with
`Ds`, and so on. The first character is recorded in the network parameters
as #param("NetworkAddressPrefix") but is informative only; decoding relies
solely on the decoded prefix bytes.

#figure(
  caption: [Prefixes per network. Each cell gives the prefix bytes in
    hexadecimal (in serialization order) and the fixed leading characters of
    the encoded string.],
  table(
    columns: (auto, auto, 1fr, 1fr, 1fr, 1fr),
    table.header([Object], [Parameter], [mainnet], [testnet3], [simnet], [regnet]),
    [First letter], [#param("NetworkAddressPrefix")], [`D`], [`T`], [`S`], [`R`],
    [P2PK (all suites)], [#param("PubKeyAddrID")], [`1386` Dk], [`28f7` Tk], [`276f` Sk], [`25e5` Rk],
    [P2PKH ECDSA], [#param("PubKeyHashAddrID")], [`073f` Ds], [`0f21` Ts], [`0e91` Ss], [`0e00` Rs],
    [P2PKH Ed25519], [#param("PKHEdwardsAddrID")], [`071f` De], [`0f01` Te], [`0e71` Se], [`0de0` Re],
    [P2PKH Schnorr], [#param("PKHSchnorrAddrID")], [`0701` DS], [`0ee3` TS], [`0e53` SS], [`0dc2` RS],
    [P2SH], [#param("ScriptHashAddrID")], [`071a` Dc], [`0efc` Tc], [`0e6c` Sc], [`0ddb` Rc],
    [WIF private key], [#param("PrivateKeyID")], [`22de` Pm], [`230e` Pt], [`2307` Ps], [`22fe` Pr],
    [Extended private key], [#param("HDPrivateKeyID")], [`02fda4e8` dprv], [`04358397` tprv], [`0420b903` sprv], [`eab40448` rprv],
    [Extended public key], [#param("HDPublicKeyID")], [`02fda926` dpub], [`043587d1` tpub], [`0420bd3d` spub], [`eab4f987` rpub],
    [BIP44 coin type], [#param("SLIP0044CoinType")], [42], [1], [1], [1],
    [Legacy coin type], [#param("LegacyCoinType")], [20], [11], [115], [1],
  ),
) <tab:addresses-prefixes>

All five address prefixes of a network are distinct, so the decoded prefix
determines the address type unambiguously. The coin types are explained in
@sec:addresses-bip44.

== Address Types <sec:addresses-types>

An address is meaningful only together with a *script version*, the 16-bit
version number carried with every transaction output (#chref("encoding")).
Every address type defined at present is for script version 0, and every
script an address produces is a version 0 script. A request for an address of
any other script version fails with `ErrUnsupportedScriptVersion`.

@tab:addresses-types lists the seven address types. The names follow the
form _pay-to-X-signature-suite_: what the output script commits to (a public
key, the hash of a public key, or the hash of a script) and, for the first
two, which of the three signature suites of #chref("crypto") must be used to
spend it. In the script templates, `H` is a 20-byte HASH160, `K33` a 33-byte
compressed secp256k1 public key and `K32` a 32-byte Ed25519 public key.

#figure(
  caption: [Version 0 address types and their payment scripts],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Address type], [Prefix], [Payload], [Payment script (hex template)]),
    [P2PK, ECDSA secp256k1], [#param("PubKeyAddrID")], [33], [`21` `K33` `ac`],
    [P2PK, Ed25519], [#param("PubKeyAddrID")], [33], [`20` `K32` `51` `be`],
    [P2PK, Schnorr secp256k1], [#param("PubKeyAddrID")], [33], [`21` `K33` `52` `be`],
    [P2PKH, ECDSA secp256k1], [#param("PubKeyHashAddrID")], [20], [`76` `a9` `14` `H` `88` `ac`],
    [P2PKH, Ed25519], [#param("PKHEdwardsAddrID")], [20], [`76` `a9` `14` `H` `88` `51` `be`],
    [P2PKH, Schnorr secp256k1], [#param("PKHSchnorrAddrID")], [20], [`76` `a9` `14` `H` `88` `52` `be`],
    [P2SH], [#param("ScriptHashAddrID")], [20], [`a9` `14` `H` `87`],
  ),
) <tab:addresses-types>

In opcode form (#chref("script") defines the opcodes): `21` is
`OP_DATA_33`, `20` is `OP_DATA_32`, `14` is `OP_DATA_20`, `51` and `52` are
`OP_1` and `OP_2` (which push the signature-type numbers 1 for Ed25519 and 2
for Schnorr), `76` is `OP_DUP`, `a9` is `OP_HASH160`, `88` is
`OP_EQUALVERIFY`, `87` is `OP_EQUAL`, `ac` is `OP_CHECKSIG` and `be` is
`OP_CHECKSIGALT`. The scripts are therefore:

```
P2PK-ECDSA      <K33> OP_CHECKSIG
P2PK-Ed25519    <K32> OP_1 OP_CHECKSIGALT
P2PK-Schnorr    <K33> OP_2 OP_CHECKSIGALT
P2PKH-ECDSA     OP_DUP OP_HASH160 <H> OP_EQUALVERIFY OP_CHECKSIG
P2PKH-Ed25519   OP_DUP OP_HASH160 <H> OP_EQUALVERIFY OP_1 OP_CHECKSIGALT
P2PKH-Schnorr   OP_DUP OP_HASH160 <H> OP_EQUALVERIFY OP_2 OP_CHECKSIGALT
P2SH            OP_HASH160 <H> OP_EQUAL
```

Script lengths are 35, 35, 36, 25, 26, 26 and 23 bytes respectively.

=== Pay-to-pubkey addresses <sec:addresses-p2pk>

All three P2PK types share the prefix #param("PubKeyAddrID") and a 33-byte
payload made of a *type byte* followed by 32 bytes of key material. The low
seven bits of the type byte hold the signature type of #chref("crypto") (0
ECDSA secp256k1, 1 Ed25519, 2 Schnorr secp256k1). For the two secp256k1
types the key material is the 32-byte big-endian X coordinate, and the high
bit (`0x80`) of the type byte is set exactly when the Y coordinate is odd,
that is, when the compressed serialization starts with `0x03`. For Ed25519
the key material is the 32-byte encoded public key unchanged and the high
bit is zero.

#figure(
  caption: [P2PK payload type byte],
  table(
    columns: (auto, auto, 1fr),
    table.header([Type byte], [Suite], [Reconstructed public key]),
    [`0x00`], [ECDSA secp256k1], [`02` ‖ X],
    [`0x80`], [ECDSA secp256k1], [`03` ‖ X],
    [`0x01`], [Ed25519], [the 32 bytes as given],
    [`0x02`], [Schnorr secp256k1], [`02` ‖ X],
    [`0x82`], [Schnorr secp256k1], [`03` ‖ X],
  ),
) <tab:addresses-p2pk-type>

A P2PK address can only be created for a valid public key. For the
secp256k1 types the key #MUST be a point on the curve and is always used in
its 33-byte *compressed* serialization: an uncompressed (`0x04`) or hybrid
(`0x06`, `0x07`) key is refused with `ErrInvalidPubKeyFormat`, even though
the script language would accept a P2PK-ECDSA script containing a 65-byte
uncompressed key. Ed25519 keys #MUST parse as valid Ed25519 points. dcrd's
test is decompression plus a range check on the recovered $x$: it accepts every 32-byte string whose low 255
bits, read little-endian as $y$, and whose top bit, as the sign of $x$,
decode to a point on the curve. It does not require $y < p$ (so
non-canonical encodings such as `ee ff … ff 7f`, which is $y = p + 1$, are
accepted), it accepts points of small order, including the identity
`01 00 … 00`, and it rejects an encoding with $x = 0$ and the sign bit set.
The address and its payment script keep the 32 bytes exactly as given.

#pitfall[
  When an output script of the form `<65-byte uncompressed key> OP_CHECKSIG`
  is converted to an address (@sec:addresses-reverse), the result is the
  P2PK-ECDSA address of the *compressed* form of that key, and the payment
  script of that address is the 35-byte compressed script, not the original.
  Address-to-script and script-to-address are not inverses for such outputs.
]

#pitfall[
  The decoder masks the high bit off the type byte before testing for
  Ed25519, so a payload beginning `0x81` decodes as the same Ed25519 address
  as `0x01`, and re-encodes with `0x01`. Implementations that compare address
  strings for equality should compare re-encoded strings. Any type value
  other than 0, 1 or 2 after masking is unsupported.
]

=== Pay-to-pubkey-hash addresses

A P2PKH address carries the 20-byte HASH160 of a public key, and the payment
script requires the spender to reveal a public key that hashes to it and a
valid signature by that key. The signature suite is fixed by the address
prefix, not by the payload, and selects the script template of
@tab:addresses-types.

- *ECDSA secp256k1*: the hash is normally of the 33-byte compressed key. For
  historical reasons the script also accepts a key in 65-byte uncompressed
  form if the hash was computed over that form; wallets #SHOULD always hash
  the compressed form.
- *Schnorr secp256k1*: the hash #MUST be of the 33-byte compressed key. The
  consensus rules for `OP_CHECKSIGALT` with signature type 2 reject
  uncompressed keys, so an output whose hash commits to an uncompressed key
  is unspendable.
- *Ed25519*: the hash is of the 32-byte encoded Ed25519 public key.

Every P2PK address has a corresponding P2PKH address of the same suite,
obtained by hashing the (compressed) public key and using the P2PKH prefix
of that suite.

=== Pay-to-script-hash addresses

A P2SH address carries the 20-byte HASH160 of a *redeem script*; the payment
script requires the spender to reveal a script with that hash and to satisfy
it. The execution rules for P2SH, including the restrictions on the redeem
script, are in #chref("script").

#vector[Addresses for a fixed key][
  The secp256k1 private key and the Ed25519 private scalar are both the
  32 bytes `01 02 03 … 1f 20`, read big-endian. The P2SH redeem script is
  the P2PK-ECDSA payment script of the secp256k1 key.
  #kv(
    [Private key], [#hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")],
    [secp256k1 public key (compressed)], [#hex("0284bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b0")],
    [HASH160 of it], [#hex("b47b61b2aeec0f3900616e6b032246e1a11e09b9")],
    [Ed25519 public key], [#hex("80334024b705b5fd76b1bce1b26d96234ab7b2d989987895fa72c43b3e5c5f85")],
    [HASH160 of it], [#hex("6ede19217e38d198dcab3778cb5b8cd451478242")],
    [Redeem script], [#hex("210284bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b0ac")],
    [HASH160 of it], [#hex("d7b0b267d1462b015611b5f78912214883384571")],
  )
  #table(
    columns: (auto, auto, 1fr),
    table.header([Type], [Network], [Address]),
    [P2PK ECDSA], [mainnet], [#hex("DkM3V4UE8ofRtdYsHfRUKn4we8zQtZoy4nLoRpKvE2bhm4jSWNCHZ")],
    [], [testnet3], [#hex("TkKmZPK7sjUFaKwZhFL2CbQE4BxAVnnLGLF6rDhdtB9VZbgL6sQyQ")],
    [P2PK Ed25519], [mainnet], [#hex("DkM5PoUuyB2y79g7DjNFoZ9dTQEgYsBP5atQ5USjPetm8vSomnEgj")],
    [], [testnet3], [#hex("TkKoU8Koi6qnnr4odKGogNUusTCSA69kH8nhVspT3oSYwTPa2Qx9E")],
    [P2PK Schnorr], [mainnet], [#hex("DkM7NYph2sNHF5pWT5EdZmyaqgpe817NkXv5a2pDbpb1mqii1LupZ")],
    [], [testnet3], [#hex("TkKqSsfamoB6vnDCrf9BSbJsFjnPjE5jx5pNzSBwFy8oaNfZn7kpv")],
    [P2PKH ECDSA], [mainnet], [#hex("DshRCvfb21VQvaXZYhBivFS7VAurvcKi32t")],
    [], [testnet3], [#hex("TshURuo6QoYX2wCvN5ot4pTP5GsnVK4bmxd")],
    [P2PKH Ed25519], [mainnet], [#hex("DeiFpNi2n7zvqzsxPP2G6QjWS89h8A4vTwZ")],
    [], [testnet3], [#hex("TeiK3MqYAv42xMZKCmeREykn2E7cgjKnRy2")],
    [P2PKH Schnorr], [mainnet], [#hex("DSkTosw79zJgbsevBBB5ABfEi9dtSZ9MLCN")],
    [], [testnet3], [#hex("TSkX2s4cYnMniELGzZoEJkgWJFbp1E7F8u4")],
    [P2SH], [mainnet], [#hex("Dcs841mixKtD7siWRMBz824w7wj7M9kgcqg")],
    [], [testnet3], [#hex("TcsBGzuEM7wKEEPsEjp9Gb6Ci3h2uriPgBA")],
  )
  The decoded payloads are, in order:
  #hex("0084bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b0"),
  #hex("0180334024b705b5fd76b1bce1b26d96234ab7b2d989987895fa72c43b3e5c5f85"),
  #hex("0284bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b0"),
  and the three HASH160 values above. The payment scripts are:
  #kv(
    [P2PK ECDSA], [#hex("210284bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b0ac")],
    [P2PK Ed25519], [#hex("2080334024b705b5fd76b1bce1b26d96234ab7b2d989987895fa72c43b3e5c5f8551be")],
    [P2PK Schnorr], [#hex("210284bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b052be")],
    [P2PKH ECDSA], [#hex("76a914b47b61b2aeec0f3900616e6b032246e1a11e09b988ac")],
    [P2PKH Ed25519], [#hex("76a9146ede19217e38d198dcab3778cb5b8cd4514782428851be")],
    [P2PKH Schnorr], [#hex("76a914b47b61b2aeec0f3900616e6b032246e1a11e09b98852be")],
    [P2SH], [#hex("a914d7b0b267d1462b015611b5f7891221488338457187")],
  )
]

#vector[The same key on the private networks][
  #table(
    columns: (auto, auto, 1fr),
    table.header([Type], [Network], [Address]),
    [P2PK ECDSA], [simnet], [#hex("SkLUPG3sF7D7gM6NaTdJ8XB98ddQnYk3JX4uksdpmha4ZDvN1V5Bw")],
    [], [regnet], [#hex("Rk41wzTtp8e9WRD9vZmnGrbsEaSFmdsCtP1UQQfKUF388HW4Hn1BP")],
    [P2PKH ECDSA], [simnet], [#hex("Sskoa8AAvZZnsAnqtZPvAzQBneEgez7tfS8")],
    [], [regnet], [#hex("RsQo7MQx9cQbpawdL1ZcxgDiiP6Ksoe5TNC")],
    [P2PKH Ed25519], [simnet], [#hex("SemeBaCcgg5Jnb9EjFETM9hajbUWrRVxTNf")],
    [], [regnet], [#hex("ReRdioTPuiv7k1J2AhQA8qX7fLLA5H3J7Sq")],
    [P2PKH Schnorr], [simnet], [#hex("SSorB5Rh4YP4YTvCX3PGQvdK1cxiApYcq4v")],
    [], [regnet], [#hex("RSTqiJgUHbDsVt4yxVYyCcSqwMpMPnBJMUm")],
    [P2SH], [simnet], [#hex("ScvWRDGJrsxb4TynmDQBNm31RR3w5TFJrGT")],
    [], [regnet], [#hex("RcaVxSX65voQ1t8aCfZtASrYM9uaJQ9DsGk")],
  )
]

=== Stake and treasury scripts <sec:addresses-stake>

The stake system (#chref("staking")) and the treasury (#chref("treasury"))
use output scripts that consist of a one-byte *stake opcode tag* followed by
an ordinary P2PKH or P2SH script, plus one special `OP_RETURN` commitment
format. Only two address types can appear in them: *P2PKH ECDSA secp256k1*
and *P2SH*. Ed25519 and Schnorr P2PKH addresses and all P2PK addresses
cannot be used for staking or for treasury payouts. @tab:addresses-stake
gives the scripts derived from an address of either kind; `S` denotes the
address's ordinary payment script from @tab:addresses-types (25 bytes for
P2PKH, 23 for P2SH).

#figure(
  caption: [Stake-tagged scripts derived from an address],
  table(
    columns: (auto, auto, 1fr),
    table.header([Purpose], [Script], [Where it is valid]),
    [Voting rights], [`ba` ‖ `S` (`OP_SSTX`)], [Output 0 of a ticket purchase],
    [Reward commitment], [`6a 1e` ‖ commitment (`OP_RETURN`)], [Odd outputs of a ticket purchase (@tab:addresses-commitment)],
    [Stake change], [`bd` ‖ `S` (`OP_SSTXCHANGE`)], [Change outputs of a ticket purchase or a treasury add],
    [Vote payment], [`bb` ‖ `S` (`OP_SSGEN`)], [Payment outputs of a vote, to a committed address],
    [Revocation payment], [`bc` ‖ `S` (`OP_SSRTX`)], [Payment outputs of a revocation, to a committed address],
    [Treasury payment], [`c3` ‖ `S` (`OP_TGEN`)], [Payment outputs of a treasury spend],
  ),
) <tab:addresses-stake>

The *reward commitment* is a 32-byte null-data script: `OP_RETURN`,
`OP_DATA_30`, then the 30 bytes of @tab:addresses-commitment. It names
the address that a later vote or revocation of the ticket must pay, the
amount that address contributed, and optional fee limits. Which scripts are
required where, and how the amounts and limits are enforced, are consensus
matters specified in #chref("staking")\; this section gives only the
encoding.

#fieldtable(
  caption: [Reward commitment payload (30 bytes, after `6a 1e`)],
  ("hash", "[20]byte", "20", [HASH160 from a P2PKH-ECDSA or P2SH address.]),
  ("amount", "uint64 LE", "8", [Contributed amount in atoms in the low 63 bits. The most significant bit (`0x80` in the last byte) is 1 if `hash` is a script hash (P2SH) and 0 if it is a public-key hash (P2PKH-ECDSA).]),
  ("limits", "uint16 LE", "2", [Fee limits. Low byte: vote fee limit; high byte: revocation fee limit. Each byte is 0 for "no fee allowed" (the payment must be exact, #chref("staking")) or `0x40 | e` for a fee limit of $2^e$ atoms. This is what the encoder produces; how consensus reads every bit of the field is in #chref("staking").]),
) <tab:addresses-commitment>

When a wallet asks for a fee limit of $L > 0$ atoms, the exponent $e$ is the
smallest integer with $2^e >= L$, so limits that are not powers of two are
rounded up. A requested limit of 0 produces a zero byte, which permits no fee at all.
dcrd computes $e$ as $ceil(log_2 L)$ in double-precision floating point;
this agrees with the integer definition for every $L <= 2^49$ (about 5.6
million DCR). The smallest disagreement is $L = 2^49 + 1$, whose
floating-point logarithm is exactly 49, so dcrd writes `0x71` where the
integer definition gives `0x72`; larger limits just above a power of two can
disagree in the same way. dcrd does not reject a negative limit, and the byte
it writes for one is not meaningful.

Reading a commitment back into an address takes bytes 2 to 21 of the script
as the hash and the most significant bit of byte 29 as the P2SH flag, and
builds a P2SH or P2PKH-ECDSA address on the network in use.

#vector[Stake scripts for the P2PKH-ECDSA and P2SH addresses above][
  Commitment (a) is for 1 DCR ($10^8$ atoms) with no vote fee limit and a
  revocation fee limit of $2^24$; commitment (b) is for 1 DCR with limits 1
  and $2^24 + 1$.
  #kv(
    [Voting rights, P2PKH], [#hex("ba76a914b47b61b2aeec0f3900616e6b032246e1a11e09b988ac")],
    [Voting rights, P2SH], [#hex("baa914d7b0b267d1462b015611b5f7891221488338457187")],
    [Commitment (a), P2PKH], [#hex("6a1eb47b61b2aeec0f3900616e6b032246e1a11e09b900e1f505000000000058")],
    [Commitment (a), P2SH], [#hex("6a1ed7b0b267d1462b015611b5f7891221488338457100e1f505000000800058")],
    [Commitment (b), P2PKH], [#hex("6a1eb47b61b2aeec0f3900616e6b032246e1a11e09b900e1f505000000004059")],
    [Stake change, P2PKH], [#hex("bd76a914b47b61b2aeec0f3900616e6b032246e1a11e09b988ac")],
    [Vote payment, P2PKH], [#hex("bb76a914b47b61b2aeec0f3900616e6b032246e1a11e09b988ac")],
    [Revocation payment, P2PKH], [#hex("bc76a914b47b61b2aeec0f3900616e6b032246e1a11e09b988ac")],
    [Treasury payment, P2PKH], [#hex("c376a914b47b61b2aeec0f3900616e6b032246e1a11e09b988ac")],
    [Treasury payment, P2SH], [#hex("c3a914d7b0b267d1462b015611b5f7891221488338457187")],
  )
  The limit bytes for requested limits 1, 2, 3, 4, $2^24$ and $2^24+1$ are
  `0x40`, `0x41`, `0x42`, `0x42`, `0x58` and `0x59`.
]

=== From scripts back to addresses <sec:addresses-reverse>

Software that displays transactions maps each version 0 output script back
to zero or more addresses. The script classes are those of #chref("script")\;
@tab:addresses-reverse gives the address each class yields. A script whose
version is not 0 yields no address.

#figure(
  caption: [Addresses extracted from version 0 script classes],
  table(
    columns: (1fr, 1fr),
    table.header([Script class], [Address(es)]),
    [P2PKH ECDSA, Ed25519, Schnorr], [The P2PKH address of that suite],
    [P2SH], [The P2SH address],
    [P2PK ECDSA (compressed or uncompressed key)], [The P2PK-ECDSA address of the compressed key, if the key parses],
    [P2PK Ed25519, P2PK Schnorr], [The P2PK address of that suite, if the key parses],
    [Multisignature (`OP_CHECKMULTISIG`)], [One P2PK-ECDSA address per public key that parses, in script order],
    [Stake-tagged (`OP_SSTX`, `OP_SSGEN`, `OP_SSRTX`, `OP_SSTXCHANGE`, `OP_TGEN`) over P2PKH or P2SH], [The inner P2PKH-ECDSA or P2SH address],
    [Null data (including reward commitments), treasury add, non-standard], [None],
  ),
) <tab:addresses-reverse>

== Decoding Addresses <sec:addresses-decoding>

Decoding first applies a shape test (length 35 or 53, Base58 alphabet only)
that selects the version 0 decoder, then Base58Check, then dispatches on the
two prefix bytes. An address for a different network fails with
`ErrUnsupportedAddress`, because its prefix matches none of the expected
values. dcrd also rejects strings longer than 54 characters with
`ErrMalformedAddress` before Base58 decoding; the shape test makes that
check unreachable through `DecodeAddress` (it applies only when the version 0
decoder `DecodeAddressV0` is called directly, which also skips the shape
test).

#algorithm("Decoding a version 0 address", src: ("txscript/stdaddr/address.go · DecodeAddress", "txscript/stdaddr/addressv0.go · DecodeAddressV0"))[
  ```python
  def decode_address(s: str, net) -> Address:
      # Shape test that selects the version 0 decoder.
      if len(s) not in (35, 53) or any(c not in ALPHABET for c in s):
          error(ErrUnsupportedAddress)
      payload, ver = check_decode(s)   # checksum failure -> ErrBadAddressChecksum,
                                       # any other failure -> ErrMalformedAddress
      if ver == net.ScriptHashAddrID:  return P2SH(hash20(payload))
      if ver == net.PubKeyHashAddrID:  return P2PKH_ECDSA(hash20(payload))
      if ver == net.PKHSchnorrAddrID:  return P2PKH_SCHNORR(hash20(payload))
      if ver == net.PKHEdwardsAddrID:  return P2PKH_ED25519(hash20(payload))
      if ver == net.PubKeyAddrID:
          if len(payload) < 1:
              error(ErrMalformedAddressData)
          sig_type = payload[0] & 0x7f
          if sig_type in (0, 2):                          # ECDSA or Schnorr secp256k1
              if len(payload) != 33:
                  error(ErrMalformedAddressData)
              prefix = 0x03 if payload[0] & 0x80 else 0x02
              key = bytes([prefix]) + payload[1:33]
              require_valid_secp256k1_point(key)          # else ErrInvalidPubKey
              return P2PK_ECDSA(key) if sig_type == 0 else P2PK_SCHNORR(key)
          if sig_type == 1:                               # Ed25519
              if len(payload) - 1 != 32:
                  error(ErrMalformedAddressData)
              require_valid_ed25519_point(payload[1:33])  # else ErrInvalidPubKey
              return P2PK_ED25519(payload[1:33])
      error(ErrUnsupportedAddress)     # includes every prefix of another network

  def hash20(payload):
      if len(payload) != 20:
          error(ErrInvalidHashLen)
      return payload
  ```
] <alg:addresses-decode>

#vector[Address decoding failures (main network)][
  #kv(
    [`DshRCvfb21VQvaXZYhBivFS7VAurvcKi32a`], [last character altered: `ErrBadAddressChecksum`],
    [`DshRCvfb21VQvaXZYhBivFS7VAurvcKi32t` on testnet3], [`ErrUnsupportedAddress`],
    [`DsQxuVRvS4eaJ42dhQEsCXauMWjvopWgrV` (34 characters)], [`ErrUnsupportedAddress`],
    [`DkRS8aabvzJAVJDLR4BQdg1xBaxMZdyDTVRXhvHYLTpYdsNzbinHP` (type byte `0x83`)], [`ErrUnsupportedAddress`],
    [`DkRND64bRG7Rg8w7c1QTFTEgCXTHNnPWwfcD9FfuSQ8dzZcKTd9Hm` (type byte `0x81`)], [accepted; re-encodes as `DkM5PoUu…omnEgj` (P2PK Ed25519 above)],
  )
]

== Private Keys: Wallet Import Format <sec:addresses-wif>

The *Wallet Import Format* (WIF) encodes a single private key together with
its signature suite and network. It is used to move individual keys between
wallets. Unlike Bitcoin's WIF it carries an explicit signature-type byte and
no "compressed" flag: secp256k1 public keys derived from a WIF key are always
compressed.

#fieldtable(
  caption: [WIF serialization (39 bytes, then Base58)],
  ("net", "[2]byte", "2", [#param("PrivateKeyID") of the network.]),
  ("type", "uint8", "1", [Signature type: 0 ECDSA secp256k1, 1 Ed25519, 2 Schnorr secp256k1.]),
  ("key", "[32]byte", "32", [Private scalar, 32-byte big-endian.]),
  ("checksum", "[4]byte", "4", [First 4 bytes of $"BLAKE256"$ (a *single* hash) of the preceding 35 bytes.]),
) <tab:addresses-wif>

#pitfall[
  The WIF checksum is a single BLAKE-256, unlike the double BLAKE-256 of
  addresses and extended keys, so WIF is *not* Base58Check as defined in
  @sec:addresses-base58check. A WIF string with a double-hash checksum is
  rejected. (The dcrd source comment describing the checksum as "double
  SHA256" is stale; the code uses one BLAKE-256.)
]

For secp256k1 the 32 bytes are reduced modulo the group order $n$ when the
key is used; the public key is the compressed serialization of $d dot G$. For
Ed25519 the 32 bytes are the private scalar $d$, read big-endian (not the
32-byte seed of RFC 8032 @rfc8032); it #MUST satisfy $0 < d <= ell$, where
$ell$ is the order of the Ed25519 base point, and the public key is the
32-byte encoding of $d dot B$.

#algorithm("Decoding a WIF string", src: "dcrutil/wif.go · DecodeWIF")[
  ```python
  def decode_wif(s: str, net) -> (int, bytes):
      if len(s) > 54:
          error("malformed private key")
      d = base58_decode(s)
      if len(d) != 39:
          error("malformed private key")
      if BLAKE256(d[0:35])[0:4] != d[35:39]:
          error("checksum mismatch")
      if d[0:2] != net.PrivateKeyID:
          error("wrong network")
      sig_type, key = d[2], d[3:35]
      if sig_type in (0, 2):
          return sig_type, key           # no range check: 0 or >= n is not rejected
      if sig_type == 1:
          if not (0 < int_from_be(key) <= ED25519_ORDER):
              error("invalid scalar")
          return 1, key
      return 0, b""                      # unknown type: no error, empty key (see below)
  ```
] <alg:addresses-wif>

#pitfall[
  dcrd's decoder does not reject an unknown type byte: it returns an
  ECDSA-typed result with an empty key. It also accepts a secp256k1 key of
  zero (deriving a meaningless public key `02 00…00`) or one that is not
  below $n$. Implementations #SHOULD reject all three. Encoders #MUST write
  the key as exactly 32 bytes, left-padded with zeros; the dcrd encoder
  copies whatever key bytes it is given, and an HD private key derived by
  the Decred method can be shorter than 32 bytes (@sec:addresses-hd-child).
]

#vector[WIF for the private key `01 02 … 1f 20`][
  #table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Type], [WIF]),
    [mainnet], [0 ECDSA], [#hex("PmQdGsGYheiVkbzcb54ZXJZW2FvaPdoqb4A3oGuzndZjLXfrCYEYL")],
    [mainnet], [1 Ed25519], [#hex("PmQfDcSn9gZvRq8SAmy99JWpd2qh1MTYRvwgsPA9UXZPLvANp1UPz")],
    [mainnet], [2 Schnorr], [#hex("PmQhAMd1biRM74GFkUsimJU9Dokod57FGojKwVQJARZ3MJf1hzZqG")],
    [testnet3], [0 ECDSA], [#hex("PtWTYK1qt46UMNqFTchWPWv3QCnDhhtrUsMx48idLCXuW3ZQuqcg9")],
    [testnet3], [1 Ed25519], [#hex("PtWVV4C5L5wu2by53Kc61WsMzyhLKRYZKk9b8Exn26XZWS42kL26f")],
    [testnet3], [2 Schnorr], [#hex("PtWXRoNJn7oKhq6td2WfdWpgbkcSw9CGAcwECMCvhzXDWpYakremR")],
  )
  The decoded bytes of the first are
  #hex("22de000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20d8225f95")\;
  the checksum `d8225f95` is the first four bytes of the BLAKE-256 of the
  preceding 35 bytes. The public keys are those of the address vector
  above.
]

== Signed Messages <sec:addresses-messages>

A *signed message* proves control of a P2PKH-ECDSA address without making a
transaction. dcrwallet produces them and dcrd verifies them through its
`verifymessage` RPC. Only P2PKH-ECDSA secp256k1 addresses are supported; a
verifier #MUST reject any other address type.

The signed digest is
$ h = "BLAKE256"("varstr"("MAGIC") || "varstr"(m)), $
where $m$ is the message as bytes (UTF-8), MAGIC is the 23 ASCII bytes
`Decred Signed Message:` followed by a line feed (`0x0a`), and
$"varstr"(x)$ is the length of $x$ as a variable-length integer
(#chref("encoding")) followed by $x$. The hash is a single BLAKE-256.

The signature is a 65-byte *compact recoverable* ECDSA signature: a header
byte, then $r$ and $s$ as 32-byte big-endian integers. The header byte is
$27 + "rec" + 4c$, where $c$ is 1 if the address hashes the compressed public
key (always the case for dcrwallet) and $"rec" in {0,1,2,3}$ is the recovery
code: bit 0 is the parity of the Y coordinate of the point $R$ that
satisfies $s dot R = e dot G + r dot Q$ (with $e$ the digest reduced modulo
$n$ and $Q$ the public key), and bit 1 is set if the X coordinate of $R$ is
at least $n$, so that $r$ is that coordinate minus $n$. dcrd's signer
outputs only $s <= n slash 2$; when it negates $s$ to achieve this it also
flips bit 0, because $R$ is then the negation of the nonce point. The
65 bytes are exchanged in standard Base64 with padding (RFC 4648). Signers
use deterministic nonces (RFC 6979 @rfc6979, as in #chref("crypto")), so a
given key and message always produce the same signature.

#algorithm("Verifying a signed message", src: ("internal/rpcserver/rpcserver.go · handleVerifyMessage", "dcrutil/util.go · VerifyMessage"))[
  ```python
  MAGIC = b"Decred Signed Message:\n"

  def message_hash(m: bytes) -> bytes:
      return BLAKE256(varint(len(MAGIC)) + MAGIC + varint(len(m)) + m)

  def verify_message(address: str, sig_b64: str, m: bytes, net) -> bool:
      if not is_P2PKH_ECDSA(decode_address(address, net)):
          error("not a pay-to-pubkey-hash address")
      sig = base64_decode(sig_b64)                            # failure -> error
      Q, compressed = recover_compact(sig, message_hash(m))   # failure -> False (RPC)
      key = ser_compressed(Q) if compressed else ser_uncompressed(Q)
      return encode_P2PKH_ECDSA(HASH160(key), net) == address
  ```
] <alg:addresses-verify>

Public-key recovery inverts the ECDSA verification equation (SEC 1
@sec1, section 4.1.6) using the recovery code to select the nonce point:

#algorithm("Compact signature public-key recovery", src: "dcrec/secp256k1/ecdsa/signature.go · RecoverCompact")[
  ```python
  def recover_compact(sig: bytes, h: bytes):    # N: group order, P: field prime
      if len(sig) != 65:                  fail()
      code = sig[0]
      if code < 27 or code > 34:          fail()
      code = code - 27
      compressed = (code & 4) != 0
      r, s = int_from_be(sig[1:33]), int_from_be(sig[33:65])
      if r >= N or r == 0 or s >= N or s == 0:
          fail()
      x = r
      if code & 2:
          if r + N >= P:                  fail()
          x = r + N
      Rpt = point_with_x(x, odd_y=(code & 1) != 0)   # fail if x is not on the curve
      e = int_from_be(h) % N
      w = inverse(r, N)
      Q = ((-e * w) % N) * G + ((s * w) % N) * Rpt
      if Q is infinity:                   fail()
      return Q, compressed
  ```
] <alg:addresses-recover>

The recovery does not require $s <= n slash 2$; high-$s$ signatures verify.

#vector[Signed message][
  #kv(
    [Address], [`DshRCvfb21VQvaXZYhBivFS7VAurvcKi32t` (private key `01 02 … 1f 20`)],
    [Message], [`Decred` (6 bytes)],
    [Preimage], [#hex("17446563726564205369676e6564204d6573736167653a0a06446563726564")],
    [Digest $h$], [#hex("e24e7c60221c11a8176e2e7d912cb947e7f68891ed0de3ebe71fa34298041198")],
    [Signature], [#hex("1f43c089ab3b869b04bd6c709418df8be7c9d938bc5e853999c719f8694fc2f5a246cd5e8dd8f23e39422b6238b7da784beb69a28e090cf2e523ccca6f1f901cc2")],
    [Base64], [`H0PAias7hpsEvWxwlBjfi+fJ2Ti8XoU5mccZ+GlPwvWiRs1ejdjyPjlCK2I4t9p4S+tpoo4JDPLlI8zKbx+QHMI=`],
  )
  The header byte `0x1f` = 31 = 27 + 0 + 4: compressed key, recovery code 0.
]

== Hierarchical Deterministic Keys <sec:addresses-hd>

Hierarchical deterministic keys derive an unbounded tree of key pairs from a
single seed, so that a wallet can be backed up once. Each node of the tree is
an *extended key*: a private or public key together with a 32-byte *chain
code*. Decred uses the BIP32 construction @bip32 with the changes listed in
@tab:addresses-bip32-diff. Of these, only the stripping of leading zeros
changes which keys are derived; the others change only the serialized form.

#figure(
  caption: [Differences between Decred HD keys and BIP32],
  table(
    columns: (auto, 1fr),
    table.header([Aspect], [Decred behaviour]),
    [Fingerprint], [First 4 bytes of $"HASH160"$ of the parent's compressed public key, with Decred's BLAKE-256-based HASH160.],
    [Checksum], [First 4 bytes of $"BLAKE256"("BLAKE256"(dot))$ of the 78-byte serialization.],
    [Version bytes], [Per network, @tab:addresses-prefixes.],
    [Private child key], [Leading zero bytes of the derived private key are stripped, which changes the input to every *hardened* child of that key (@sec:addresses-hd-child).],
    [Master key], [Unchanged: HMAC-SHA512 keyed with the ASCII string `Bitcoin seed`.],
  ),
) <tab:addresses-bip32-diff>

Because the master key and the derivation function are otherwise BIP32's,
the master private key and chain code for a given seed equal BIP32's, and so
do the keys of any path that never meets a stripped key. The serialized
strings always differ (version, fingerprint and checksum).

=== Master key generation

#algorithm("Master key from seed", src: "hdkeychain/extendedkey.go · NewMaster")[
  ```python
  def new_master(seed: bytes, net) -> ExtKey:
      if len(seed) < 16 or len(seed) > 64:          # 128 to 512 bits; 32 recommended
          error("invalid seed length")
      I = HMAC_SHA512(key=b"Bitcoin seed", data=seed)
      IL, IR = I[0:32], I[32:64]
      k = int_from_be(IL)
      if k >= N or k == 0:
          error("unusable seed")                    # choose another seed
      return ExtKey(private=True, key=IL,           # 32 bytes, never stripped
                    chain_code=IR, depth=0, parent_fp=b"\x00" * 4, child=0)
  ```
] <alg:addresses-hd-master>

=== Child key derivation <sec:addresses-hd-child>

Child indices are 32-bit unsigned integers. Indices from 0 to $2^31 - 1$
are *normal*; indices from $2^31$ (#const("HardenedKeyStart") $= 2^31$
$= #raw("0x80000000")$) to $2^32 - 1$ are *hardened* and are written with a
prime, so $0'$ is index $2^31$. A hardened child can only be derived from an
extended private key; a normal child of a public key can be derived from the
public key alone, and equals the public key of the corresponding private
child.

To describe Decred's variation exactly, an extended private key is taken to
hold its private key as a byte string `key` of 1 to 32 bytes whose
big-endian value is the private scalar. A master key, and any key parsed
from its serialized form, holds exactly 32 bytes. A private key produced by
Decred child derivation holds the 32-byte big-endian value *with its leading
zero bytes removed*. The parent's bytes enter the HMAC input of a hardened
child left-justified, followed by zero padding, so a stripped key produces a
different child from the standard BIP32 one.

#algorithm("Child key derivation (Decred variant)", src: ("hdkeychain/extendedkey.go · child", "hdkeychain/extendedkey.go · Child, ChildBIP32Std"))[
  ```python
  def ckd(parent: ExtKey, i: uint32, strict: bool = False) -> ExtKey:
      hardened = i >= 0x80000000
      if hardened and not parent.private:
          error("cannot derive a hardened key from a public key")
      if hardened:
          # 0x00, then the parent key bytes LEFT-justified in 32 bytes, then i.
          # Identical to BIP32's 0x00 || ser256(k) only when len(parent.key) == 32.
          data = b"\x00" + parent.key + b"\x00" * (32 - len(parent.key)) + be32(i)
      else:
          data = pubkey(parent) + be32(i)           # 33-byte compressed key
      I = HMAC_SHA512(key=parent.chain_code, data=data)
      IL, IR = I[0:32], I[32:64]
      t = int_from_be(IL)
      if t >= N or t == 0:
          error("invalid child")                    # caller skips to index i + 1
      if parent.private:
          k = (t + int_from_be(parent.key)) % N     # k == 0 is not checked
          key = be256(k)                            # 32 bytes
          if not strict:
              key = strip_leading_zero_bytes(key)   # Decred variant (Child)
      else:
          key = ser_compressed(t * G + parse_point(parent.key))
      return ExtKey(private=parent.private, key=key, chain_code=IR,
                    depth=parent.depth + 1, child=i,
                    parent_fp=HASH160(pubkey(parent))[0:4])

  def pubkey(k: ExtKey) -> bytes:
      if k.private:
          return ser_compressed((int_from_be(k.key) % N) * G)
      return k.key
  ```
] <alg:addresses-hd-child>

dcrd exposes the Decred variant as `Child` and a strictly conforming variant
(`strict = True`, never stripping) as `ChildBIP32Std`. The flag affects only
the key that is returned: `ChildBIP32Std` applied to a parent that `Child`
has already stripped still places the stripped bytes left-justified in the
HMAC input, exactly as `Child` does. *Decred wallets use `Child`*, and an
implementation that must reproduce existing wallets' addresses #MUST
implement the stripping and the left-justified layout exactly as above.

#pitfall[
  The result depends on how the parent was obtained, not only on its value.
  The same private key yields different hardened children when it was just
  derived by `Child` (stripped) and when it was parsed from a serialized
  extended key (32 bytes). For example, deriving $1'$ from the vector-4 key
  $m slash 0'$ below gives one result if $m slash 0'$ was derived in memory
  and the strict BIP32 result if $m slash 0'$ was first serialized and
  parsed. The serialized form always carries the full 32 bytes. Normal
  children are unaffected, because they depend only on the public key.
]

#pitfall[
  In the wallet path of @sec:addresses-bip44, the dcrwallet source examined
  for this document (its development branch as of November 2026) derives the
  purpose key $m slash 44'$, both coin-type keys and account 0 in memory
  with `Child` when the wallet is created or restored, but derives every
  later account, and the candidate accounts that account discovery scans
  during a restore, from the coin-type key after it has been serialized,
  stored and parsed. Hence the coin-type key depends on whether $m slash 44'$
  begins with a zero byte, account 0 depends on whether the coin-type key
  does (each with probability about $1/256$), and accounts 1 and above are
  derived from the full 32-byte coin-type key, as in strict BIP32. A wallet
  that must restore dcrwallet accounts reproduces this exactly.
]

#rationale[
  The stripping is a legacy behaviour, apparently dating from the original
  Decred port of the BIP32 code. The dcrd source keeps it because changing it "would break
  derivation for a lot of Decred wallets that rely on this behavior".
]

Further details of dcrd's behaviour, relevant only in edge cases:

- A child index whose `IL` is not a valid scalar is reported as invalid and
  wallets move to the next index; the probability is below $2^(-127)$.
- dcrd does not check that a private child key is non-zero or that a public
  child point is not the point at infinity, which BIP32 requires; both have
  negligible probability.
- The depth is kept as a 16-bit number in memory but serialized modulo 256.

=== Serialization

#fieldtable(
  caption: [Extended key serialization (78 bytes, then a 4-byte checksum, then Base58)],
  ("version", "[4]byte", "4", [#param("HDPrivateKeyID") for a private key, #param("HDPublicKeyID") for a public key.]),
  ("depth", "uint8", "1", [0 for the master key, 1 for its children, and so on.]),
  ("parent_fp", "[4]byte", "4", [Parent fingerprint; zero for the master key.]),
  ("child", "uint32 BE", "4", [Index of this key in its parent; 0 for the master key.]),
  ("chain_code", "[32]byte", "32", [Chain code.]),
  ("key_data", "[33]byte", "33", [Private: `0x00` followed by the private key left-padded with zeros to 32 bytes. Public: the 33-byte compressed public key.]),
  ("checksum", "[4]byte", "4", [$"BLAKE256"("BLAKE256"(dot))[0:4]$ of the preceding 78 bytes.]),
) <tab:addresses-xkey>

The 82 bytes are Base58-encoded as a whole; there is no separate
Base58Check prefix. Parsing reverses this:

#algorithm("Parsing a serialized extended key", src: "hdkeychain/extendedkey.go · NewKeyFromString")[
  ```python
  def parse_ext_key(s: str, net) -> ExtKey:
      if len(s) > 113:                       # 82 * 137 // 100 + 1
          error("invalid key length")
      d = base58_decode(s)
      if len(d) != 82:
          error("invalid key length")
      if BLAKE256(BLAKE256(d[0:78]))[0:4] != d[78:82]:
          error("bad checksum")
      if d[0:4] not in (net.HDPrivateKeyID, net.HDPublicKeyID):
          error("wrong network")
      depth, parent_fp = d[4], d[5:9]
      child, chain_code, key_data = be32_to_int(d[9:13]), d[13:45], d[45:78]
      if key_data[0] == 0x00:                # private, regardless of the version bytes
          key = key_data[1:33]               # 32 bytes, leading zeros kept
          if int_from_be(key) >= N or int_from_be(key) == 0:
              error("unusable seed")
          return ExtKey(private=True, key=key, ...)
      require_valid_compressed_secp256k1_point(key_data)
      return ExtKey(private=False, key=key_data, ...)
  ```
] <alg:addresses-xkey-parse>

#pitfall[
  dcrd decides whether a parsed key is private from the first byte of the
  key data, not from the version bytes, and accepts either of the network's
  two versions with either kind of key; re-serializing such a key writes the
  version that matches its kind, not the one it was parsed with. It also
  does not check that a depth-0 key has a zero fingerprint and child number.
  Strict
  implementations that add these checks will reject strings that dcrd
  accepts; no conforming encoder produces such strings.
]

=== Wallet account structure (convention) <sec:addresses-bip44>

The layout of the key tree is a wallet convention, not part of dcrd.
dcrwallet follows BIP43 @bip43 and BIP44 @bip44:

$ m slash 44' slash "coin_type"' slash "account"' slash "branch" slash "index" $

- *Coin type* is #param("SLIP0044CoinType") from the SLIP-0044 registry
  @slip44: 42 on the main network and 1 ("all test networks") elsewhere.
  Older wallets used the coin types now kept as #param("LegacyCoinType")
  (20, 11, 115 and 1 for mainnet, testnet3, simnet and regnet). dcrwallet
  stores the keys of both coin types, starts on the legacy one for backward
  compatibility, and switches to the SLIP-0044 coin type when no legacy
  address or account has been used: immediately for a newly generated seed,
  and after address discovery for a restored seed. Wallet restoration
  therefore #SHOULD scan both coin types.
- *Account* numbers run from 0 (the default account) to $2^31 - 2$;
  dcrwallet reserves $2^31 - 1$ for imported keys, which are not
  HD-derived.
- *Branch* 0 is the external branch (receiving addresses) and branch 1 the
  internal branch (change). Both are normal children, so an account's
  extended public key suffices to derive all of its addresses.
- *Index* runs from 0 upward. dcrwallet's default gap limit, the number of
  consecutive unused addresses after which address discovery stops, is 20.

A wallet address is the P2PKH-ECDSA address of the compressed public key at
the leaf. dcrwallet's mnemonic seed (33 words from the PGP word list: 32
encoding a 256-bit seed and one checksum word) is outside the scope of this document.

=== Test vectors

#vector[HD chain from the BIP32 test vector 1 seed (main network)][
  Seed `000102030405060708090a0b0c0d0e0f` (the seed of BIP32 test vector 1).
  No private key on the path $m slash 0' slash 1 slash 2'$ begins with a zero
  byte, so its keys and chain codes are those of standard BIP32; the
  fingerprints, checksums and strings are Decred's.
  #kv(
    [$m$ private], [#hex("e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35")],
    [$m$ chain code], [#hex("873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508")],
    [$m$ public], [#hex("0339a36013301597daef41fbe593a02cc513d0b55527ec2df1050e2e8ff49c85c2")],
    [$m$ serialized (private)], [#hex("02fda4e8000000000000000000873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d50800e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b3530117b28")],
    [$m$ dprv], [#hex("dprv3hCznBesA6jBtmoyVFPfyMSZ1qYZ3WdjdebquvkEfmRfxC9VFEFi2YDaJqHnx7uGe75eGSa3Mn3oHK11hBW7KZUrPxwbCPBmuCi1nwm182s")],
    [$m$ dpub], [#hex("dpubZ9169KDAEUnyoBhjjmT2VaEodr6pUTDoqCEAeqgbfr2JfkB88BbK77jbTYbcYXb2FVz7DKBdW4P618yd51MwF8DjKVopSbS7Lkgi6bowX5w")],
    [Fingerprint of $m$], [`bc495588` (first 4 bytes of #hex("bc495588ca4ffd88706347cce9791fc800e13535"))],
    [$m slash 0'$ dprv], [#hex("dprv3kUQDBztdyjKuwnaL3hfKYpT7W6X2huYH5d61YSWFBebSYwEBHAXJkCpQ7rvMAxPzKqxVCGLvBqWvGxXjAyMJsV1XwKkfnQCM9KctC8k8bk")],
    [$m slash 0'$ dpub], [#hex("dpubZCGVaKZBiMo7pMgLaZm1qmchjWenTeVcUdFQkTNsFGFEA6xs4EW8PKiqYqP7HBAitt9Hw16VQkQ1tjsZQSHNWFc6bEK6bLqrbco24FzBTY4")],
    [$m slash 0' slash 1$ dprv], [#hex("dprv3nRtCZ5VAoHW4RUwQgRafSNRPUDFrmsgyY71A5eoZceVfuyL9SbZe2rcbwDW2UwpkEniE4urffgbypegscNchPajWzy9QS4cRxF8QYXsZtq")],
    [$m slash 0' slash 1$ dpub], [#hex("dpubZEDyZgdnFBMHxqNhfCUwBfAg1UmXHiTmB5jKtzbAZhF8PTzy2PwAicNdkg1CmW6TARxQeUbgC7nAQenJts4YoG3KMiqcjsjgeMvwLc43w6C")],
    [$m slash 0' slash 1 slash 2'$ dprv], [#hex("dprv3pYtkZK168vgrU38gXkUSjHQ2LGpEUzQ9fXrR8fGUR59YviSnm6U82XjQYhpJEUPnVcC9bguJBQU5xVM4VFcDHu9BgScGPA6mQMH4bn5Cth")],
    [$m slash 0' slash 1 slash 2'$ dpub], [#hex("dpubZGLz7gsJAWzUksvtw3opxx5eeLq5fRaUMDABA3bdUVfnGUk5fiS5Cc3kZGTjWtYr3jrEavQQnAF6jv2WCpZtFX4uFgifXqev6ED1TM9rTCB")],
    [$m slash 44' slash 42' slash 0' slash 0 slash 0$ private], [#hex("062030a1065be57e24b89fad7413b576b5d06a2c11faff137b9c437649d62e08")],
    [$m slash 44' slash 42' slash 0' slash 0 slash 0$ public], [#hex("03976beeebefe06a527bdd1ebbe8e9077f388df42aa29b14348bff6ff7da8dabc1")],
    [$m slash 44' slash 42' slash 0' slash 0 slash 0$ address], [`DsVxTiRYVKtUQogbS6prKdQvFb4dUwy7KyM` (all steps derived in memory with `Child`)],
  )
  Deriving $m slash 0' slash 1$ from the neutered $m slash 0'$ gives the
  same dpub as neutering the private $m slash 0' slash 1$.
]

#vector[Leading-zero stripping (BIP32 test vector 4 seed, main network)][
  Seed #hex("3ddd5602285899a946114506157c7997e5444528f3003f6134712147db19b678").
  The private key of $m slash 0'$ is
  #hex("00d948e9261e41362a688b916f297121ba6bfb2274a3575ac0e456551dfd7f7e"),
  which begins with a zero byte; `Child` holds it as the 31 bytes after that
  zero. The chain code of $m slash 0'$ is
  #hex("cdc0f06456a14876c898790e0b3b1a41c531170aec69da44ff7b7265bfe7743b").
  Both methods serialize $m slash 0'$ identically:
  #hex("dprv3jkqwzsd88yXqZJdSuLnfKqGPYzCVffataF79tcuPhdudeU3d1uUpvwn5Btmbai3BoVYhzbsEQ7tcH1XtEJ1BhzNSAtZfqv8BtSpdq5FEpj").
  The HMAC inputs and results for $m slash 0' slash 1'$ differ:
  #kv(
    [`Child` input], [#hex("00d948e9261e41362a688b916f297121ba6bfb2274a3575ac0e456551dfd7f7e0080000001")],
    [`Child` private key], [#hex("bf33f8c13baf010213cd34f488297f7729d560871286b2e360b25bc9fecc96f4")],
    [`Child` dprv], [#hex("dprv3mhK5vAEzovJTfnqwfzGTamym6yPPGEggq5fpQHrnXGyb22Doqew7Co7mCvYHe6nTCewnggesjM4LVJj8RFJ92ANtogs3NY7ev4YxSwf6ez")],
    [Strict input], [#hex("0000d948e9261e41362a688b916f297121ba6bfb2274a3575ac0e456551dfd7f7e80000001")],
    [Strict private key], [#hex("3a2086edd7d9df86c3487a5905a1712a9aa664bce8cc268141e07549eaa8661d")],
    [Strict dprv], [#hex("dprv3mhK5vAEzovJUV5RycwKGbth8MYtoYL1aJTxN1T8PLmH6da6aMU8nYKQiC5Zj7mC7pH4G8xPxGZVR51FG9Ssptzx1c39A1JxADS6zDrsLPr")],
  )
  Parsing the serialized $m slash 0'$ and then applying `Child(1')` yields
  the strict dprv. The normal child $m slash 0' slash 1$ is the same under
  both methods.
]

== Amounts <sec:addresses-amounts>

All protocol amounts are integers of atoms, $10^8$ atoms to the coin
(#chref("conventions")). User interfaces and the JSON-RPC interface express
amounts in coins as decimal numbers. dcrd's conversion helpers, which are
not consensus code, behave as follows:

- Coins to atoms multiplies the double-precision value by $10^8$, adds 0.5
  (subtracts 0.5 if the product is negative), both in double precision, and
  truncates toward zero. NaN and infinities are rejected; the range is not
  checked, and an out-of-range value converts to an unspecified integer.
- Formatting divides the amount by the unit's number of atoms in double
  precision and writes the result with the shortest decimal representation
  that round-trips that double (with no decimal places for the Atom unit),
  followed by a space and the unit name of @tab:addresses-units. For
  example, 44433322211100 atoms
  formats as `444333.222111 DCR`, `444.333222111 kDCR` or
  `44433322211100 Atom`.

#figure(
  caption: [Amount units],
  table(
    columns: (auto, auto, auto),
    table.header([Unit], [Atoms], [Name]),
    [Megacoin], [$10^14$], [`MDCR`],
    [Kilocoin], [$10^11$], [`kDCR`],
    [Coin], [$10^8$], [`DCR`],
    [Millicoin], [$10^5$], [`mDCR`],
    [Microcoin], [$10^2$], [`μDCR`],
    [Atom], [1], [`Atom`],
  ),
) <tab:addresses-units>

Implementations that handle amounts #SHOULD convert to integer atoms at the
boundary and never compute with floating-point coin values.

== Bech32 <sec:addresses-bech32>

dcrd contains a `bech32` package implementing the Bech32 encoding of BIP173
@bip173 (the original Bech32 checksum constant 1, not Bech32m), with the
standard 32-character alphabet `qpzry9x8gf2tvdw0s3jn54khce6mua7l` and a
90-character limit in its standard decoder. *No Decred address format uses
Bech32*, and no dcrd code calls the package (its only import is a blank
import that keeps it in dcrd's module requirements); it is published for
other software, such as Lightning Network payment requests, which its
documentation names.
