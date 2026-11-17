#import "../template.typ": *

= Cryptographic Primitives <ch:crypto>

This chapter specifies every cryptographic primitive on which Decred's
consensus rules depend: the hash functions, the elliptic curves, the three
signature schemes that scripts can verify, and the Merkle tree used to commit
to the transactions of a block. Later chapters use these primitives by name
and do not repeat their definitions.

Decred differs from Bitcoin in its choice of primitives more than its
structure suggests. Its general-purpose hash is BLAKE-256, not double SHA-256;
its proof-of-work hash has been BLAKE-256 and then BLAKE3; and besides ECDSA
over secp256k1 its script language can verify Schnorr signatures over
secp256k1 (a Decred-specific scheme) and Ed25519 signatures. The definitions
below are taken from the reference implementation. Where a primitive is
specified by an external standard, the standard is cited and the parameters
and any departures from it are stated.

@tab:crypto-overview summarizes the primitives and where they appear.

#figure(
  caption: [Cryptographic primitives and their uses],
  table(
    columns: (auto, auto, 1fr),
    table.header([Primitive], [Section], [Used for]),
    [BLAKE-256 (14 rounds)], [@sec:crypto-blake256], [Transaction and block hashes, Merkle trees, signature hashes, the version 1 proof-of-work hash, `OP_BLAKE256`, `OP_HASH160`, `OP_HASH256`, the Schnorr challenge],
    [BLAKE3], [@sec:crypto-blake3], [The version 2 proof-of-work hash (#dcp(11))],
    [RIPEMD-160], [@sec:crypto-sha], [`OP_RIPEMD160`, `OP_HASH160`, address hashes],
    [SHA-256], [@sec:crypto-sha], [`OP_SHA256`; HMAC inside deterministic nonce generation (not consensus)],
    [SHA-1], [@sec:crypto-sha], [`OP_SHA1`],
    [secp256k1], [@sec:crypto-secp256k1], [Public keys for ECDSA and EC-Schnorr-DCRv0],
    [ECDSA], [@sec:crypto-ecdsa], [`OP_CHECKSIG`, `OP_CHECKMULTISIG` and their `VERIFY` forms],
    [EC-Schnorr-DCRv0], [@sec:crypto-schnorr], [`OP_CHECKSIGALT` with signature type 2; treasury spend authorization],
    [Ed25519], [@sec:crypto-ed25519], [`OP_CHECKSIGALT` with signature type 1],
    [Merkle tree], [@sec:crypto-merkle], [Transaction tree roots in the block header; header commitment proofs],
  ),
) <tab:crypto-overview>

== Notation <sec:crypto-notation>

A *word* is a `uint32`. For words, $a + b$ in the hash function definitions
means addition modulo $2^32$, $a plus.o b$ (`^` in pseudocode) is
bitwise exclusive or, and $"rotr"(a, n)$ is rotation to the right by $n$
bits. In pseudocode the mask `M32 = 0xffffffff` makes the reduction modulo
$2^32$ explicit.

For an integer $x$ with $0 <= x < 2^256$, $"BE"_256 (x)$ is its 32-byte
big-endian encoding and $"LE"_256 (x)$ its 32-byte little-endian encoding.
For a byte string $b$, $"int"_"BE" (b)$ and $"int"_"LE" (b)$ interpret $b$ as
an unsigned integer in big-endian and little-endian order, and $b[i:j]$ is
the substring of bytes $i$ up to but not including $j$, counting from 0.
$||$ is concatenation.

The pseudocode follows #xref("conv:pseudocode") and uses these helpers in
addition: `be32(w)`, `le32(w)` and `be64(x)` encode an integer as 4 or 8
bytes; `be32_decode(b)` and `le32_decode(b)` decode 4 bytes; `be256(x)` is
$"BE"_256 (x)$; `int_be(b)` and `int_le(b)` are $"int"_"BE"$ and
$"int"_"LE"$; `left_pad(b, 32)` prefixes zero bytes up to 32 bytes;
`blake256` is @alg:crypto-blake256; `hmac_sha256(K, m)` is HMAC
(RFC 2104 @rfc2104) with SHA-256;
`pow(a, e, m)` is modular exponentiation; and `scalar_mult`, `point_add`
and `INFINITY` are elliptic curve scalar multiplication, point addition
(complete, handling the identity and doubling) and $cal(O)$.

For elliptic curves, upper-case letters denote points and lower-case letters
integers. $k G$ is scalar multiplication, $cal(O)$ is the point at infinity
(the group identity), and $P.x$, $P.y$ are the affine coordinates of a point
$P eq.not cal(O)$, always as fully reduced integers. An integer is *odd* or
*even* according to its least significant bit after full reduction.

== BLAKE-256 <sec:crypto-blake256>

BLAKE-256 is the 256-bit member of the BLAKE family, a finalist of the NIST
SHA-3 competition, in the final version 1.3 of its specification, which uses
14 rounds @blake. Decred uses it wherever Bitcoin uses SHA-256 or double
SHA-256. It is not BLAKE2s (a later, different function with 10 rounds and
little-endian words), and it is not the 10-round BLAKE-32 of the first round
of the competition. BLAKE-256 is an iterated hash with a 512-bit block, a
256-bit chaining value, and a 64-bit counter of message bits; the
specification also defines an optional 128-bit salt. Decred always uses a
zero salt, and the definition below is written with the salt removed.

#rule("BLAKE-256", src: ("crypto/blake256/hasher.go · finalize, finalize256", "crypto/blake256/internal/compress/blocks_generic.go · blocksGeneric"))[
  Wherever this document writes BLAKE-256, or $H$, the function defined by
  @alg:crypto-blake256-compress and @alg:crypto-blake256 with the constants of
  @tab:crypto-blake-iv, @tab:crypto-blake-c and @tab:crypto-sigma is meant.
  Its output is always 32 bytes. An implementation #MUST reproduce it bit for
  bit, including the counter rule for padding-only blocks.
] <rule:crypto-blake256>

=== Constants

The initial chaining value (@tab:crypto-blake-iv) is the same as SHA-256's.
The sixteen constants $c_0, ..., c_15$ (@tab:crypto-blake-c) are the first
512 bits of the fractional part of $pi$. Each round uses one of ten
permutations $sigma_0, ..., sigma_9$ of the message word indices
(@tab:crypto-sigma); round $r$ (counting from 0) uses $sigma_(r mod 10)$, so
rounds 10 to 13 repeat $sigma_0$ to $sigma_3$.

#figure(
  caption: [BLAKE-256 initial chaining value $"IV"$ (also the BLAKE3 IV)],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    table.header([$"IV"_0$], [$"IV"_1$], [$"IV"_2$], [$"IV"_3$], [$"IV"_4$], [$"IV"_5$], [$"IV"_6$], [$"IV"_7$]),
    `6a09e667`, `bb67ae85`, `3c6ef372`, `a54ff53a`, `510e527f`, `9b05688c`, `1f83d9ab`, `5be0cd19`,
  ),
) <tab:crypto-blake-iv>

#figure(
  caption: [BLAKE-256 constants $c_i$],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    table.header([$c_0$], [$c_1$], [$c_2$], [$c_3$], [$c_4$], [$c_5$], [$c_6$], [$c_7$]),
    `243f6a88`, `85a308d3`, `13198a2e`, `03707344`, `a4093822`, `299f31d0`, `082efa98`, `ec4e6c89`,
    [*$c_8$*], [*$c_9$*], [*$c_10$*], [*$c_11$*], [*$c_12$*], [*$c_13$*], [*$c_14$*], [*$c_15$*],
    `452821e6`, `38d01377`, `be5466cf`, `34e90c6c`, `c0ac29b7`, `c97c50dd`, `3f84d5b5`, `b5470917`,
  ),
) <tab:crypto-blake-c>

#figure(
  caption: [BLAKE message permutations $sigma_j$: entry $i$ of row $j$ is $sigma_j (i)$],
  table(
    columns: 17,
    align: right,
    table.header([], [0], [1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [11], [12], [13], [14], [15]),
    [$sigma_0$], [0], [1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [11], [12], [13], [14], [15],
    [$sigma_1$], [14], [10], [4], [8], [9], [15], [13], [6], [1], [12], [0], [2], [11], [7], [5], [3],
    [$sigma_2$], [11], [8], [12], [0], [5], [2], [15], [13], [10], [14], [3], [6], [7], [1], [9], [4],
    [$sigma_3$], [7], [9], [3], [1], [13], [12], [11], [14], [2], [6], [5], [10], [4], [0], [15], [8],
    [$sigma_4$], [9], [0], [5], [7], [2], [4], [10], [15], [14], [1], [11], [12], [6], [8], [3], [13],
    [$sigma_5$], [2], [12], [6], [10], [0], [11], [8], [3], [4], [13], [7], [5], [15], [14], [1], [9],
    [$sigma_6$], [12], [5], [1], [15], [14], [13], [4], [10], [0], [7], [6], [3], [9], [2], [8], [11],
    [$sigma_7$], [13], [11], [7], [14], [12], [1], [3], [9], [5], [0], [15], [4], [8], [6], [2], [10],
    [$sigma_8$], [6], [15], [14], [9], [11], [3], [0], [8], [12], [2], [13], [7], [1], [4], [10], [5],
    [$sigma_9$], [10], [2], [8], [4], [7], [6], [1], [5], [15], [11], [9], [14], [3], [12], [13], [0],
  ),
) <tab:crypto-sigma>

=== Compression function

The compression function maps a chaining value $h_0, ..., h_7$, a 64-byte
block and the counter $t$ to a new chaining value. The block is read as
sixteen *big-endian* words $m_0, ..., m_15$. A 16-word state
$v_0, ..., v_15$, viewed as a $4 times 4$ matrix, is initialized from the
chaining value, the constants and the counter; each round applies the
function $G$ to the four columns and then to the four diagonals of the
matrix. In the $i$-th application of $G$ within round $r$, with
$sigma = sigma_(r mod 10)$, the message word $m_(sigma(2i))$ is combined with
the constant $c_(sigma(2i+1))$, and $m_(sigma(2i+1))$ with $c_(sigma(2i))$.
In the pseudocode, `IV`, `C` and `SIGMA` are the tables
@tab:crypto-blake-iv, @tab:crypto-blake-c and @tab:crypto-sigma, indexed
from 0.

#algorithm("BLAKE-256 compression", src: "crypto/blake256/internal/compress/blocks_generic.go · g, blocksGeneric")[
  ```python
  M32 = 0xffffffff

  def rotr32(x, n):
      return ((x >> n) | (x << (32 - n))) & M32

  def G(v, m, sigma, i, a, b, c, d):
      x, y = sigma[2 * i], sigma[2 * i + 1]
      v[a] = (v[a] + v[b] + (m[x] ^ C[y])) & M32
      v[d] = rotr32(v[d] ^ v[a], 16)
      v[c] = (v[c] + v[d]) & M32
      v[b] = rotr32(v[b] ^ v[c], 12)
      v[a] = (v[a] + v[b] + (m[y] ^ C[x])) & M32
      v[d] = rotr32(v[d] ^ v[a], 8)
      v[c] = (v[c] + v[d]) & M32
      v[b] = rotr32(v[b] ^ v[c], 7)

  def blake256_compress(h: list[uint32], block: bytes, t: uint64) -> list[uint32]:
      m = [be32_decode(block[4 * i : 4 * i + 4]) for i in range(16)]
      t0, t1 = t & M32, t >> 32
      v = h[0:8] + C[0:4] + [t0 ^ C[4], t0 ^ C[5], t1 ^ C[6], t1 ^ C[7]]
      for r in range(14):
          sigma = SIGMA[r % 10]
          G(v, m, sigma, 0, 0, 4,  8, 12)     # columns
          G(v, m, sigma, 1, 1, 5,  9, 13)
          G(v, m, sigma, 2, 2, 6, 10, 14)
          G(v, m, sigma, 3, 3, 7, 11, 15)
          G(v, m, sigma, 4, 0, 5, 10, 15)     # diagonals
          G(v, m, sigma, 5, 1, 6, 11, 12)
          G(v, m, sigma, 6, 2, 7,  8, 13)
          G(v, m, sigma, 7, 3, 4,  9, 14)
      return [h[i] ^ v[i] ^ v[i + 8] for i in range(8)]
  ```
] <alg:crypto-blake256-compress>

With a non-zero salt $s_0, ..., s_3$, the initial $v_8, ..., v_11$ would be
$s_i plus.o c_i$ and the output $h_i plus.o s_(i mod 4) plus.o v_i plus.o v_(i+8)$; with
the zero salt used by Decred these reduce to the expressions above.

=== Padding, counter and output

The message is padded with a 1 bit, then zero bits until its length is
congruent to 447 modulo 512, then a 1 bit (which distinguishes BLAKE-256 from
BLAKE-224, where this bit is 0), and finally the message length in bits as a
64-bit big-endian integer. For messages made of whole bytes this is the byte
sequence `80 00 ... 00 01` followed by the length, where the first and last
padding bytes merge into the single byte `81` when exactly one padding byte
fits.

The counter $t$ passed with each block is the number of *message* bits
contained in that block and all preceding blocks. A block that contains no
message bits at all, which is the case for the only block of the empty
message, for the extra padding block appended when a message's final partial
block has more than 55 bytes, and for the padding block of a message whose
length is a non-zero multiple of 64, is compressed with $t = 0$.

#algorithm("BLAKE-256", src: "crypto/blake256/hasher.go · write, finalize, wordsToBytes256")[
  ```python
  def blake256(msg: bytes) -> bytes:
      L = len(msg)
      p = bytearray(msg) + b"\x80"
      while len(p) % 64 != 56:
          p += b"\x00"
      p[-1] |= 0x01                       # 0x80 becomes 0x81 if L % 64 == 55
      p += be64(8 * L)
      h = IV
      for j in range(len(p) // 64):
          if 64 * j < L:
              t = 8 * min(64 * (j + 1), L)    # message bits up to the end of block j
          else:
              t = 0                           # block holds padding only
          h = blake256_compress(h, p[64 * j : 64 * j + 64], t)
      return be32(h[0]) + be32(h[1]) + ... + be32(h[7])
  ```
] <alg:crypto-blake256>

#pitfall[
  Three details distinguish BLAKE-256 from the functions it resembles and
  are the usual causes of wrong output: the message words and the output are
  *big-endian* (BLAKE2 and BLAKE3 are little-endian); every message word is
  XORed with a constant before it is added, and the constant index is the
  *other* half of the $sigma$ pair; and a block containing only padding is
  compressed with counter 0, not with the total bit length. The vectors for
  55-, 56- and 64-byte inputs below exercise the three padding cases.
]

#vector[BLAKE-256][
  ```
  input                                            BLAKE-256
  (empty)                                       716f6e863f744b9ac22c97ec7b76ea5f
                                                5908bc5b2f67c61510bfc4751384ea7a
  00                                            0ce8d4ef4dd7cd8d62dfded9d4edb0a7
                                                74ae6a41929a74da23109e8f11139c87
  "abc"                                         1833a9fa7cf4086bd5fda73da32e5a1d
                                                75b4c3f89d5c436369f9d78bb2da5c28
  "a" x 55                                      6e8d7898571228c1106fcec9ef9c5db9
                                                df8a3a2dcd2655a848af596d181bbae4
  "a" x 56                                      ea7a29472a26148914abb8033869be9b
                                                dea294fdd2b73ed7a02a7692940f5b9e
  "a" x 64                                      84d7f3bbf2cfc3ee940ddb6d25045c6d
                                                3f756c4b2077a8128e171d5d165be170
  00 x 72                                       d419bad32d504fb7d44d460c42c5593f
                                                e544fa4c135dec31e21bd9abdcc22d41
  "The quick brown fox jumps over the lazy dog" 7576698ee9cad30173080678e5965916
                                                adbb11cb5245d386bf1ffda1cb26c9d7
  ```
  Quoted inputs are ASCII without a terminator; `"a" x 55` is 55 bytes of
  `0x61`. The 1-byte and 72-byte inputs are the examples from the BLAKE
  specification @blake.
]

== Hash Functions Derived from BLAKE-256 <sec:crypto-derived>

dcrd names its general-purpose hash `chainhash.HashB` (returning bytes) and
`chainhash.HashH` (returning a 32-byte hash value); both are a single
BLAKE-256. Transaction hashes, block hashes, Merkle tree nodes and signature
hashes all use this single application. @tab:crypto-derived lists the other
compositions in use.

#figure(
  caption: [Hash functions derived from BLAKE-256],
  table(
    columns: (auto, auto, 1fr),
    table.header([Name], [Definition], [Used by]),
    [$H(x)$], [BLAKE-256$(x)$], [Everything not listed below],
    [HASH256$(x)$], [BLAKE-256(BLAKE-256$(x)$)], [`OP_HASH256` (the only consensus use); the Base58Check checksum (#chref("addresses"))],
    [HASH160$(x)$], [RIPEMD-160(BLAKE-256$(x)$)], [`OP_HASH160`; public key hashes and script hashes in addresses (#chref("addresses"))],
    [Message hash], [BLAKE-256$("varstr"("Decred Signed Message:\\n") || "varstr"(m))$], [Signed messages (@sec:crypto-compact); not consensus],
  ),
) <tab:crypto-derived>

#rule("Derived hash functions", src: ("chaincfg/chainhash/hashfuncs.go · HashB, HashH", "txscript/opcode.go · opcodeHash160, opcodeHash256", "txscript/stdaddr/addressv0.go · Hash160"))[
  HASH160 #MUST be computed as RIPEMD-160 of the 32-byte BLAKE-256 digest,
  giving 20 bytes. HASH256 #MUST be computed as BLAKE-256 of the 32-byte
  BLAKE-256 digest. Where a consensus structure is said to be hashed without
  further qualification, a single BLAKE-256 is meant.
] <rule:crypto-derived>

#pitfall[
  Decred has no double hashing in its block or transaction identifiers,
  Merkle trees or signature hashes. An implementation adapted from Bitcoin
  code must remove the second hash everywhere in consensus except
  `OP_HASH256`, and must replace SHA-256 by BLAKE-256 inside HASH160.
]

#vector[Derived hashes][
  ```
  HASH256("")    d8ee5f957b78a961fb729098b4efb56440a14e05e3c55890f5edbc626380aaa6
  HASH256("abc") f1a44bb867d5ac7053d5e071d62d4513d5b243420d9863e2718823a161c1344a
  HASH160(02ba9cf60e2ea62eb020697b80a34eaaf17cdf7ee6114b3bdbdaac3494066a10fd)
                   2f4b63971d0e28df5c6fa3ace542adb5eee4b2ab
  ```
  The public key is the one used in the ECDSA vectors of @sec:crypto-ecdsa.
]

== BLAKE3 <sec:crypto-blake3>

Since the activation of the `blake3pow` agenda (#dcp(11)), the proof-of-work
hash of a block header is BLAKE3 @blake3 instead of BLAKE-256. dcrd computes
it with the Go library `lukechampine.com/blake3` at version v1.3.0, in the
default *hash* mode (unkeyed, no key derivation) with a 32-byte output.
The input is the 180-byte serialized block header, the same bytes that are
hashed with BLAKE-256 to form the block hash (#chref("encoding")). Which
blocks use which proof-of-work hash, and how the result is compared with the
target, is specified in #chref("difficulty").

#rule("BLAKE3 proof-of-work hash function", src: ("wire/blockheader.go · PowHashV2", "lukechampine.com/blake3 v1.3.0 · New, Sum"))[
  The BLAKE3 hash used by Decred #MUST be the BLAKE3 hash function of
  @blake3 in hash mode with the default 32-byte output, which is the first 32
  bytes of the extendable output. For inputs of at most 1024 bytes, including
  the 180-byte block header, it is fully specified by
  @alg:crypto-blake3; longer inputs, which do not occur in consensus, use the
  tree mode of @blake3.
] <rule:crypto-blake3>

BLAKE3 splits its input into 1024-byte chunks, each made of up to sixteen
64-byte blocks, and combines the chunks in a binary tree. An input of at most
1024 bytes is a single chunk, which is also the root of the tree, so the
hash is computed by chaining the compression function over the blocks of
that chunk. The compression function shares the $G$ function and rotation
amounts of BLAKE-256 but differs in everything else: 7 rounds, little-endian
words, no constants mixed into the message, a fixed message permutation
applied between rounds, and a state that includes the block length and a
set of domain flags.

#figure(
  caption: [BLAKE3 parameters used for single-chunk inputs],
  table(
    columns: (auto, 1fr),
    table.header([Parameter], [Value]),
    [IV], [Identical to the BLAKE-256 IV of @tab:crypto-blake-iv],
    [Message permutation `PERM`], [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 (new word $i$ is old word `PERM[i]`)],
    [Flags], [`CHUNK_START` = 1, `CHUNK_END` = 2, `ROOT` = 8 (`PARENT` = 4 and the keyed and key-derivation flags are not used for single-chunk unkeyed hashing)],
    [Rounds], [7],
    [Counter], [The chunk index, which is 0 for a single-chunk input],
  ),
) <tab:crypto-blake3>

#algorithm("BLAKE3 for inputs of at most 1024 bytes", src: ("lukechampine.com/blake3 v1.3.0 · guts.CompressNode, guts.CompressChunk", "blake3.go · Hasher.Sum, rootNode"))[
  ```python
  PERM = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
  CHUNK_START, CHUNK_END, ROOT = 1, 2, 8

  def g3(v, a, b, c, d, x, y):
      v[a] = (v[a] + v[b] + x) & M32
      v[d] = rotr32(v[d] ^ v[a], 16)
      v[c] = (v[c] + v[d]) & M32
      v[b] = rotr32(v[b] ^ v[c], 12)
      v[a] = (v[a] + v[b] + y) & M32
      v[d] = rotr32(v[d] ^ v[a], 8)
      v[c] = (v[c] + v[d]) & M32
      v[b] = rotr32(v[b] ^ v[c], 7)

  def blake3_compress(cv, m, counter: uint64, block_len, flags) -> list[uint32]:
      v = cv[0:8] + IV[0:4] + [counter & M32, counter >> 32, block_len, flags]
      for r in range(7):
          g3(v, 0, 4,  8, 12, m[0],  m[1]);  g3(v, 1, 5,  9, 13, m[2],  m[3])
          g3(v, 2, 6, 10, 14, m[4],  m[5]);  g3(v, 3, 7, 11, 15, m[6],  m[7])
          g3(v, 0, 5, 10, 15, m[8],  m[9]);  g3(v, 1, 6, 11, 12, m[10], m[11])
          g3(v, 2, 7,  8, 13, m[12], m[13]); g3(v, 3, 4,  9, 14, m[14], m[15])
          m = [m[PERM[i]] for i in range(16)]
      return [v[i] ^ v[i + 8] for i in range(8)] + [v[i + 8] ^ cv[i] for i in range(8)]

  def blake3_256(msg: bytes) -> bytes:        # len(msg) <= 1024
      n = max(1, (len(msg) + 63) // 64)       # block count; the empty input has one
      cv = IV
      for j in range(n):
          block = msg[64 * j : 64 * j + 64]
          block_len = len(block)              # 64, except possibly for the last block
          block = block + bytes(64 - block_len)
          m = [le32_decode(block[4 * i : 4 * i + 4]) for i in range(16)]
          flags = 0
          if j == 0:
              flags |= CHUNK_START
          if j == n - 1:
              flags |= CHUNK_END | ROOT
          cv = blake3_compress(cv, m, 0, block_len, flags)[0:8]
      return le32(cv[0]) + le32(cv[1]) + ... + le32(cv[7])
  ```
] <alg:crypto-blake3>

For the 180-byte header the chunk has three blocks of 64, 64 and 52 bytes,
compressed with flags 1, 0 and 10 respectively and block lengths 64, 64
and 52.

#vector[BLAKE3 (32-byte output)][
  ```
  (empty)    af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
  "abc"      6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85
  00 x 180   3419118e1c6537b8de8a2e6a22dcc2734c0d92729ce542484de3e829e6e67f12
  ```
]

#vector[Main-network genesis block header][
  ```
  serialized header (180 bytes):
    0100000000000000000000000000000000000000000000000000000000000000
    000000000dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb9
    9174aa6600000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000ffff011b00c2eb0b00000000
    0000000000000000a0d7b8560000000000000000000000000000000000000000
    0000000000000000000000000000000000000000
  BLAKE-256  80d9212bf4ceb066ded2866b39d4ed89e0ab60f335c11df8e7bf85d9c35c8e29
  BLAKE3     1baa4b79809fc85fac9333371d37e203f34c345595f5ed5ed435fbc10b09d3d7
  ```
  Both hashes are shown with their bytes in order. The BLAKE-256 value is the genesis block hash, displayed in reversed byte
  order as in #xref("conv:bytes"). The BLAKE3 value is only an example of the
  function: the genesis block predates #dcp(11) and is never checked against
  it.
]

== SHA-256, SHA-1 and RIPEMD-160 <sec:crypto-sha>

These three functions are used exactly as standardized and are specified by
reference. SHA-256 and SHA-1 are defined in FIPS 180-4 @fips180; RIPEMD-160
is defined by its authors @ripemd160. dcrd uses Go's standard library for
SHA-256 and SHA-1 and a copy of the `golang.org/x/crypto` RIPEMD-160 code
(`crypto/ripemd160`).

In consensus they appear only as script opcodes: `OP_RIPEMD160`, `OP_SHA1`,
`OP_SHA256` (which is interpreted as SHA-256 only when the corresponding
script flag is in effect), and inside `OP_HASH160`. Their stack semantics and
activation are given in #chref("script"). SHA-256 also appears, outside
consensus, as the hash of the HMAC used for deterministic nonces
(@alg:crypto-rfc6979), and SHA-512 inside Ed25519 (@sec:crypto-ed25519).

#vector[SHA-256, SHA-1 and RIPEMD-160][
  ```
  SHA-256("")     e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  SHA-256("abc")  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  SHA-1("")       da39a3ee5e6b4b0d3255bfef95601890afd80709
  SHA-1("abc")    a9993e364706816aba3e25717850c26c9cd0d89d
  RIPEMD-160("")  9c1185a5c5e9fc54612808977ee8f548b2258d31
  RIPEMD-160("abc")
                  8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
  ```
]

== The secp256k1 Curve <sec:crypto-secp256k1>

ECDSA and EC-Schnorr-DCRv0 both operate on secp256k1 @sec2, the Koblitz
curve $y^2 = x^3 + 7$ over the prime field $bb(F)_p$. Its group of points
has prime order $n$ and cofactor 1, so every point other than $cal(O)$
generates the whole group. @tab:crypto-secp256k1 lists the domain
parameters.

#figure(
  caption: [secp256k1 domain parameters (hexadecimal, big-endian)],
  table(
    columns: (auto, 1fr),
    table.header([Parameter], [Value]),
    [$p$], [#hex("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f") $= 2^256 - 2^32 - 977$],
    [$a$, $b$], [$a = 0$, $b = 7$],
    [$G.x$], [#hex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")],
    [$G.y$], [#hex("483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")],
    [$n$], [#hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")],
    [$(n-1)/2$], [#hex("7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0")],
    [$p - n$], [#hex("14551231950b75fc4402da1722fc9baee")],
    [Cofactor $h$], [1],
  ),
) <tab:crypto-secp256k1>

A *scalar* is an integer modulo $n$. A *private key* is a scalar $d$ with
$1 <= d <= n - 1$, and its *public key* is the point $Q = d G$.

=== Public key encodings <sec:crypto-pubkey>

Public keys are serialized in the formats of SEC 1 @sec1 and ANSI X9.62,
with coordinates as 32-byte big-endian integers. The first byte identifies
the format (@tab:crypto-pubkey-formats). dcrd always produces the compressed
format, or the uncompressed format on request, and never produces the hybrid
format.

#figure(
  caption: [secp256k1 public key formats and where each is accepted],
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    table.header([Format], [Prefix], [Length], [Parse (@rule:crypto-pubkey-parse)], [Strict (@rule:crypto-pubkey-strict)], [Schnorr (@rule:crypto-schnorr-pubkey)]),
    [Compressed], [`02` ($y$ even), `03` ($y$ odd)], [33], [yes], [yes], [yes],
    [Uncompressed], [`04`], [65], [yes], [yes], [no],
    [Hybrid], [`06` ($y$ even), `07` ($y$ odd)], [65], [yes], [no], [no],
    [Anything else], [], [], [no], [no], [no],
  ),
) <tab:crypto-pubkey-formats>

#rule("Parsing a secp256k1 public key", src: "dcrec/secp256k1/pubkey.go · PublicKey.parse, ParsePubKey")[
  A byte string $b$ parses as a secp256k1 public key if and only if one of
  the following holds; otherwise parsing fails.
  + $|b| = 65$, $b_0 in {#raw("04"), #raw("06"), #raw("07")}$, and with
    $x = "int"_"BE" (b[1:33])$ and $y = "int"_"BE" (b[33:65])$: $x < p$,
    $y < p$, if $b_0 = #raw("06")$ then $y$ is even, if $b_0 = #raw("07")$ then
    $y$ is odd, and $y^2 equiv x^3 + 7 med (mod p)$. The key is $(x, y)$.
  + $|b| = 33$, $b_0 in {#raw("02"), #raw("03")}$, $x = "int"_"BE" (b[1:33]) < p$,
    and $x^3 + 7$ is a quadratic residue modulo $p$. The key is $(x, y)$
    where $y$ is the square root of $x^3 + 7$ modulo $p$ that is even if
    $b_0 = #raw("02")$ and odd if $b_0 = #raw("03")$.
  Every other length, and every other prefix byte for the given length,
  fails. A successfully parsed key is never $cal(O)$, since $cal(O)$ has no
  encoding.
] <rule:crypto-pubkey-parse>

Because $p equiv 3 med (mod 4)$, the square root of a residue $a$ is
$a^((p+1)/4) mod p$; $x^3 + 7$ is a residue exactly when the square of that
value equals it.

The script engine applies a stricter syntactic test to ECDSA public keys
before parsing them. It is part of the consensus rules wherever the script
chapter applies it (#chref("script")); it rejects the hybrid format even
though the parser accepts it.

#rule("Strict public key encoding", src: ("txscript/engine.go · isStrictPubKeyEncoding", "txscript/consensus.go · CheckPubKeyEncoding"))[
  A public key byte string is *strictly encoded* if and only if it is 33
  bytes long with first byte `02` or `03`, or 65 bytes long with first byte
  `04`. Strict encoding is purely syntactic: it does not check that the
  coordinates are in range or that the point is on the curve.
] <rule:crypto-pubkey-strict>

Since ECDSA public keys in scripts must pass @rule:crypto-pubkey-strict
before they are parsed, and EC-Schnorr-DCRv0 keys must be compressed
(@rule:crypto-schnorr-pubkey), a hybrid key can never validate a signature
in consensus even though @rule:crypto-pubkey-parse accepts it. A key that is
strictly encoded but fails @rule:crypto-pubkey-parse (for example, one not
on the curve) makes the signature check fail rather than aborting the
script (#chref("script")).

#vector[Public key parsing][
  ```
  key                               parse                      strict
  02ba9c...10fd (compressed)        ok                         ok
  04ba9c...1674 (uncompressed)      ok                         ok
  06ba9c...1674 (hybrid, y even)    ok                         rejected
  07ba9c...1674 (hybrid, y even)    fails: parity mismatch     rejected
  05ba9c...1674                     fails: unsupported format  rejected
  04ba9c...1675 (y + 1)             fails: not on curve        ok
  02 || BE256(p)                    fails: x >= p              ok
  02 || BE256(5)                    fails: x not on curve      ok
  first 32 bytes of 02ba9c...       fails: length              rejected
  ```
  The full keys are those of the ECDSA vector in @sec:crypto-ecdsa-vectors.
]

=== Scalars from byte strings <sec:crypto-scalars>

Several algorithms below convert a byte string $b$ to a scalar. dcrd does
this by taking the first $min(|b|, 32)$ bytes of $b$, left-padding them with
zero bytes to 32 bytes, and interpreting the result as a big-endian integer
$z$. It reports *overflow* if $z >= n$ and otherwise yields $z$. Where an
algorithm below reduces (written `scalar_reduce(b)` in pseudocode), the
value used is $z mod n$; where it rejects on overflow, $z >= n$ is a
failure. The same conversion into a
field element reports overflow when $z >= p$.

== Signature Schemes in Consensus <sec:crypto-sigschemes>

Scripts verify signatures with two families of opcodes, whose full semantics
are given in #chref("script"). This chapter owns the mathematics and the
encodings; @tab:crypto-sigtypes shows how they connect.

#figure(
  caption: [Signature schemes reachable from scripts],
  table(
    columns: (auto, auto, auto, auto, 1fr),
    table.header([Opcode family], [Type], [Scheme], [Public key], [Signature (excluding the hash type byte)]),
    [`OP_CHECKSIG`, `OP_CHECKMULTISIG`], [], [ECDSA / secp256k1], [33 or 65 bytes, strict], [DER, 8 to 72 bytes],
    [`OP_CHECKSIGALT`], [0], [none], [], [Always yields false],
    [`OP_CHECKSIGALT`], [1], [Ed25519], [32 bytes], [64 bytes],
    [`OP_CHECKSIGALT`], [2], [EC-Schnorr-DCRv0 / secp256k1], [33 bytes, compressed], [64 bytes],
    [`OP_CHECKSIGALT`], [other], [none], [], [Always yields true (reserved for future soft forks)],
  ),
) <tab:crypto-sigtypes>

The signature type numbers are the constants `STEcdsaSecp256k1` = 0,
`STEd25519` = 1 and `STSchnorrSecp256k1` = 2 defined in
#src("dcrec/common.go"). ECDSA is never selected through `OP_CHECKSIGALT`:
type 0 makes it yield false. Types 1 and 2 are executed by the consensus
engine, so both alternative schemes are reachable in consensus. In all cases the
message that is signed is the 32-byte signature hash of the spending
transaction defined in #chref("script"), and every signature carries one
trailing hash type byte that is removed before the signature is parsed.
Outside scripts, EC-Schnorr-DCRv0 also authorizes treasury spends
(#chref("treasury")); that 64-byte signature carries no hash type byte.

== ECDSA <sec:crypto-ecdsa>

ECDSA over secp256k1 is the primary signature scheme. Verification is
standard ECDSA @sec1; Decred's specifics lie in the signature encoding and in
deterministic signing.

=== Verification <sec:crypto-ecdsa-verify>

#rule("ECDSA verification", src: "dcrec/secp256k1/ecdsa/signature.go · Signature.Verify")[
  An ECDSA signature $(r, s)$ is valid for a 32-byte message hash $z$ and a
  public key $Q$ if and only if @alg:crypto-ecdsa-verify returns true. In
  consensus, $(r, s)$ comes from @rule:crypto-der-parse, $Q$ from
  @rule:crypto-pubkey-parse, and $z$ is the signature hash.
] <rule:crypto-ecdsa-verify>

#algorithm("ECDSA verification", src: "dcrec/secp256k1/ecdsa/signature.go · Signature.Verify")[
  ```python
  def ecdsa_verify(r: int, s: int, z: bytes, Q: Point) -> bool:
      if r == 0 or s == 0:                    # cannot happen after DER parsing
          return False
      e = scalar_reduce(z)                    # first 32 bytes, big-endian, mod n
      w = pow(s, n - 2, n)                    # s^-1 mod n
      u1 = e * w % n
      u2 = r * w % n
      X = point_add(scalar_mult(u1, G), scalar_mult(u2, Q))
      if X == INFINITY:
          return False
      return X.x % n == r
  ```
] <alg:crypto-ecdsa-verify>

#note[
  dcrd avoids converting $X$ to affine coordinates: with $X$ in Jacobian
  coordinates $(X_J, Y_J, Z_J)$ it accepts if $r Z_J^2 equiv X_J$ or, when
  $r + n < p$, if $(r + n) Z_J^2 equiv X_J$ modulo $p$. Since
  $X.x < p < 2n$, this is exactly the condition $X.x mod n = r$.
]

#pitfall[
  $u_1$ is zero when $e equiv 0$, making $u_1 G = cal(O)$, and
  $u_1 G + u_2 Q$ may be $cal(O)$. Point addition must handle the identity
  and the doubling case; a formula that assumes distinct, non-identity
  operands produces wrong verdicts on such inputs.
]

=== DER signature encoding <sec:crypto-der>

ECDSA signatures in scripts are encoded with the ASN.1 Distinguished
Encoding Rules (DER, ITU-T X.690 @x690) as a sequence of two integers (@tab:crypto-der). All lengths are
single bytes, since no valid signature needs a long-form length.

#fieldtable(
  caption: [DER encoding of an ECDSA signature],
  ("seq", "byte", "1", [`0x30`, the ASN.1 SEQUENCE identifier.]),
  ("len", "byte", "1", [Number of remaining bytes; must equal the signature length minus 2.]),
  ("rtype", "byte", "1", [`0x02`, the ASN.1 INTEGER identifier.]),
  ("rlen", "byte", "1", [Length $ell_r$ of $R$ in bytes.]),
  ("R", "bytes", [$ell_r$], [$r$ as a minimal big-endian two's complement integer.]),
  ("stype", "byte", "1", [`0x02`.]),
  ("slen", "byte", "1", [Length $ell_s$ of $S$ in bytes.]),
  ("S", "bytes", [$ell_s$], [$s$ as a minimal big-endian two's complement integer.]),
) <tab:crypto-der>

"Minimal two's complement" means that the first byte of an integer must not
have its high bit set (that would make it negative), and a leading `0x00`
byte is allowed only when the following byte has its high bit set. The
shortest valid signature is therefore 8 bytes ($ell_r = ell_s = 1$) and the
longest 72 bytes ($ell_r = ell_s = 33$).

#rule("Parsing a DER signature", src: "dcrec/secp256k1/ecdsa/signature.go · ParseDERSignature")[
  Let $b$ be the signature with its hash type byte removed and $L = |b|$.
  $b$ parses as an ECDSA signature if and only if all of the following
  hold, where offsets are zero-based, $ell_r = b_3$,
  $o_s = 4 + ell_r$ (the offset of the S type byte), and
  $ell_s = b_(o_s + 1)$:
  + $8 <= L <= 72$.
  + $b_0 = #raw("0x30")$.
  + $b_1 = L - 2$.
  + $o_s < L$ and $o_s + 1 < L$ (the S type and length bytes are inside $b$).
  + $o_s + 2 + ell_s = L$ (the lengths account for every byte; there is no
    trailing data).
  + $b_2 = #raw("0x02")$.
  + $ell_r eq.not 0$.
  + $b_4$ has its high bit clear ($R$ is not negative).
  + Not ($ell_r > 1$ and $b_4 = #raw("0x00")$ and $b_5$ has its high bit
    clear) ($R$ has no excess leading zero).
  + $b_(o_s) = #raw("0x02")$.
  + $ell_s eq.not 0$.
  + $b_(o_s+2)$ has its high bit clear ($S$ is not negative).
  + Not ($ell_s > 1$ and $b_(o_s+2) = #raw("0x00")$ and $b_(o_s+3)$ has
    its high bit clear) ($S$ has no excess leading zero).
  + With all leading zero bytes stripped from the $R$ field, at most 32
    bytes remain, and their big-endian value $r$ satisfies $1 <= r <= n - 1$.
  + With all leading zero bytes stripped from the $S$ field, at most 32
    bytes remain, and their big-endian value $s$ satisfies $1 <= s <= n - 1$.
  The result is the pair $(r, s)$. The parser does *not* require
  $s <= (n-1)\/2$; high-$S$ signatures parse and verify.
] <rule:crypto-der-parse>

The script engine additionally applies a *strict encoding* check to every
ECDSA signature before parsing it (#chref("script")). It repeats items 1 to
13 of @rule:crypto-der-parse and adds the low-$S$ requirement, but it does not
check the range of $r$: a signature that is strictly encoded but has $r = 0$
or $r >= n$, or $s = 0$, passes the strict check and then fails to parse.
The two outcomes differ in script: a strict-encoding failure aborts the
script with an error, whereas a parse failure makes the signature check
return false.

#rule("Strict ECDSA signature encoding", src: "txscript/consensus.go · CheckSignatureEncoding")[
  A signature (without hash type) is *strictly encoded* if and only if it
  satisfies items 1 to 13 of @rule:crypto-der-parse and, with all leading
  zero bytes stripped from the $S$ field, at most 32 bytes remain and their
  value $s$ satisfies $s < n$ and $s <= (n - 1)\/2$. In particular a strictly
  encoded signature has $s <= #hex("7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0")$.
] <rule:crypto-der-strict>

#rationale[
  If $(r, s)$ is a valid signature then so is $(r, n - s)$. Without the
  low-$S$ rule anyone could change the $S$ value of a signature in a
  transaction, and thereby the transaction's full hash, without invalidating
  it. Requiring $s <= (n-1)\/2$ leaves one valid choice.
]

=== Signing <sec:crypto-ecdsa-sign>

Signing is not part of consensus, but dcrd's signatures are deterministic
and implementations that wish to reproduce them, or the test vectors, must
follow @alg:crypto-ecdsa-sign. The nonce is generated per RFC 6979 @rfc6979
with HMAC-SHA256 (@alg:crypto-rfc6979), and $s$ is normalized to the lower
half of the range as required by @rule:crypto-der-strict.

#algorithm("Deterministic ECDSA signing", src: "dcrec/secp256k1/ecdsa/signature.go · signRFC6979, sign")[
  ```python
  def ecdsa_sign(d: int, z: bytes) -> tuple[int, int, int]:
      for iteration in range(0, 2**32):
          k = nonce_rfc6979(be256(d), z, b"", iteration)
          X = scalar_mult(k, G)
          r = X.x % n
          if r == 0:
              continue
          e = scalar_reduce(z)
          s = pow(k, n - 2, n) * (e + d * r) % n
          if s == 0:
              continue
          recid = (2 if X.x >= n else 0) | (X.y & 1)   # public key recovery code
          if s > (n - 1) // 2:
              s = n - s
              recid ^= 1                              # -k gives the opposite y parity
          return r, s, recid
  ```
] <alg:crypto-ecdsa-sign>

A signature is serialized in DER (@tab:crypto-der) by encoding $r$ and $s$
as 32-byte big-endian values, prefixing a zero byte, and stripping leading
zero bytes while more than one byte remains and the next byte has its high
bit clear.

#algorithm("RFC 6979 nonce generation as implemented", src: "dcrec/secp256k1/nonce.go · NonceRFC6979")[
  ```python
  def nonce_rfc6979(key: bytes, z: bytes, extra: bytes, iteration: uint32) -> int:
      key = left_pad(key[0:32], 32)       # truncate to 32 bytes or left-pad with zeros
      z = left_pad(z[0:32], 32)
      data = key + z
      if len(extra) == 32:                # extra data is used only if exactly 32 bytes
          data = data + extra
      V = b"\x01" * 32
      K = b"\x00" * 32
      K = hmac_sha256(K, V + b"\x00" + data)
      V = hmac_sha256(K, V)
      K = hmac_sha256(K, V + b"\x01" + data)
      V = hmac_sha256(K, V)
      generated = 0
      while True:
          V = hmac_sha256(K, V)
          k = int_be(V)
          if 1 <= k <= n - 1:
              generated += 1
              if generated > iteration:
                  return k
          K = hmac_sha256(K, V + b"\x00")
          V = hmac_sha256(K, V)
  ```
] <alg:crypto-rfc6979>

The function also accepts an optional 16-byte "version" string that is appended after the
extra data (with 32 zero bytes standing in for absent extra data); no
signature scheme in this chapter uses it.

#pitfall[
  RFC 6979 feeds $"bits2octets"(z) = "int"_"BE" (z) mod n$ into the HMAC.
  dcrd feeds $z$ itself, unreduced. The two differ only when
  $"int"_"BE" (z) >= n$, which happens with probability about $2^(-128)$ for
  a hash output, but an implementation that reduces $z$ produces different
  nonces, and therefore different signatures, for such messages.
]

=== Compact recoverable signatures and signed messages <sec:crypto-compact>

A *compact signature* is a 65-byte encoding of an ECDSA signature from which
the signer's public key can be recovered. It is used for signed messages
(the `signmessage` interface of wallets and the `verifymessage` interface
of wallets and dcrd; #chref("addresses") gives the message format) and
is not part of consensus.

#fieldtable(
  caption: [Compact signature],
  ("code", "byte", "1", [$27 + "recid" + 4c$, where $"recid"$ is the recovery code of @alg:crypto-ecdsa-sign and $c = 1$ if the signer's address uses the compressed public key, else 0. Valid values are 27 to 34.]),
  ("r", "bytes", "32", [$"BE"_256 (r)$.]),
  ("s", "bytes", "32", [$"BE"_256 (s)$, with $s <= (n-1)\/2$ as produced by signing.]),
) <tab:crypto-compact>

Bit 0 of the recovery code is the parity of $X.y$ for the nonce point $X$
(after the low-$S$ adjustment), and bit 1 is set when $X.x >= n$, so that
$r = X.x - n$. Recovery from a compact signature and a 32-byte hash $z$
proceeds as follows, failing at any step that cannot be completed:

+ Require the length to be 65 and the first byte $c$ to satisfy
  $27 <= c <= 34$. Let $c' = c - 27$; the original key was compressed if
  bit 2 of $c'$ is set, and $"recid" = c' mod 4$.
+ Parse $r$ and $s$ from the next two 32-byte fields; require
  $1 <= r <= n - 1$ and $1 <= s <= n - 1$ (rejecting on overflow).
+ Let $x = r$. If bit 1 of $"recid"$ is set, require $r + n < p$ and let
  $x = r + n$.
+ Find $y$ with $y^2 equiv x^3 + 7 med (mod p)$ whose parity equals bit 0
  of $"recid"$; fail if none exists. Let $X = (x, y)$.
+ Let $e$ be $z$ reduced as in @sec:crypto-scalars, $w = r^(-1) mod n$,
  $u_1 = -e w mod n$, $u_2 = s w mod n$, and $Q = u_1 G + u_2 X$. Fail if
  $Q = cal(O)$.
+ The recovered key is $Q$, to be serialized compressed if
  $"compressed"$ is set and uncompressed otherwise.

A signed message $m$ (a UTF-8 string) is verified by computing the message
hash

$ z = "BLAKE-256"("varstr"(#raw("\"Decred Signed Message:\\n\"")) || "varstr"(m)), $

where $"varstr"$ is the variable-length string encoding of
#chref("encoding") (a variable-length integer byte count followed by the
bytes), recovering $Q$ from the compact signature and $z$, and comparing the
version 0 pay-to-public-key-hash address of HASH160 of $Q$'s serialization
with the claimed address (#chref("addresses")). Unlike Bitcoin, the message
hash is a single BLAKE-256, not double SHA-256.

=== Test vectors <sec:crypto-ecdsa-vectors>

#vector[ECDSA key, nonce and signature][
  ```
  d   cbe35df915b1e955c4956bba366d95256a7ee187c9d5267a8f0c69afae669c0e
        (= BLAKE-256("Decred crypto chapter test key"))
  z   5a029fb117f154fc26caa93ca613772e2795e5776e2fd4208abbf6386be52dc7
        (= BLAKE-256("Decred crypto chapter test message"))
  Q compressed  02ba9cf60e2ea62eb020697b80a34eaaf17cdf7ee6114b3bdbdaac3494066a10fd
  Q uncompr.    04ba9cf60e2ea62eb020697b80a34eaaf17cdf7ee6114b3bdbdaac3494066a10fd
                  5b94e113908bde6f4dc99d83494af73fdf7db95194617ff0418056a978481674
  k (iter. 0)   83d68d3a073a926fdd7f485df64f27e829bc7c07334b795f5d36b161f5139ab1
  X.x           c766d1c56552499bca21cc0f329b3ca2ecd96b501a60e5797576f33331c6ea4e
  X.y parity    even
  s (raw)       a8184510d564a0d715fdff73d704cb78356d3631ed1579eba2ddef42acd1722a
  r             c766d1c56552499bca21cc0f329b3ca2ecd96b501a60e5797576f33331c6ea4e
  s             57e7baef2a9b5f28ea02008c28fb34868541a6b4c23326501cf46f4a2364cf17
  DER  3045022100c766d1c56552499bca21cc0f329b3ca2ecd96b501a60e5797576f33331c6ea4e
       022057e7baef2a9b5f28ea02008c28fb34868541a6b4c23326501cf46f4a2364cf17
  compact (compressed key, recid 1: code 27 + 1 + 4 = 0x20)
       20c766d1c56552499bca21cc0f329b3ca2ecd96b501a60e5797576f33331c6ea4e
         57e7baef2a9b5f28ea02008c28fb34868541a6b4c23326501cf46f4a2364cf17
  ```
  Here the raw $s$ exceeded $(n-1)\/2$ and was negated, which flipped the
  recovery code's parity bit from 0 to 1.
]

#vector[Signed message][
  ```
  message "hello"; key d as above
  z = BLAKE-256(17 "Decred Signed Message:\n" 05 "hello")
    = 776fea952d41c5269b91e9710afcd91103ad41a06e814f8ecba72f49044fdfe6
  compact signature
    208900fad91d879b2643d8b2046f033ca389247e3a9fe499d6d7908cb72d14712f
      07e9ce1734285c6f9a79ef3617ce8453f38d9a104c93cd14b4d7c7070dc236af
  ```
]

#vector[DER parsing and strict encoding][
  The base signature is the DER signature above, with
  `R = 00c766...ea4e` and `S = 57e7...cf17`.
  #table(
    columns: (1fr, auto, auto),
    table.header([Modification], [Parse (@rule:crypto-der-parse)], [Strict (@rule:crypto-der-strict)]),
    [None], [ok], [ok],
    [$S$ replaced by $n - s$ (`022100a818...722a`, 72 bytes)], [ok], [high S],
    [Extra `00` before $R$ (`02220000c766...`)], [excess padding (9)], [excess padding],
    [First byte of $R$ field `80` instead of `00`], [negative R (8)], [negative R],
    [$R$ = `00` (`020100`)], [R is 0 (14)], [ok],
    [$R$ = `00` $||$ $"BE"_256 (n)$], [R >= n (14)], [ok],
    [$S$ = `00` (`020100`)], [S is 0 (15)], [ok],
    [$S$ length 0 (`0200`)], [zero S length (11)], [zero S length],
    [First byte `31`], [sequence id (2)], [sequence id],
    [Length byte `46` instead of `45`], [bad length (3)], [bad length],
    [One trailing byte appended], [bad length (3)], [bad length],
    [R type byte `03`], [R integer id (6)], [R integer id],
    [`3006020101020101` ($r = s = 1$)], [ok], [ok],
    [`30060201010201` (7 bytes)], [too short (1)], [too short],
  )
  Numbers in parentheses are the items of @rule:crypto-der-parse that fail.
]

== EC-Schnorr-DCRv0 <sec:crypto-schnorr>

EC-Schnorr-DCRv0 is a Schnorr signature scheme @schnorr over secp256k1
defined by Decred. A signature is the pair $(r, s)$ where $r$ is the $x$ coordinate of
the nonce point $R$, whose $y$ coordinate is required to be even, and
$s = k - e d mod n$ with challenge $e = "BLAKE-256"("BE"_256 (r) || m)$.
Verification checks $s G + e Q = R$. It is not compatible with BIP 340
@bip340 Schnorr signatures, which use a different challenge hash, the
opposite sign convention and $x$-only public keys. The scheme is described
in the README of the `schnorr` package, which this section follows; where the
README and the code differ in detail, the code is authoritative.

=== Encoding <sec:crypto-schnorr-encoding>

#fieldtable(
  caption: [EC-Schnorr-DCRv0 signature],
  ("r", "bytes", "32", [$"BE"_256 (r)$, the $x$ coordinate of $R$, with $r < p$.]),
  ("s", "bytes", "32", [$"BE"_256 (s)$, with $s < n$.]),
) <tab:crypto-schnorr-sig>

#rule("Parsing an EC-Schnorr-DCRv0 signature", src: "dcrec/secp256k1/schnorr/signature.go · ParseSignature")[
  A byte string $b$ parses as an EC-Schnorr-DCRv0 signature if and only if
  $|b| = 64$, $r = "int"_"BE" (b[0:32]) < p$ and
  $s = "int"_"BE" (b[32:64]) < n$. No other condition is checked: $r = 0$,
  $s = 0$, and an $r$ that is not the $x$ coordinate of any curve point all
  parse (and then fail or succeed in verification on their merits).
] <rule:crypto-schnorr-parse>

#rule("Parsing an EC-Schnorr-DCRv0 public key", src: "dcrec/secp256k1/schnorr/pubkey.go · ParsePubKey")[
  A byte string parses as an EC-Schnorr-DCRv0 public key if and only if it
  is exactly 33 bytes long, its first byte is `02` or `03`, and it parses as
  a compressed key under @rule:crypto-pubkey-parse. Uncompressed and hybrid
  keys are rejected.
] <rule:crypto-schnorr-pubkey>

=== Verification

#rule("EC-Schnorr-DCRv0 verification", src: "dcrec/secp256k1/schnorr/signature.go · schnorrVerify, Signature.Verify")[
  A parsed signature $(r, s)$ is valid for a message $m$ and a parsed public
  key $Q$ if and only if @alg:crypto-schnorr-verify returns true.
] <rule:crypto-schnorr-verify>

#algorithm("EC-Schnorr-DCRv0 verification", src: "dcrec/secp256k1/schnorr/signature.go · schnorrVerify")[
  ```python
  def schnorr_verify(r: int, s: int, m: bytes, Q: Point) -> bool:
      if len(m) != 32:
          return False
      if not on_curve(Q):                 # always true for a parsed key
          return False
      e = int_be(blake256(be256(r) + m))  # r is always encoded as 32 bytes
      if e >= n:                          # no reduction: overflow is a failure
          return False
      R = point_add(scalar_mult(s, G), scalar_mult(e, Q))
      if R == INFINITY:
          return False
      if R.y % 2 == 1:
          return False
      return R.x == r
  ```
] <alg:crypto-schnorr-verify>

#pitfall[
  The challenge $e$ is not reduced modulo $n$: a hash value $e >= n$ makes
  the signature invalid. The comparison $R.x = r$ is over the field, not
  modulo $n$. Because $s = 0$ and $e = 0$ are both possible inputs, point
  arithmetic must handle $cal(O)$ correctly.
]

=== Signing

Signing is deterministic. The nonce comes from @alg:crypto-rfc6979 with
32 bytes of extra data that separate it from ECDSA nonces for the same key
and message:

#align(center)[
  `extra` $=$ BLAKE-256(`"EC-Schnorr-DCRv0"`) $=$
  #hex("0b75f97b60e8a5762876c004829ee9b926fa6f0d2eeaec3a4fd1446a768331cb")
]

#algorithm("EC-Schnorr-DCRv0 signing", src: "dcrec/secp256k1/schnorr/signature.go · Sign, schnorrSign")[
  ```python
  def schnorr_sign(d: int, m: bytes) -> tuple[int, int]:
      if len(m) != 32 or d == 0:
          fail()
      for iteration in range(0, 2**32):
          k = nonce_rfc6979(be256(d), m, EXTRA_DCRV0, iteration)
          R = scalar_mult(k, G)
          if R.y % 2 == 1:
              k = n - k                       # -k gives a nonce point with even y
          r = R.x
          e = int_be(blake256(be256(r) + m))
          if e >= n:
              continue
          s = (k - e * d) % n
          return r, s
  ```
] <alg:crypto-schnorr-sign>

#vector[EC-Schnorr-DCRv0][
  ```
  d, z, Q as in the ECDSA vector (Q compressed = 02ba9c...10fd)
  k (iter. 0)  18de4f626d03fb5ce2b99e35c1a647001de4a09b17b10575f7f14069885fa651
  R.y parity   even (k not negated)
  r            fc941c3662ebb36c6ac57a1399e5d1c914ebba55e5632e450f5069d9c6023954
  e            f574323b5a096cf37a2fc5c63dc0ab696204ae903083a9e89835a6918dc67ba1
  s            908e6a2805b90ade93188d193394e10d3c1e178522a316237618b3d4d40fa229
  signature    fc941c3662ebb36c6ac57a1399e5d1c914ebba55e5632e450f5069d9c6023954
               908e6a2805b90ade93188d193394e10d3c1e178522a316237618b3d4d40fa229
  ```
  Parsing edge cases: 64 zero bytes parse ($r = s = 0$) but cannot verify;
  replacing $s$ by $"BE"_256 (n)$ fails to parse ($s >= n$); replacing $r$ by
  $"BE"_256 (p)$ fails to parse ($r >= p$); the 65-byte uncompressed form of
  $Q$ is rejected as a public key.
]

== Ed25519 <sec:crypto-ed25519>

Ed25519 @ed25519 is EdDSA over the twisted Edwards curve edwards25519, as
standardized in RFC 8032 @rfc8032. dcrd's implementation, the `dcrec/edwards`
package (module `github.com/decred/dcrd/dcrec/edwards/v2` at version v2.0.4,
which dcrd's `go.mod` takes as a published module rather than from its own
source tree; the two copies differ only in their tests), wraps the Go library
`github.com/agl/ed25519` (pinned at version
`v0.0.0-20170116200512-5312a6153412`), adding its own decoding and range
checks. Signatures produced by dcrd from a 32-byte secret are exactly
RFC 8032 Ed25519 signatures, and honestly generated RFC 8032 signatures on a
32-byte message verify. The differences lie in the treatment of unusual
encodings and of $S = 0$, and are specified below.

#figure(
  caption: [edwards25519 parameters],
  table(
    columns: (auto, 1fr),
    table.header([Parameter], [Value]),
    [Field prime $q$], [$2^255 - 19$],
    [Curve], [$-x^2 + y^2 = 1 + d x^2 y^2$],
    [$d$], [$-121665 \/ 121666 mod q$ = #hex("52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3")],
    [Group order $ell$], [$2^252 + 27742317777372353535851937790883648493$ = #hex("1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed")],
    [Cofactor], [8],
    [Base point $B$], [$B.y = 4\/5 mod q$ = #hex("6666666666666666666666666666666666666666666666666666666666666658"), $B.x$ even = #hex("216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a")\; encoded #hex("5866666666666666666666666666666666666666666666666666666666666666")],
  ),
) <tab:crypto-ed25519>

=== Point encoding and decoding <sec:crypto-ed-points>

A point $(x, y)$ is encoded as 32 bytes: $"LE"_256 (y)$ with the most
significant bit of the last byte set to the least significant bit of $x$
(the "sign" of $x$). The encoding produced by the implementation always has
$y < q$ (it is *canonical*).

Decoding, as performed by the library and relied upon by every rule below,
is more permissive than RFC 8032:

#algorithm("Ed25519 point decoding as implemented", src: ("dcrec/edwards/primitives.go · encodedBytesToBigIntPoint", "github.com/agl/ed25519/edwards25519 · ExtendedGroupElement.FromBytes"))[
  ```python
  def ed_decode(b: bytes) -> Point:      # len(b) == 32
      sign = b[31] >> 7
      y = (int_le(b) & (2**255 - 1)) % q     # y >= q is NOT rejected; it is reduced
      u = (y * y - 1) % q
      v = (d * y * y + 1) % q
      x = sqrt_mod_q(u * inverse(v, q))       # fail if u/v is not a square mod q
      if (x & 1) != sign:
          x = (q - x) % q                     # x = 0 stays 0 even if sign == 1
      return (x, y)
  ```
] <alg:crypto-ed-decode>

A square root of $a$ modulo $q$, when it exists, is
$a^((q+3)\/8)$ or that value times $sqrt(-1) = 2^((q-1)\/4) mod q$.

=== Parsing and verification

#rule("Parsing an Ed25519 public key", src: "dcrec/edwards/pubkey.go · ParsePubKey")[
  A byte string $b$ parses as an Ed25519 public key if and only if
  $|b| = 32$, @alg:crypto-ed-decode succeeds on $b$ giving $A = (x, y)$, and
  it is not the case that $x = 0$ and the sign bit (bit 7 of $b[31]$) is 1. (dcrd
  represents that case internally with $x = q$ and rejects it because
  $x >= q$.) A non-canonical $y$ encoding (bits 0 to 254 encoding a value
  $>= q$) is accepted and reduced.
] <rule:crypto-ed-pubkey>

#rule("Parsing an Ed25519 signature", src: "dcrec/edwards/signature.go · parseSig, ParseSignature")[
  A byte string $b$ parses as an Ed25519 signature if and only if
  $|b| = 64$, @alg:crypto-ed-decode succeeds on $R_"enc" = b[0:32]$, and
  $S = "int"_"LE" (b[32:64])$ satisfies $0 < S < ell$. The signature
  retains the 32 bytes $R_"enc"$ exactly as given.
] <rule:crypto-ed-sigparse>

#rule("Ed25519 verification", src: ("dcrec/edwards/ecdsa.go · Verify", "github.com/agl/ed25519 · Verify"))[
  A parsed signature $(R_"enc", S)$ is valid for a message $m$ and a parsed
  public key $A$ if and only if
  $ "encode"(S B - k A) = R_"enc", quad k = "int"_"LE" ("SHA-512"(R_"enc" || A_"enc" || m)) mod ell, $
  where $A_"enc"$ is the *canonical* encoding of $A$ (@sec:crypto-ed-points),
  not necessarily the bytes from which $A$ was parsed, $"encode"$ is the
  canonical encoding, and the comparison is of all 32 bytes. In consensus
  $m$ is the 32-byte signature hash.
] <rule:crypto-ed-verify>

The equation is the cofactorless one: it is not multiplied by 8. Since the
left side is canonical, a non-canonical $R_"enc"$ never verifies. No
condition is placed on the order of $A$ or $R$: small-order and mixed-order
points are accepted if the equation holds.

#figure(
  caption: [Ed25519 as implemented compared with RFC 8032],
  table(
    columns: (auto, 1fr, 1fr),
    table.header([Aspect], [RFC 8032], [dcrd]),
    [Public key with $y >= q$], [Decoding fails], [$y$ reduced modulo $q$; accepted if the reduced value decodes, and the canonical re-encoding is hashed],
    [Public key with $x = 0$, sign bit 1], [Decoding fails], [Rejected],
    [$R$ with $y >= q$], [Decoding fails], [Parses if the reduced value decodes; never verifies],
    [$R$ with $x = 0$, sign bit 1], [Decoding fails], [Parses, never verifies],
    [$S = 0$], [Allowed], [Rejected],
    [$S >= ell$], [Rejected], [Rejected],
    [Verification equation], [$[8] S B = [8] R + [8] k A$ (the unmultiplied form is permitted)], [$S B - k A$ re-encoded and compared with $R_"enc"$ (cofactorless)],
    [Message], [Arbitrary], [The 32-byte signature hash (pure Ed25519, no context or prehash)],
  ),
) <tab:crypto-ed-diff>

Signing from a 32-byte secret $s_"seed"$ follows RFC 8032 exactly:
$h = "SHA-512"(s_"seed")$, the scalar $a$ is $"int"_"LE" (h[0:32])$ with
bits 0, 1, 2 and 255 cleared and bit 254 set, $A = a B$,
$r = "int"_"LE" ("SHA-512"(h[32:64] || m)) mod ell$, $R = r B$, and
$S = (r + k a) mod ell$ with $k$ as in @rule:crypto-ed-verify. (The package
also has a mode for keys given as a bare scalar, which signs with an
RFC 6979 nonce; dcrd's transaction signing code in `txscript/sign` does not
use it. Its signatures are verified by the same rules.)

#vector[Ed25519][
  ```
  seed  232b277c698f23760d3bb922ffd92c47f80db87382f567de705c1c96108a6818
          (= BLAKE-256("Decred crypto chapter ed25519 seed"))
  A     4fb3bab83ba936b65d6e5aeefe6433aae325b78121f18401aaadda5090a7465e
  m     5a029fb117f154fc26caa93ca613772e2795e5776e2fd4208abbf6386be52dc7
  sig   86e6c6ce81e30f209948be1bba9e1313ca78355b428206af9341dea5cc57a8c9
        ee1c6b29a2c9a472591759f35ea53e1700c6d773722bcb79a0493d273c541d0b
  ```
  Parsing edge cases: the public key `01` followed by 31 zero bytes (the
  identity) parses; the same with the last byte `80` is rejected; the
  non-canonical encoding `eeff...ff7f` of $y = q + 1$ parses and re-encodes
  as `01` followed by 31 zero bytes; `02` followed by 31 zero bytes ($y = 2$)
  is not on the curve. As $R_"enc"$, the identity with the sign bit set and
  the non-canonical encoding of $y = q + 1$ both parse (and cannot verify);
  a signature with $S = 0$ or $S = ell$ is rejected.
]

== Merkle Trees <sec:crypto-merkle>

A Merkle tree @merkle commits to an ordered list of 32-byte *leaves* with a
single 32-byte *root*. Each interior node is the BLAKE-256 hash of the
concatenation of its two children. When a level has an odd number of nodes,
its last node is paired with itself. The block header commits to the
transactions of a block with Merkle roots whose leaves are transaction
hashes; which hashes are used, and how the regular and stake tree roots are
combined under #dcp(5), is specified in #chref("encoding") and
#chref("blocks"). This section defines the generic tree.

#rule("Merkle root", src: "blockchain/standalone/merkle.go · CalcMerkleRoot, CalcMerkleRootInPlace")[
  The Merkle root of a list of leaves #MUST be computed by
  @alg:crypto-merkle-root. In particular, the root of the empty list is 32
  zero bytes, the root of a single leaf is that leaf itself (it is not
  hashed), and at each level with an odd number of nodes greater than one
  the last node is duplicated before pairing.
] <rule:crypto-merkle-root>

#algorithm("Merkle root", src: "blockchain/standalone/merkle.go · CalcMerkleRootInPlace")[
  ```python
  def merkle_root(leaves: list[bytes]) -> bytes:
      if len(leaves) == 0:
          return bytes(32)
      level = list(leaves)
      while len(level) > 1:
          if len(level) % 2 == 1:
              level.append(level[-1])
          level = [blake256(level[2 * i] + level[2 * i + 1])
                   for i in range(len(level) // 2)]
      return level[0]
  ```
] <alg:crypto-merkle-root>

#pitfall[
  Because the last node of an odd level is duplicated, the lists
  $[L_0, L_1, L_2]$ and $[L_0, L_1, L_2, L_2]$ have the same root, and in
  general appending copies of trailing leaves can preserve the root. A
  Merkle root therefore does not by itself determine the number of leaves.
  The rule that makes this harmless for blocks (no duplicate transactions)
  is part of #chref("blocks").
]

#vector[Merkle roots][
  Leaves $L_i = "BLAKE-256"(i)$ for the single byte $i$:
  ```
  L0  0ce8d4ef4dd7cd8d62dfded9d4edb0a774ae6a41929a74da23109e8f11139c87
  L1  4a6c419a1e25c85327115c4ace586decddfe2990ed8f3d4d801871158338501d
  L2  49af37ab5270015fe25276ea5a3bb159d852943df23919522a202205fb7d175c
  L3  b706d561742ad3671703c247eb927ee8a386369c79644131cdeb2c5c26bf6c5d
  L4  4c6eb9e38415034f4c93d3304d10bef38bf0ad420eefd0f72f940f11c5857786

  root([])       0000000000000000000000000000000000000000000000000000000000000000
  root([L0])     0ce8d4ef4dd7cd8d62dfded9d4edb0a774ae6a41929a74da23109e8f11139c87
  root([L0..L1]) ad204769bc6f9a916299fe1af8d54828b7403e2dbe65c8888e16e9fa1deae0c5
  root([L0..L2]) 0135cd60725091a8795118c7ed50b8bf8a272707938a9fa7b24f0399bbe4a048
  root([L0..L3]) f71e10d28e0d14e884e043114c2e30cfbed5ef375faf4fd9790b122a0e574e0b
  root([L0..L4]) 1a3f528d95b03c38767aaf2daab6ee3a97c3040adfffbb67ecb357d418b34517
  ```
  `root([L0..L2])` $= H(H(L_0 || L_1) || H(L_2 || L_2))$, and it equals the
  root of `[L0, L1, L2, L2]`.
]

=== Inclusion proofs <sec:crypto-inclusion>

An *inclusion proof* for the leaf at zero-based index $i$ is the list of
sibling hashes on the path from that leaf to the root, ordered from the leaf
level upward. Together with the leaf and its index it suffices to recompute
the root. dcrd generates such proofs for the header commitments of #dcp(5),
which it serves to light clients (#chref("filters")); they are not used in
block validation. The proof for a tree of $N >= 1$ leaves has
$ceil(log_2 N)$ entries, and none for a single leaf.

#algorithm("Inclusion proof generation", src: "blockchain/standalone/inclusionproof.go · GenerateInclusionProof")[
  ```python
  def inclusion_proof(leaves: list[bytes], index: uint32) -> list[bytes] | None:
      if len(leaves) == 0 or index >= len(leaves):
          return None
      level = list(leaves)
      proof = []
      while len(level) > 1:
          if len(level) % 2 == 1:
              level.append(level[-1])
          sibling = index ^ 1                 # left if index is odd, else right
          proof.append(level[sibling])
          level = [blake256(level[2 * j] + level[2 * j + 1])
                   for j in range(len(level) // 2)]
          index = index >> 1
      return proof
  ```
] <alg:crypto-inclusion-gen>

#algorithm("Inclusion proof verification", src: "blockchain/standalone/inclusionproof.go · VerifyInclusionProof")[
  ```python
  def verify_inclusion(root: bytes, leaf: bytes, index: uint32,
                       proof: list[bytes]) -> bool:
      if len(proof) > 32:
          return False
      if index > 2**len(proof) - 1:           # largest index this proof length covers
          return False
      h = leaf
      for sibling in proof:
          if index & 1 == 1:
              h = blake256(sibling + h)
          else:
              h = blake256(h + sibling)
          index = index >> 1
      return h == root
  ```
] <alg:crypto-inclusion-verify>

Verification does not learn the number of leaves. A proof for the last leaf
of an odd level contains a copy of that leaf as its own sibling.

#vector[Inclusion proofs for the five leaves above][
  ```
  index 2:
    [0] b706d561742ad3671703c247eb927ee8a386369c79644131cdeb2c5c26bf6c5d
    [1] ad204769bc6f9a916299fe1af8d54828b7403e2dbe65c8888e16e9fa1deae0c5
    [2] 92ad3df5fcd26cbbd6ea00363893dd6f201516f3760bdfa9f9359945369beacd
  index 4:
    [0] 4c6eb9e38415034f4c93d3304d10bef38bf0ad420eefd0f72f940f11c5857786
    [1] 72b0e5fb43e19eb8b640aec409532c2cd8a583cfb5ada680f8664a6b53c36558
    [2] f71e10d28e0d14e884e043114c2e30cfbed5ef375faf4fd9790b122a0e574e0b
  ```
  For index 2 the entries are $L_3$, $H(L_0 || L_1)$ and the hash of the
  duplicated right subtree $H(H(L_4 || L_4) || H(L_4 || L_4))$; for index 4
  they are $L_4$ itself (its own duplicate), $H(L_4 || L_4)$ (the duplicate
  of its parent), and the root of $L_0, ..., L_3$. Both verify against
  `root([L0..L4])`. The index 4 proof presented with
  index 8 is rejected, since 8 exceeds $2^3 - 1$.
]

== Other Primitives <sec:crypto-other>

No other cryptographic primitive is evaluated in block validation outside
the chapters that own it:

- The pseudorandom number generator that selects winning tickets is built on
  BLAKE-256 and is specified in #chref("staking").
- SipHash and Golomb-coded sets, used by the version 2 compact filters
  committed to by header commitments, are specified in #chref("filters").
- Base58Check (whose checksum is the first four bytes of HASH256 of the
  payload) and hierarchical deterministic keys are specified in
  #chref("addresses")\; neither is consensus-critical.
- The signature hash that each signature commits to is specified in
  #chref("script").
