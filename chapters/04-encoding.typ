#import "../template.typ": *

= Data Encoding and Structures <ch:encoding>

Every object that the consensus rules talk about, a transaction, a block
header, a block, is exchanged and hashed as a byte string. This chapter
specifies those byte strings exactly: the primitive encodings they are built
from, the layout of transactions in each of their three serialization types,
the 180-byte block header, the block, and the identifiers (hashes) derived
from each of them. It also specifies what the two Merkle-root fields of the
header contain, before and after the change made by #dcp(5).

The generic Merkle tree construction and the hash functions themselves belong
to #chref("crypto"). Scripts carried inside transactions are opaque byte
strings here and are interpreted in #chref("script"). The rules that decide
whether a decoded transaction or block is _valid_ are in #chref("transactions")
and #chref("blocks"). The framing of these structures inside peer-to-peer
messages is in #chref("p2p").

== Decoding Principles <sec:encoding-principles>

All structures are concatenations of fields with no padding, no alignment and
no field tags. Integers are little-endian (#xref("conv:bytes")) unless stated
otherwise. A structure carries no overall length prefix: its extent is
determined by decoding it field by field from its first byte.

dcrd computes every identifier and every size from the _decoded_ structure,
by serializing it again, never from the bytes it received. The encoding is
designed so that this makes no difference: the decoder accepts only canonical
encodings, so every byte string that decodes successfully re-encodes to
exactly the same byte string, and two different accepted byte strings never
decode to the same structure. An implementation may therefore hash either the
received bytes or a re-serialization, _provided_ it rejects everything that
dcrd's decoder rejects. The rules in this chapter that use the word
"undecodable" list every such rejection.

#rule("Decodability", src: ("wire/msgblock.go · MsgBlock.BtcDecode", "wire/msgtx.go · MsgTx.BtcDecode"))[
  A block #MUST be decodable according to @sec:encoding-block, and every
  transaction it contains #MUST be decodable according to
  @sec:encoding-tx-decode. A byte string that is undecodable under any rule
  of this chapter is not a block (or transaction) at all, and no block can be
  built on it. In particular, a structure that ends before all of its fields
  have been read is undecodable.
] <rule:encoding-decodable>

The serialization used on the wire is the same as the one dcrd uses for
storage and for hashing. dcrd's encoder and decoder accept a protocol version
argument; the only effect of that argument on any structure in this chapter is
the transaction-count bound of @rule:encoding-block-counts, which never decides
the validity of a block (see the note after that rule).

== Primitive Encodings <sec:encoding-primitives>

=== Fixed-Width Integers <sec:encoding-ints>

Fixed-width integers occupy exactly their width in bytes and are serialized
least significant byte first. Signed integers are serialized as the two's
complement bit pattern of the same width, so an `int64` field is written as
`le64(uint64(x))` and read back as `int64(read_le64())`. The decoder places no
range restriction on any integer field: every bit pattern decodes, and
range checks (for example on amounts) are validation rules stated elsewhere.

#figure(
  caption: [Fixed-width field types],
  table(
    columns: (auto, auto, 1fr),
    table.header([Type], [Bytes], [Encoding]),
    [`uint8`], [1], [The byte itself.],
    [`uint16`], [2], [`le16(x)`],
    [`uint32`], [4], [`le32(x)`],
    [`int32`], [4], [`le32(uint32(x))`],
    [`uint64`], [8], [`le64(x)`],
    [`int64`], [8], [`le64(uint64(x))`],
    [`[n]byte`], [$n$], [The $n$ bytes in order, unaltered. Used for hashes ($n = 32$), the header's final state ($n = 6$) and extra data ($n = 32$).],
  ),
) <tab:encoding-ints>

=== Variable-Length Integers <sec:encoding-varint>

Counts and lengths are encoded as *variable-length integers* (_varints_), the
same scheme as Bitcoin's "CompactSize". The first byte, the
*discriminant*, either is the value itself or announces a 2-, 4- or 8-byte
little-endian value that follows. The scheme can represent every `uint64`.

#figure(
  caption: [Variable-length integer encoding],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Value $v$], [Bytes], [Discriminant], [Encoding]),
    [$0 <= v <= 252$], [1], [$v$], [`u8(v)`],
    [$253 <= v <= 2^16 - 1$], [3], [`0xfd`], [`0xfd || le16(v)`],
    [$2^16 <= v <= 2^32 - 1$], [5], [`0xfe`], [`0xfe || le32(v)`],
    [$2^32 <= v <= 2^64 - 1$], [9], [`0xff`], [`0xff || le64(v)`],
  ),
) <tab:encoding-varint>

The same value could be written in more than one of these forms, for example
$5$ as `05` or as `fd0500`. Only the shortest form is accepted.

#rule("Canonical variable-length integers", src: "wire/common.go · ReadVarInt")[
  A varint is undecodable if its value could have been encoded in fewer bytes.
  Precisely, after reading the discriminant $d$ and the value $v$ that
  follows it:
  - if $d = "0xfd"$ and $v < "0xfd"$ (that is, $v <= 252$), reject;
  - if $d = "0xfe"$ and $v < "0x10000"$, reject;
  - if $d = "0xff"$ and $v < "0x100000000"$, reject.
  A discriminant below `0xfd` is always canonical. A varint whose following
  2, 4 or 8 bytes are not all present is undecodable (@rule:encoding-decodable).
] <rule:encoding-varint-canonical>

#algorithm("Variable-length integer encoding and decoding", src: ("wire/common.go · WriteVarInt", "wire/common.go · ReadVarInt", "wire/common.go · VarIntSerializeSize"))[
  ```python
  def encode_varint(v: uint64) -> bytes:
      if v < 0xfd:
          return u8(v)
      if v <= 0xffff:
          return u8(0xfd) + le16(v)
      if v <= 0xffffffff:
          return u8(0xfe) + le32(v)
      return u8(0xff) + le64(v)

  def decode_varint(r) -> uint64:
      # r.read_*() reject("truncated") when too few bytes remain
      d = r.read_u8()
      if d == 0xff:
          v = r.read_le64()
          if v < 0x100000000:
              reject("non-canonical varint")
      elif d == 0xfe:
          v = r.read_le32()
          if v < 0x10000:
              reject("non-canonical varint")
      elif d == 0xfd:
          v = r.read_le16()
          if v < 0xfd:
              reject("non-canonical varint")
      else:
          v = d
      return v

  def varint_size(v: uint64) -> int:
      return 1 if v < 0xfd else 3 if v <= 0xffff else 5 if v <= 0xffffffff else 9
  ```
] <alg:encoding-varint>

#note[
  #dcp(5) adopts the same encoding, with the same canonical requirement, for
  the item count of compact block filters (#chref("filters")).
]

=== Variable-Length Byte Strings <sec:encoding-varbytes>

A *variable-length byte string* (_varbytes_) is a varint length $n$ followed by
$n$ bytes. Scripts are the only varbytes in consensus structures. Each use
site imposes a maximum on $n$, checked _after_ the varint has been decoded and
_before_ the bytes are read; a length above the maximum makes the structure
undecodable even if the input would contain that many bytes. The maxima for
scripts are given in @rule:encoding-script-length.

A *variable-length string* has the same encoding with the bytes interpreted as
text. Strings occur only in peer-to-peer messages (#chref("p2p")); dcrd bounds
their length by #const("MaxMessagePayload") and, for some fields, additionally
requires printable ASCII (`0x20` to `0x7e`).

=== Hashes <sec:encoding-hashes>

A hash is serialized as its 32 bytes in the order the hash function produced
them, with no length prefix. All hashes in consensus structures are BLAKE-256
digests (#chref("crypto")), written $"BLAKE256"(x)$ below, with the single
exception of the proof-of-work hash of @sec:encoding-pow. When a hash is shown
to people it is displayed with its bytes reversed, as described in
#xref("conv:bytes"). Every byte string in this chapter is in serialized (internal)
order unless it is explicitly labelled as display form.

== Transactions <sec:encoding-tx>

A Decred transaction is split into two parts. The *prefix* holds everything
that determines what the transaction does: the outpoints it spends, the
outputs it creates, its lock time and its expiry. The *witness* holds, for
each input, the signature script that authorizes the spend together with three
fields of fraud-proof data (the amount, block height and block index of the
output being spent). The transaction's identifier is the hash of the prefix
alone, so altering a signature script, which third parties can sometimes do
without invalidating it, cannot change the identifier that later transactions
use to refer to it.

A transaction can be serialized in three ways: in full (prefix followed by
witness), as the prefix alone, or as the witness alone. Which one is used is
recorded in the transaction's first four bytes.

#figure(
  caption: [In-memory transaction structure],
  table(
    columns: (auto, auto, 1fr),
    table.header([Field], [Type], [Meaning]),
    [`version`], [`uint16`], [Transaction version (@tab:encoding-txversions).],
    [`ser_type`], [`uint16`], [Serialization type the transaction was or will be encoded with (@tab:encoding-sertypes).],
    [`inputs`], [list of TxIn], [Each with prefix fields and witness fields (@tab:encoding-txin-prefix, @tab:encoding-txin-witness).],
    [`outputs`], [list of TxOut], [@tab:encoding-txout.],
    [`lock_time`], [`uint32`], [Earliest height or time at which the transaction may be included (#chref("transactions")).],
    [`expiry`], [`uint32`], [Height from which the transaction may no longer be included; `0` means no expiry (#chref("transactions")).],
  ),
) <tab:encoding-txstruct>

=== The Version Word and Serialization Types <sec:encoding-txversion>

Every serialized transaction begins with a 32-bit little-endian *version word*.
Its low 16 bits are the transaction version; its high 16 bits are the
serialization type:

$ "word" = "version" + 2^16 dot "ser_type". $

#figure(
  caption: [Transaction serialization types],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([`ser_type`], [dcrd name], [Body after the version word], [Use]),
    [`0`], [`TxSerializeFull`], [prefix body, then witness body], [The normal encoding: in blocks, in `tx` messages, in storage.],
    [`1`], [`TxSerializeNoWitness`], [prefix body only], [Input to the transaction hash (@sec:encoding-txid).],
    [`2`], [`TxSerializeOnlyWitness`], [witness body only], [Input to the witness hash (@sec:encoding-txid).],
  ),
) <tab:encoding-sertypes>

#rule("Serialization type", src: "wire/msgtx.go · MsgTx.BtcDecode")[
  A transaction whose serialization type (the high 16 bits of the version word)
  is not `0`, `1` or `2` is undecodable.
] <rule:encoding-sertype>

The version (low 16 bits) is not restricted by the decoder. The versions with
a defined meaning are listed below; which versions are permitted in which
context is a validation rule (#chref("transactions"), #chref("staking"),
#chref("treasury")).

#figure(
  caption: [Transaction version constants],
  table(
    columns: (auto, auto, 1fr),
    table.header([Constant], [Value], [Meaning]),
    [#const("TxVersion")], [1], [Initial transaction version.],
    [#const("TxVersionSeqLock")], [2], [Enables relative lock times through the sequence field.],
    [#const("TxVersionAutoRevocations")], [2], [Version of revocations under #dcp(9).],
    [#const("TxVersionTreasury")], [3], [Treasury transactions (#dcp(6)).],
  ),
) <tab:encoding-txversions>

=== Outpoints <sec:encoding-outpoint>

An *outpoint* identifies one output of an earlier transaction. Unlike
Bitcoin's, a Decred outpoint also names the *transaction tree* in which the
referenced transaction appears, because a block carries regular and stake
transactions in two separate lists (@sec:encoding-block).

#fieldtable(
  caption: [Outpoint (37 bytes)],
  ("Hash", "[32]byte", "32", [Transaction hash (@sec:encoding-txid) of the transaction that created the output.]),
  ("Index", "uint32", "4", [Zero-based index of the output within that transaction's outputs.]),
  ("Tree", "int8", "1", [Tree of the transaction that created the output: `0` regular, `1` stake (@tab:encoding-trees).]),
) <tab:encoding-outpoint>

#figure(
  caption: [Transaction tree identifiers],
  table(
    columns: (auto, auto, 1fr),
    table.header([Constant], [Value], [Meaning]),
    [#const("TxTreeRegular")], [0], [The regular transaction tree: ordinary transfers and the coinbase.],
    [#const("TxTreeStake")], [1], [The stake transaction tree: tickets, votes, revocations and treasury transactions.],
    [#const("TxTreeUnknown")], [$-1$], [In-memory marker for "not in a block"; never serialized.],
  ),
) <tab:encoding-trees>

#rule("Outpoint tree byte", src: "wire/msgtx.go · ReadOutPoint")[
  The tree byte is read as an unsigned byte and reinterpreted as `int8`. If
  the result is negative, that is, if the byte is `0x80` or greater, the
  transaction is undecodable.
] <rule:encoding-outpoint-tree>

Tree values `2` to `127` decode successfully. dcrd identifies unspent outputs
by the full triple (hash, index, tree), and every output it records has tree
`0` or `1`, according to the type of the transaction that created it
(#chref("transactions")). An outpoint with any other tree value therefore
never refers to an existing output, and an input carrying one is rejected by
the ordinary missing-input rule, or, for an input that is required to be
null, by the null-outpoint requirement (which includes tree `0`), not by the
decoder.

A *null outpoint* has the all-zero hash, index #const("MaxPrevOutIndex")
$= "0xffffffff"$ and tree `0`. It marks inputs that spend nothing, such as
those of the coinbase, the stakebase input of a vote, the treasurybase and
treasury spends; which of these require a null outpoint, and which
components are checked, is specified with each transaction type.

=== Transaction Inputs <sec:encoding-txin>

Each input has fields in the prefix and fields in the witness. The two halves
are paired by position: the $i$-th witness entry belongs to the $i$-th prefix
entry.

#fieldtable(
  caption: [Transaction input, prefix part (41 bytes)],
  ("PreviousOutPoint", "Outpoint", "37", [The output being spent (@tab:encoding-outpoint).]),
  ("Sequence", "uint32", "4", [Sequence number. #const("MaxTxInSequenceNum") $= "0xffffffff"$ is the default. For transactions of version 2 or higher it can encode a relative lock time (@tab:encoding-sequence; semantics in #chref("transactions")).]),
) <tab:encoding-txin-prefix>

#fieldtable(
  caption: [Transaction input, witness part (16 bytes plus the script)],
  ("ValueIn", "int64", "8", [Amount in atoms of the output being spent, committed by the spender. #const("NullValueIn") $= -1$ is the conventional "not given" value.]),
  ("BlockHeight", "uint32", "4", [Height of the block containing the output being spent. #const("NullBlockHeight") $= 0$ is the null value.]),
  ("BlockIndex", "uint32", "4", [Zero-based position, within its tree, of the transaction that created the output being spent. #const("NullBlockIndex") $= "0xffffffff"$ is the null value.]),
  ("SignatureScript", "varbytes", "var", [Script that satisfies the spent output's public key script (#chref("script")).]),
) <tab:encoding-txin-witness>

dcrd calls the three numeric witness fields *fraud-proof* data: they
repeat, inside the spending transaction, the amount and the location of the
output being spent. For inputs that spend an existing output, consensus requires them
to match the output exactly; for inputs that spend nothing, specific
transaction types require the null values. Both requirements are specified in
#chref("transactions"). Note that "null" for `BlockHeight` is $0$, a valid
height, while "null" for `BlockIndex` is `0xffffffff`.

#figure(
  caption: [Sequence-field constants (semantics in #chref("transactions"))],
  table(
    columns: (auto, auto, 1fr),
    table.header([Constant], [Value], [Meaning]),
    [#const("MaxTxInSequenceNum")], [`0xffffffff`], [Maximum and default sequence number.],
    [#const("SequenceLockTimeDisabled")], [`1 << 31`], [If set, the sequence number is not a relative lock time.],
    [#const("SequenceLockTimeIsSeconds")], [`1 << 22`], [If set, the relative lock time counts units of 512 seconds; otherwise blocks.],
    [#const("SequenceLockTimeMask")], [`0x0000ffff`], [Mask that extracts the relative lock time value.],
    [#const("SequenceLockTimeGranularity")], [`9`], [Seconds-based lock times are shifted right by this amount ($2^9 = 512$).],
  ),
) <tab:encoding-sequence>

=== Transaction Outputs <sec:encoding-txout>

#fieldtable(
  caption: [Transaction output (10 bytes plus the script)],
  ("Value", "int64", "8", [Amount in atoms (@sec:encoding-amounts).]),
  ("Version", "uint16", "2", [Script version of `PkScript`. #const("DefaultPkScriptVersion") $= 0$ (#chref("script")).]),
  ("PkScript", "varbytes", "var", [Public key script: the conditions for spending this output (#chref("script")).]),
) <tab:encoding-txout>

=== Lock Time and Expiry <sec:encoding-locktime>

The prefix ends with two `uint32` fields. `LockTime` is interpreted as a block
height or a Unix time depending on its magnitude, and `Expiry` is a block
height, with #const("NoExpiryValue") $= 0$ meaning that the transaction never
expires. Their semantics are given in #chref("transactions"). A witness-only
serialization does not carry them.

=== Serialized Layouts <sec:encoding-tx-layout>

The *prefix body* and *witness body* are defined as follows; each
serialization type is the version word followed by one or both bodies
(@tab:encoding-sertypes).

#fieldtable(
  caption: [Prefix body],
  ("TxInCount", "varint", "1–9", [Number of inputs $n$.]),
  ("TxIn[i]", "TxIn prefix", [$41n$], [@tab:encoding-txin-prefix, for $i = 0, dots, n - 1$.]),
  ("TxOutCount", "varint", "1–9", [Number of outputs $m$.]),
  ("TxOut[j]", "TxOut", "var", [@tab:encoding-txout, for $j = 0, dots, m - 1$.]),
  ("LockTime", "uint32", "4", []),
  ("Expiry", "uint32", "4", []),
) <tab:encoding-prefix-body>

#fieldtable(
  caption: [Witness body],
  ("WitnessCount", "varint", "1–9", [Number of witness entries. In a full serialization it equals the input count $n$ (@rule:encoding-witness-count).]),
  ("TxIn[i]", "TxIn witness", "var", [@tab:encoding-txin-witness, in input order.]),
) <tab:encoding-witness-body>

#algorithm("Transaction serialization", src: ("wire/msgtx.go · MsgTx.BtcEncode", "wire/msgtx.go · encodePrefix", "wire/msgtx.go · encodeWitness"))[
  ```python
  FULL, NO_WITNESS, ONLY_WITNESS = 0, 1, 2

  def encode_varbytes(b: bytes) -> bytes:
      return encode_varint(len(b)) + b

  def prefix_body(tx) -> bytes:
      out = encode_varint(len(tx.inputs))
      for ti in tx.inputs:
          out += ti.prev.hash + le32(ti.prev.index) + u8(ti.prev.tree) + le32(ti.sequence)
      out += encode_varint(len(tx.outputs))
      for to in tx.outputs:
          out += le64(uint64(to.value)) + le16(to.version) + encode_varbytes(to.pk_script)
      return out + le32(tx.lock_time) + le32(tx.expiry)

  def witness_body(tx) -> bytes:
      out = encode_varint(len(tx.inputs))
      for ti in tx.inputs:
          out += (le64(uint64(ti.value_in)) + le32(ti.block_height)
                  + le32(ti.block_index) + encode_varbytes(ti.sig_script))
      return out

  def serialize_tx(tx, ser_type: int) -> bytes:
      out = le32(tx.version | (ser_type << 16))
      if ser_type == FULL:
          return out + prefix_body(tx) + witness_body(tx)
      if ser_type == NO_WITNESS:
          return out + prefix_body(tx)
      if ser_type == ONLY_WITNESS:
          return out + witness_body(tx)
  ```
] <alg:encoding-tx-serialize>

The serialized size of a transaction in each type follows directly. With $n$
inputs, $m$ outputs, signature scripts $s_i$ and public key scripts $p_j$, and
$V(x)$ the varint size of $x$:

$ "size"_"prefix" = 4 + V(n) + 41 n + V(m) + sum_j (10 + V(|p_j|) + |p_j|) + 8, $
$ "size"_"witness" = 4 + V(n) + sum_i (16 + V(|s_i|) + |s_i|), $
$ "size"_"full" = "size"_"prefix" + "size"_"witness" - 4. $

The size that the transaction-size rule of #chref("transactions") compares
with #param("MaxTxSize") (393216 bytes on the main network) is the size in the
serialization type the transaction was decoded with.

=== Decoding <sec:encoding-tx-decode>

Decoding reads the version word, rejects an unknown serialization type, and
then reads the bodies that the type calls for. Fields that the chosen type
does not carry are set to zero or empty. In particular a prefix-only
transaction has every input's `ValueIn`, `BlockHeight` and `BlockIndex` equal
to $0$ (not to the null values) and empty signature scripts, and a
witness-only transaction has all-zero outpoints, zero sequence numbers, no
outputs, and zero lock time and expiry.

The decoder bounds every count and length before allocating storage for it.
The bounds are derived from #const("MaxMessagePayload") $= 2^25 = 33554432$
bytes, the largest peer-to-peer message payload: a count is rejected when even
the smallest possible elements could not fit into one message.

#figure(
  caption: [Transaction decoding bounds],
  table(
    columns: (auto, auto, 1fr),
    table.header([Bound], [Value], [Derivation]),
    [Inputs (prefix or witness count)], [780336], [$floor(33554432 \/ 43) + 1$, where $43 = 32 + 4 + 1 + 1 + 4 + 1$ is dcrd's `minTxInPayload` (outpoint, a one-byte script-length varint and the sequence, plus one byte).],
    [Outputs], [3728271], [$floor(33554432 \/ 9) + 1$, where $9 = 8 + 1$ is `minTxOutPayload` (value and a one-byte script-length varint).],
    [Signature script length], [33554432], [#const("MaxMessagePayload").],
    [Public key script length], [33554432], [#const("MaxMessagePayload").],
  ),
) <tab:encoding-tx-bounds>

#rule("Transaction element counts", src: ("wire/msgtx.go · MsgTx.decodePrefix", "wire/msgtx.go · MsgTx.decodeWitness"))[
  A transaction is undecodable if its input count (in the prefix body, or in
  the witness body of a witness-only serialization) exceeds 780336, or if its
  output count exceeds 3728271. Each count is compared after it has been
  decoded as a varint and before any element is read.
] <rule:encoding-tx-counts>

#rule("Witness count of a full serialization", src: "wire/msgtx.go · MsgTx.decodeWitness")[
  In a transaction of serialization type `0` (full), the witness count #MUST
  equal the number of inputs read from the prefix body; otherwise the
  transaction is undecodable.
] <rule:encoding-witness-count>

#rule("Script lengths", src: ("wire/msgtx.go · readScript", "wire/msgtx.go · readTxInWitness", "wire/msgtx.go · readTxOut"))[
  A signature script or public key script whose length varint exceeds
  33554432 makes the transaction undecodable. The comparison is made before
  the script bytes are read.
] <rule:encoding-script-length>

#algorithm("Transaction decoding: constants and helpers", src: ("wire/msgtx.go · readScript", "wire/msgtx.go · readTxInWitness"))[
  ```python
  MAX_MESSAGE_PAYLOAD = 33554432
  MAX_TX_IN  = MAX_MESSAGE_PAYLOAD // 43 + 1      # 780336
  MAX_TX_OUT = MAX_MESSAGE_PAYLOAD // 9 + 1       # 3728271

  def decode_varbytes(r, max_len: int) -> bytes:
      n = decode_varint(r)
      if n > max_len:
          reject("script too long")
      return r.read(n)                            # reject("truncated") if short

  def read_witness_fields(r, ti):
      ti.value_in = int64(r.read_le64())
      ti.block_height = r.read_le32()
      ti.block_index = r.read_le32()
      ti.sig_script = decode_varbytes(r, MAX_MESSAGE_PAYLOAD)
  ```
] <alg:encoding-tx-decode-helpers>

#algorithm("Transaction decoding", src: ("wire/msgtx.go · MsgTx.BtcDecode", "wire/msgtx.go · ReadOutPoint", "wire/msgtx.go · readTxOut"))[
  ```python
  def decode_tx(r) -> Tx:
      word = r.read_le32()
      tx = Tx(version=word & 0xffff, ser_type=word >> 16,
              inputs=[], outputs=[], lock_time=0, expiry=0)
      if tx.ser_type not in (FULL, NO_WITNESS, ONLY_WITNESS):
          reject("unknown serialization type")

      if tx.ser_type in (FULL, NO_WITNESS):
          n = decode_varint(r)
          if n > MAX_TX_IN:
              reject("too many inputs")
          for _ in range(n):
              ti = TxIn()                         # all witness fields zero / empty
              ti.prev.hash = r.read(32)
              ti.prev.index = r.read_le32()
              tree = r.read_u8()
              if tree >= 0x80:
                  reject("negative transaction tree")
              ti.prev.tree = tree
              ti.sequence = r.read_le32()
              tx.inputs.append(ti)
          m = decode_varint(r)
          if m > MAX_TX_OUT:
              reject("too many outputs")
          for _ in range(m):
              to = TxOut()
              to.value = int64(r.read_le64())
              to.version = r.read_le16()
              to.pk_script = decode_varbytes(r, MAX_MESSAGE_PAYLOAD)
              tx.outputs.append(to)
          tx.lock_time = r.read_le32()
          tx.expiry = r.read_le32()

      if tx.ser_type == FULL:
          k = decode_varint(r)
          if k != len(tx.inputs):
              reject("witness count differs from input count")
          for ti in tx.inputs:
              read_witness_fields(r, ti)
      elif tx.ser_type == ONLY_WITNESS:
          k = decode_varint(r)
          if k > MAX_TX_IN:
              reject("too many inputs")
          for _ in range(k):
              ti = TxIn()                         # all prefix fields zero
              read_witness_fields(r, ti)
              tx.inputs.append(ti)
      return tx
  ```
] <alg:encoding-tx-decode>

#note[
  None of the bounds in @tab:encoding-tx-bounds can be reached by a
  transaction inside a block that respects the block size limit of
  #chref("blocks") (at most #const("MaxBlockPayload") $= 1310720$ bytes): an
  input prefix alone occupies 41 bytes and an output at least 11. They matter
  for robustness, not for which blocks are valid, but an implementation that
  enforces tighter bounds at decoding time must make sure they too can never
  bind on a block within the size limit.
]

=== Transaction Identifiers <sec:encoding-txid>

Three hashes are defined for every transaction. Each is computed from the
decoded transaction, independently of the serialization type it was received
in.

#algorithm("Transaction hashes", src: ("wire/msgtx.go · MsgTx.TxHash", "wire/msgtx.go · MsgTx.TxHashWitness", "wire/msgtx.go · MsgTx.TxHashFull"))[
  ```python
  def tx_hash(tx) -> bytes:              # "transaction hash", "txid"
      return blake256(serialize_tx(tx, NO_WITNESS))

  def tx_witness_hash(tx) -> bytes:
      return blake256(serialize_tx(tx, ONLY_WITNESS))

  def tx_full_hash(tx) -> bytes:
      return blake256(tx_hash(tx) + tx_witness_hash(tx))
  ```
] <alg:encoding-txhashes>

#figure(
  caption: [Where each transaction hash is used],
  table(
    columns: (auto, 1fr),
    table.header([Hash], [Used for]),
    [Transaction hash (`tx_hash`)], [The transaction's identity: the `Hash` field of outpoints that spend its outputs, the identity of tickets in the ticket pool and lottery, duplicate-transaction checks, display to users. It does not commit to any witness field.],
    [Witness hash (`tx_witness_hash`)], [Only as an input to the full hash.],
    [Full hash (`tx_full_hash`)], [The leaves of the transaction-tree Merkle trees (@sec:encoding-roots), so that the block header commits to the witnesses as well as the prefixes.],
  ),
) <tab:encoding-txhash-uses>

#pitfall[
  - The transaction hash is the hash of the _prefix serialization_, which
    begins with the version word carrying serialization type `1`. It is
    therefore *not* the hash of any substring of the full serialization, whose
    version word carries type `0`. For a version-1 transaction the prefix
    serialization begins `01000100`, the full serialization `01000000`.
  - Likewise the witness serialization begins with type `2` in its version
    word and repeats the input count.
  - The full hash is the hash of the 64-byte concatenation of the two other
    hashes, *not* the hash of the full serialization.
  - Signature hashing (#chref("script")) defines its own serializations. Its
    prefix component coincides with the transaction hash for the signature
    hash type `SigHashAll` without `SigHashAnyOneCanPay` (dcrd reuses the
    cached transaction hash in that case); its witness component is not the
    witness hash defined here.
]

#rationale[
  Including the serialization type in the hashed version word guarantees that
  the prefix and witness hashes of a transaction differ even when the two
  bodies would otherwise be identical byte strings (code comment in
  #src("wire/msgtx.go", "MsgTx.TxHashFull")). Excluding the witness from the
  identifier makes the identifier immune to signature-script malleability.
]

=== Transactions in Blocks <sec:encoding-tx-in-blocks>

Each transaction in a block is decoded with the serialization type given in
its own version word. Blocks produced by dcrd contain only full (type `0`)
transactions, and dcrd's mempool policy refuses any other type, but the block
format and the consensus code do not themselves name the serialization type.

#pitfall[
  dcrd has no consensus rule that names the serialization type of a
  transaction in a block. A block containing a type-`1` or type-`2`
  transaction is decoded as specified above (@rule:encoding-decodable does
  not reject it), its size (header `Size`, @rule:encoding-header-size)
  counts the transaction's actual, shorter encoding, its Merkle leaf is the
  full hash of the transaction _as decoded_ (with zeroed witness or zeroed
  prefix fields), and the transaction is then subject to every ordinary
  validation rule using those decoded values. A header can therefore match
  such a block in `Size` and in its Merkle roots. The block is nevertheless
  always invalid, for the following reasons:
  - A type-`2` transaction has no outputs and fails the requirement that
    every transaction have at least one output (#chref("transactions")).
  - A type-`1` transaction has `ValueIn` $= 0$, `BlockHeight` $= 0$,
    `BlockIndex` $= 0$ and an empty signature script on every input, and it
    has at least one input. An input that spends an existing output fails
    the fraud-proof rule (`ValueIn` must equal the output's amount, and
    outputs of amount $0$ cannot be spent at all). The null input of a
    coinbase, treasurybase or treasury spend fails the null-fraud-proof rule
    (`BlockIndex` must be `0xffffffff`). A vote's stakebase input fails the
    same rule, so the transaction is not recognized as a vote and is then
    rejected for its null outpoint; in any case its ticket input is an input
    of the first kind.
  Running dcrd's validation on blocks whose transactions were re-encoded in
  type `1` produced, respectively, a fraud-proof amount error (regular
  transaction and ticket), a non-null coinbase fraud proof error (coinbase)
  and a null-previous-output error (vote); type `2` produced the
  no-outputs error. Because the Merkle leaf is computed from the decoded
  fields, a full-type transaction with the same field values has the same
  leaf and is invalid for the same reason, so the header itself commits to
  invalid data. An implementation may therefore reject a block containing a
  non-full transaction once the header's commitments to it have been
  checked, but must not validate the transaction as though the missing
  fields were present.
]

== The Block Header <sec:encoding-header>

The block header is a fixed 180-byte structure (#const("MaxBlockHeaderPayload")
$= 84 + 3 dot 32 = 180$). Every field has a fixed width, so the header has
exactly one serialization. Besides the usual chain link, Merkle root,
difficulty, time and nonce, it carries a summary of the block's stake
activity, which allows several stake rules to be checked from headers
alone.

#block(breakable: false)[#fieldtable(
  caption: [Block header (180 bytes). The offset of each field is given first.],
  ("Version", "int32", "4", [Offset 0. Block version (#chref("voting")); not the protocol version.]),
  ("PrevBlock", "[32]byte", "32", [Offset 4. Block hash (@sec:encoding-blockhash) of the parent block; all zero in the genesis block. This is always the BLAKE-256 block hash, never the proof-of-work hash.]),
  ("MerkleRoot", "[32]byte", "32", [Offset 36. Commitment to the transactions: the regular-tree Merkle root, or the combined root after #dcp(5) (@sec:encoding-roots).]),
  ("StakeRoot", "[32]byte", "32", [Offset 68. The stake-tree Merkle root, or the header commitment root after #dcp(5) (@sec:encoding-roots).]),
  ("VoteBits", "uint16", "2", [Offset 100. Bit 0 (`0x0001`) set means the regular transaction tree of the parent block is approved by this block's votes; its consistency with the votes is specified in #chref("staking") and its effect in #chref("blocks"). The remaining bits are described in #chref("voting").]),
  ("FinalState", "[6]byte", "6", [Offset 102. Final state of the ticket-lottery pseudorandom generator (#chref("staking")).]),
  ("Voters", "uint16", "2", [Offset 108. Number of votes in the block.]),
  ("FreshStake", "uint8", "1", [Offset 110. Number of ticket purchases in the block.]),
  ("Revocations", "uint8", "1", [Offset 111. Number of revocations in the block.]),
  ("PoolSize", "uint32", "4", [Offset 112. Size of the live ticket pool (#chref("staking")).]),
  ("Bits", "uint32", "4", [Offset 116. Proof-of-work target in compact form (#chref("difficulty")).]),
  ("SBits", "int64", "8", [Offset 120. Stake difficulty: the ticket price in atoms (#chref("difficulty")).]),
  ("Height", "uint32", "4", [Offset 128. Height of this block.]),
  ("Size", "uint32", "4", [Offset 132. Length in bytes of the serialized block (@rule:encoding-header-size).]),
  ("Timestamp", "uint32", "4", [Offset 136. Block time, Unix seconds.]),
  ("Nonce", "uint32", "4", [Offset 140. Proof-of-work nonce.]),
  ("ExtraData", "[32]byte", "32", [Offset 144. Additional nonce space for miners; no consensus meaning beyond being hashed.]),
  ("StakeVersion", "uint32", "4", [Offset 176. Stake version, determined by the versions of recent votes (#chref("voting")).]),
) <tab:encoding-header>]

#algorithm("Block header serialization", src: "wire/blockheader.go · writeBlockHeader")[
  ```python
  def serialize_header(h) -> bytes:           # always exactly 180 bytes
      return (le32(uint32(h.version)) + h.prev_block + h.merkle_root + h.stake_root
              + le16(h.vote_bits) + h.final_state + le16(h.voters)
              + u8(h.fresh_stake) + u8(h.revocations) + le32(h.pool_size)
              + le32(h.bits) + le64(uint64(h.sbits)) + le32(h.height)
              + le32(h.size) + le32(h.timestamp) + le32(h.nonce)
              + h.extra_data + le32(h.stake_version))
  ```
] <alg:encoding-header>

The decoder reads the 18 fields in this order and imposes no condition on any
of them; a header is undecodable only if fewer than 180 bytes are available.

#note[
  `Nonce` and `ExtraData` together form 36 contiguous bytes (offsets 140 to
  175) that the consensus rules treat as an uninterpreted blob. #dcp(11)
  describes them as a single 36-byte extra-data field and recommends a
  layout for miners and pools; dcrd's split into a 4-byte nonce and 32 further
  bytes is a representation convenience only.
]

#note[
  The timestamp is an unsigned 32-bit count of seconds, so it can represent
  times up to 2106-02-07. The header has no other time field.
]

=== The Block Hash <sec:encoding-blockhash>

The *block hash*, which identifies a block and is the value stored in the
next block's `PrevBlock`, is

$ "BlockHash" = "BLAKE256"("serialize_header"(h)). $

It commits to every header field, and through `MerkleRoot` (and, before
#dcp(5), `StakeRoot`) to every transaction. The block hash has always been
computed this way and is unaffected by #dcp(11).

=== The Proof-of-Work Hash <sec:encoding-pow>

The *proof-of-work hash* is the value compared with the target. Its input is
the same 180-byte header serialization; only the hash function differs:

- if the `blake3pow` agenda (#dcp(11)) is not active for the block, the
  proof-of-work hash is the block hash, $"BLAKE256"("serialize_header"(h))$;
- if it is active, the proof-of-work hash is
  $"BLAKE3"("serialize_header"(h))$ with a 32-byte output.

The hash functions are specified in #chref("crypto") and the target check in
#chref("difficulty"). After #dcp(11) the proof-of-work hash and the block hash
of a block are different values, and only the block hash is used to identify
blocks.

== Transaction Trees and Merkle Roots <sec:encoding-roots>

A block holds two ordered lists of transactions: the *regular transaction
tree* and the *stake transaction tree*. ("Tree" is Decred's name for these
lists; each is a flat sequence, and the word refers to the Merkle tree built
over it.) Which transactions belong in which list is specified in
#chref("blocks") and #chref("staking").

The Merkle root of a list of transactions is the Merkle root, as defined in
#chref("crypto"), of the list of their *full hashes* (@alg:encoding-txhashes)
in block order. That construction pairs adjacent hashes with BLAKE-256,
duplicating the last hash of any level with an odd number of entries; the root
of an empty list is 32 zero bytes, and the root of a one-element list is that
element.

#algorithm("Transaction tree roots and the combined root", src: ("blockchain/standalone/merkle.go · CalcTxTreeMerkleRoot", "blockchain/standalone/merkle.go · CalcCombinedTxTreeMerkleRoot"))[
  ```python
  def tree_root(txs) -> bytes:
      # merkle_root() is the generic construction of the cryptography chapter;
      # merkle_root([]) is 32 zero bytes.
      return merkle_root([tx_full_hash(tx) for tx in txs])

  def combined_root(regular_txs, stake_txs) -> bytes:
      # Equal to merkle_root([tree_root(regular_txs), tree_root(stake_txs)]).
      return blake256(tree_root(regular_txs) + tree_root(stake_txs))
  ```
] <alg:encoding-roots>

What the header's two root fields must contain depends on whether the
`headercommitments` agenda (#dcp(5)) is active for the block, as determined
from its parent by the rules of #chref("voting").

#rule("Merkle roots before header commitments", src: ("internal/blockchain/validate.go · checkMerkleRoots", "internal/blockchain/validate.go · checkMerkleRootsContext"))[
  If the `headercommitments` agenda is not active for the block, the header's
  `MerkleRoot` #MUST equal `tree_root` of the regular transaction tree and
  its `StakeRoot` #MUST equal `tree_root` of the stake transaction tree.
] <rule:encoding-roots-original>

#rule("Merkle roots after header commitments", src: ("internal/blockchain/validate.go · checkMerkleRoots", "internal/blockchain/validate.go · checkConnectBlock"))[
  If the `headercommitments` agenda is active for the block, the header's
  `MerkleRoot` #MUST equal `combined_root` of the regular and stake
  transaction trees, that is, $"BLAKE256"(R || S)$ where $R$ and $S$ are the
  regular and stake tree roots. The `StakeRoot` field then holds the *header
  commitment root*, which #MUST equal the version 1 commitment root of
  #dcp(5), which is the hash of the block's version 2 compact filter (the
  BLAKE-256 hash of the serialized filter data, with an all-zero hash for an
  empty filter). The filter and its hash are specified in #chref("filters")
  and the enforcement of this field in #chref("blocks").
] <rule:encoding-roots-dcp0005>

#history[
  At launch the header committed to the two trees separately, in `MerkleRoot`
  and `StakeRoot`. #dcp(5) merged both commitments into `MerkleRoot` and
  repurposed `StakeRoot` as the root of a new Merkle tree of _header
  commitments_, whose only leaf so far is the hash of the block's compact
  filter, so that light clients can verify filters from headers. On the main
  network the agenda became active at block 431488; an implementation must
  nevertheless determine activation from the chain (#chref("voting")).
]

#note[
  dcrd checks the Merkle roots twice. Before the full chain context of a
  block is available it determines the agenda state "positionally", from the
  known activation block of each network; where that is not possible (on
  networks without a recorded activation) it provisionally accepts a header
  that matches _either_ variant. The contextual check made when the block is
  connected then requires the variant selected by the agenda state. The net
  consensus effect is exactly the two rules above.
]

#pitfall[
  The Merkle leaves are *full* hashes, which commit to the witnesses.
  Outpoints refer to transactions by their *transaction hash*, which does
  not. Using the transaction hash as the leaf yields a different root
  (@sec:encoding-vec-block shows both for a real block).
]

== Block Serialization <sec:encoding-block>

#fieldtable(
  caption: [Block],
  ("Header", "BlockHeader", "180", [@tab:encoding-header.]),
  ("TxCount", "varint", "1–9", [Number of regular transactions.]),
  ("Transactions", "Tx[]", "var", [Regular transaction tree, each transaction serialized in its own serialization type (normally full).]),
  ("STxCount", "varint", "1–9", [Number of stake transactions.]),
  ("STransactions", "Tx[]", "var", [Stake transaction tree, likewise.]),
) <tab:encoding-block>

#algorithm("Block serialization", src: "wire/msgblock.go · MsgBlock.BtcEncode")[
  ```python
  def serialize_block(b) -> bytes:
      out = serialize_header(b.header) + encode_varint(len(b.regular))
      for tx in b.regular:
          out += serialize_tx(tx, tx.ser_type)
      out += encode_varint(len(b.stake))
      for tx in b.stake:
          out += serialize_tx(tx, tx.ser_type)
      return out
  ```
] <alg:encoding-block>

Decoding reads the header, then each count followed by that many
transactions decoded with @alg:encoding-tx-decode. The encoding of a block is
exactly the bytes so consumed. The decoders of blocks and transactions do
not themselves examine what follows the structure. When a block or a
transaction is carried in a peer-to-peer message, dcrd rejects the message
unless its payload consists of exactly those bytes (a payload with
unconsumed trailing bytes is an error); that requirement, and the
per-message size limits, are part of #chref("p2p"). Outside that framing,
trailing bytes are simply not part of the block: dcrd's `submitblock` RPC,
for example, decodes the block from the front of the submitted data and
does not reject anything after it. Such bytes count neither towards the
block's size nor towards its hash, although dcrd keeps the submitted buffer
as the block's serialization: it is written to the block database with the
trailing bytes and returned unchanged by `getblock` in raw form, while peers
are sent a re-encoding without them.

#rule("Block transaction counts", src: ("wire/msgblock.go · MsgBlock.BtcDecode", "wire/msgblock.go · MaxTxPerTxTree"))[
  A block is undecodable if either its regular or its stake transaction count
  exceeds $floor(floor(P \/ 15) \/ 2) + 1$, where $15$ is the size of the
  smallest possible full transaction (`minTxPayload`: version word, three
  one-byte varints, lock time, expiry) and $P$ is
  #const("MaxBlockPayloadV3") $= 1000000$ when decoding at peer-to-peer
  protocol version 3 or lower (giving 33334), and #const("MaxBlockPayload")
  $= 1310720$ at higher protocol versions (giving 43691). dcrd decodes blocks
  from storage and from the `submitblock` RPC at protocol version 0, and
  therefore with the bound 33334.
] <rule:encoding-block-counts>

#note[
  This bound depends on a transport parameter, but it never decides whether a
  block is valid. Every block must have a serialized size of at most 1310720
  bytes (#chref("blocks")), and every transaction must have at least one input
  and one output (#chref("transactions")), which makes it at least 66 bytes
  long even in prefix-only form (see @tab:encoding-min-sizes). Such a block
  holds at most $floor(1310720 \/ 66) = 19859$ transactions in total, well
  below 33334. Put the other way round, a block that exceeded the count within
  1310720 bytes would have to contain a transaction shorter than 40 bytes,
  which cannot have both an input and an output. An implementation may
  therefore omit the bound, or apply either value, without affecting
  consensus.
]

=== Block Size <sec:encoding-blocksize>

The *size* of a block is the length in bytes of `serialize_block` applied to
the decoded block: header, both counts and every transaction in the
serialization type it was decoded with. Since decoding is canonical this is
also the number of bytes the block occupied on the wire.

#rule("Header size field", src: "internal/blockchain/validate.go · checkBlockDataSanity")[
  The header's `Size` field #MUST equal the size of the block as just defined.
] <rule:encoding-header-size>

The limits on the size, the context-free bound of #const("MaxBlockPayload")
$= 1310720$ bytes and the network-specific maximum #param("MaximumBlockSizes")
(393216 bytes on the main network), are block validation rules specified in
#chref("blocks").

#figure(
  caption: [Minimum sizes and fixed sizes],
  table(
    columns: (auto, auto, 1fr),
    table.header([Structure], [Bytes], [Composition]),
    [Block header], [180], [Fixed.],
    [Outpoint], [37], [32 + 4 + 1.],
    [Input, prefix part], [41], [Outpoint + 4.],
    [Input, witness part], [$>= 17$], [8 + 4 + 4 + script-length varint + script; 17 with an empty script.],
    [Output], [$>= 11$], [8 + 2 + script-length varint + script; 11 with an empty script.],
    [Full transaction, no inputs or outputs], [15], [4 + 1 + 1 + 4 + 4 + 1. Decodable but never valid.],
    [Full transaction, 1 input, 1 output, empty scripts], [84], [Smallest full transaction that has an input and an output.],
    [Prefix-only transaction, 1 input, 1 output], [66], [Same transaction in serialization type 1.],
    [Witness-only transaction, 1 input], [22], [Same transaction in serialization type 2.],
    [Main-network genesis block], [300], [Header, one 118-byte coinbase, empty stake tree.],
  ),
) <tab:encoding-min-sizes>

=== The Genesis Block <sec:encoding-genesis>

Each network's genesis block is a fixed constant (#chref("parameters")). It is
valid by definition, and none of its fields are validated. Two of its fields
are inconsistent with the rules above, and an implementation must use the
constant as given rather than recompute it:

- its header `Size` is $0$ on every network, although the main-network
  genesis block serializes to 300 bytes;
- on the test network (version 3) its `MerkleRoot` is the _transaction hash_
  of the genesis coinbase instead of its full hash (a mistake recorded in a
  comment in #src("chaincfg/testnetparams.go", "TestNet3Params")); on the other
  networks it is the full hash, as @rule:encoding-roots-original would
  require.

Changing either value would change the genesis hash and therefore every block
of that network.

== Amounts <sec:encoding-amounts>

Amounts are integers counting *atoms* and are carried in `int64` fields:
`TxOut.Value`, `TxIn.ValueIn` and the header's `SBits`. On the wire they are
eight little-endian bytes of the two's complement representation, and every
bit pattern decodes. The range checks, which make negative output values,
values above #const("MaxAmount") and negative input values other than
#const("NullValueIn") invalid, are transaction rules
(#chref("transactions")).

#figure(
  caption: [Amount constants],
  table(
    columns: (auto, auto, 1fr),
    table.header([Constant], [Value], [Meaning]),
    [#const("AtomsPerCoin")], [$10^8$], [Atoms per DCR.],
    [#const("AtomsPerCent")], [$10^6$], [Atoms per hundredth of a DCR.],
    [#const("MaxAmount")], [$21 dot 10^6 dot 10^8 = 2100000000000000$], [Largest amount permitted in any single value or sum (#chref("transactions")).],
    [#const("NullValueIn")], [$-1$], [Conventional "not given" value of `ValueIn`.],
  ),
) <tab:encoding-amounts>

== Summary of Constants and Decoding Limits <sec:encoding-limits>

#figure(
  caption: [Encoding constants],
  table(
    columns: (auto, auto, 1fr),
    table.header([Constant], [Value], [Meaning]),
    [#const("MaxVarIntPayload")], [9], [Longest varint encoding.],
    [#const("HashSize")], [32], [Bytes in a hash.],
    [#const("MaxBlockHeaderPayload")], [180], [Bytes in a block header (exact).],
    [#const("MaxMessagePayload")], [33554432], [Largest peer-to-peer payload; basis of the transaction decoding bounds.],
    [#const("MaxBlockPayloadV3")], [1000000], [Largest block message at protocol version 3 or lower.],
    [#const("MaxBlockPayload")], [1310720], [Largest block message at later protocol versions; also the context-free block size limit (#chref("blocks")).],
    [#const("MaxPrevOutIndex")], [`0xffffffff`], [Largest outpoint index; the index of a null outpoint.],
    [#const("MaxTxInSequenceNum")], [`0xffffffff`], [Largest and default sequence number.],
    [#const("NullValueIn")], [$-1$], [Null `ValueIn`.],
    [#const("NullBlockHeight")], [0], [Null `BlockHeight`.],
    [#const("NullBlockIndex")], [`0xffffffff`], [Null `BlockIndex`.],
    [#const("NoExpiryValue")], [0], [`Expiry` value meaning "never expires".],
    [#const("DefaultPkScriptVersion")], [0], [Default output script version.],
    [#const("TxTreeRegular")], [0], [Regular tree identifier.],
    [#const("TxTreeStake")], [1], [Stake tree identifier.],
  ),
) <tab:encoding-constants>

#figure(
  caption: [Every condition under which a consensus structure is undecodable],
  table(
    columns: (auto, 1fr, auto),
    table.header([Structure], [Condition], [Rule]),
    [Any], [Input ends before a field is complete.], [@rule:encoding-decodable],
    [Varint], [Non-canonical (value fits a shorter form).], [@rule:encoding-varint-canonical],
    [Transaction], [Serialization type not 0, 1 or 2.], [@rule:encoding-sertype],
    [Transaction], [Outpoint tree byte $>=$ `0x80`.], [@rule:encoding-outpoint-tree],
    [Transaction], [Input count $> 780336$ or output count $> 3728271$.], [@rule:encoding-tx-counts],
    [Transaction], [Full serialization whose witness count differs from its input count.], [@rule:encoding-witness-count],
    [Transaction], [Script length $> 33554432$.], [@rule:encoding-script-length],
    [Block], [Regular or stake transaction count above 33334 (protocol version $<= 3$, and storage) or 43691 (later versions).], [@rule:encoding-block-counts],
  ),
) <tab:encoding-undecodable>

== Test Vectors <sec:encoding-vectors>

All vectors in this section were produced by running dcrd's `wire`,
`chaincfg` and `blockchain/standalone` packages at the reference commit. Byte
strings are in serialized order; hashes are given in both serialized
("internal") and display form.

=== Variable-Length Integers <sec:encoding-vec-varint>

#vector[Varint encodings at every boundary][
  ```
  value                         encoding
  0                             00
  252          (0xfc)           fc
  253          (0xfd)           fdfd00
  255          (0xff)           fdff00
  256          (0x100)          fd0001
  65535        (0xffff)         fdffff
  65536        (0x10000)        fe00000100
  4294967295   (0xffffffff)     feffffffff
  4294967296   (0x100000000)    ff0000000001000000
  2^64 - 1                      ffffffffffffffffff
  ```
]

#vector[Varint decoding: rejected and accepted inputs][
  ```
  input                  result
  fd0000                 reject: non-canonical (0 < 0xfd)
  fdfc00                 reject: non-canonical (252 < 0xfd)
  fdfd00                 253
  fe00000000             reject: non-canonical (0 < 0x10000)
  feffff0000             reject: non-canonical (65535 < 0x10000)
  fe00000100             65536
  ff0000000000000000     reject: non-canonical (0 < 0x100000000)
  ffffffffff00000000     reject: non-canonical (4294967295 < 0x100000000)
  ff0000000001000000     4294967296
  fd00                   reject: truncated
  fe000001               reject: truncated
  (empty)                reject: truncated
  ```
]

=== The Main-Network Genesis Block <sec:encoding-vec-genesis>

The main-network genesis header serializes to the following 180 bytes:

#vector[Main-network genesis block header][
  ```
  01000000
  0000000000000000000000000000000000000000000000000000000000000000
  0dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb99174aa66
  0000000000000000000000000000000000000000000000000000000000000000
  0000 000000000000 0000 00 00 00000000 ffff011b 00c2eb0b00000000
  00000000 00000000 a0d7b856 00000000
  0000000000000000000000000000000000000000000000000000000000000000
  00000000

  block hash (internal):
    80d9212bf4ceb066ded2866b39d4ed89e0ab60f335c11df8e7bf85d9c35c8e29
  block hash (display):
    298e5cc3d985bfe7f81dc135f360abe089edd4396b86d2de66b0cef42b21d980
  BLAKE3 of the header (internal):
    1baa4b79809fc85fac9333371d37e203f34c345595f5ed5ed435fbc10b09d3d7
  ```
  The lines hold, in order: `Version`; `PrevBlock`; `MerkleRoot`;
  `StakeRoot`; `VoteBits` to `SBits`; `Height`, `Size`, `Timestamp` and
  `Nonce`; `ExtraData`; `StakeVersion` (see @tab:encoding-genesis-header).
  The BLAKE3 value only illustrates @sec:encoding-pow; the genesis block is
  not subject to a proof-of-work check.
]

#figure(
  caption: [Main-network genesis header, field by field],
  table(
    columns: (auto, auto, auto, 1fr, auto),
    table.header([Offset], [Bytes], [Field], [Serialized bytes], [Value]),
    [0], [4], [Version], [#hex("01000000")], [1],
    [4], [32], [PrevBlock], [#hex("0000000000000000000000000000000000000000000000000000000000000000")], [none],
    [36], [32], [MerkleRoot], [#hex("0dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb99174aa66")], [Full hash of the coinbase],
    [68], [32], [StakeRoot], [#hex("0000000000000000000000000000000000000000000000000000000000000000")], [Empty stake tree],
    [100], [2], [VoteBits], [#hex("0000")], [0],
    [102], [6], [FinalState], [#hex("000000000000")], [zero],
    [108], [2], [Voters], [#hex("0000")], [0],
    [110], [1], [FreshStake], [#hex("00")], [0],
    [111], [1], [Revocations], [#hex("00")], [0],
    [112], [4], [PoolSize], [#hex("00000000")], [0],
    [116], [4], [Bits], [#hex("ffff011b")], [`0x1b01ffff`],
    [120], [8], [SBits], [#hex("00c2eb0b00000000")], [200000000 (2 DCR)],
    [128], [4], [Height], [#hex("00000000")], [0],
    [132], [4], [Size], [#hex("00000000")], [0 (see @sec:encoding-genesis)],
    [136], [4], [Timestamp], [#hex("a0d7b856")], [1454954400 (2016-02-08 18:00:00 UTC)],
    [140], [4], [Nonce], [#hex("00000000")], [0],
    [144], [32], [ExtraData], [#hex("0000000000000000000000000000000000000000000000000000000000000000")], [zero],
    [176], [4], [StakeVersion], [#hex("00000000")], [0],
  ),
) <tab:encoding-genesis-header>

The genesis block has one regular transaction, the coinbase, and an empty
stake tree. Its `MerkleRoot` is `tree_root` of a one-element list, which is
the coinbase's full hash, and its `StakeRoot` is `tree_root` of the empty
list, which is zero: the genesis header conforms to
@rule:encoding-roots-original.

#vector[Main-network genesis coinbase in all three serialization types][
  ```
  full serialization (118 bytes):
    01000000                      version 1, type 0
    01                            1 input
    0000000000000000000000000000000000000000000000000000000000000000
    ffffffff 00                   index 0xffffffff, tree 0
    ffffffff                      sequence
    01                            1 output
    0000000000000000 0000         value 0, script version 0
    20                            script length 32
    801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9
    00000000 00000000             lock time, expiry
    01                            1 witness
    ffffffffffffffff              ValueIn = -1 (null)
    00000000 ffffffff             BlockHeight, BlockIndex (null)
    02 0000                       signature script 0000

  prefix serialization (98 bytes): the first 98 bytes above,
    with version word 01000100 in place of 01000000
  witness serialization (24 bytes):
    01000200 01 ffffffffffffffff 00000000 ffffffff 02 0000

  transaction hash, internal and display:
    2c0ad603d44a16698ac951fa22aab5e7b30293fa1d0ac72560cdfcc9eabcdfe7
    e7dfbceac9fccd6025c70a1dfa9302b3e7b5aa22fa51c98a69164ad403d60a2c
  witness hash, internal and display:
    6c6a06b87b148ada9f3950d0cc275a4bad21622116bd1de16909f5eff1874eeb
    eb4e87f1eff50969e11dbd16216221ad4b5a27ccd050399fda8a147bb8066a6c
  full hash, internal and display:
    0dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb99174aa66
    66aa7491b9adce110585ccab7e3fb5fe280de174530cca10eba2c6c3df01c10d
  BLAKE-256 of the full serialization (not an identifier), internal:
    33c951d47eef1f372f3ac45f8da9eb3f7982121b8db4a30ab12c28ccb3a51c00
  ```
]

#vector[Main-network genesis block (300 bytes)][
  The 180-byte header above, then `01`, the 118-byte full coinbase, and `00`
  (no stake transactions). Its size is $180 + 1 + 118 + 1 = 300$ bytes; the
  header's `Size` field nevertheless holds 0.
]

=== A Regular Transaction <sec:encoding-vec-tx>

The following one-input, two-output pay-to-public-key-hash transaction is
taken from dcrd's test data (`dcrutil/txsort/testdata/tx150043-14.hex`).

#vector[Transaction `aa4c208c…ff6684`, full serialization (252 bytes)][
  ```
  01000000                                               version 1, type 0
  01                                                     1 input; outpoint:
  64084d5f9b7fcedd3d816b7e1ba154123310dd892c09b53c8bf811804efab903
  00000000 00                                            index 0, tree 0
  ffffffff                                               sequence
  02                                                     2 outputs
  52deda0a00000000 0000                                  182115922, ver. 0
  19 76a9146ab21ce59fedbfe724cd979d1409397c68105c0d88ac  25-byte script
  52deda0a00000000 0000                                  182115922, ver. 0
  19 76a9145529ab44931e1ad083df53fa97f4922a80f234b688ac  25-byte script
  00000000                                               lock time 0
  00000000                                               expiry 0 (none)
  01                                                     1 witness
  781fb61500000000                                       ValueIn 364257144
  0d4a0200                                               BlockHeight 150029
  04000000                                               BlockIndex 4
  6b                                                     107-byte script:
  483045022100c6ae9a0587e64b6761a55e81321eee6dd3550e9c9a69c058d773
  4f0ade1ce00702200650ecc1eacc938bedae55a7f2d0e73bee548dcce77352ef
  f77b090b8087b6de012102d30f38730d4d4feb7f7fec0d2c81b550ff702d03c8
  191cd6b98e28f9da9e2c9c
  ```
  The fee, input amount minus output amounts, is
  $364257144 - 2 dot 182115922 = 25300$ atoms.
]

#vector[The same transaction, prefix and witness serializations][
  ```
  prefix serialization (127 bytes):
    01000100 01
    64084d5f9b7fcedd3d816b7e1ba154123310dd892c09b53c8bf811804efab903
    00000000 00 ffffffff
    02
    52deda0a00000000 0000
    19 76a9146ab21ce59fedbfe724cd979d1409397c68105c0d88ac
    52deda0a00000000 0000
    19 76a9145529ab44931e1ad083df53fa97f4922a80f234b688ac
    00000000 00000000

  witness serialization (129 bytes):
    01000200 01 781fb61500000000 0d4a0200 04000000 6b
    483045022100c6ae9a0587e64b6761a55e81321eee6dd3550e9c9a69c058d773
    4f0ade1ce00702200650ecc1eacc938bedae55a7f2d0e73bee548dcce77352ef
    f77b090b8087b6de012102d30f38730d4d4feb7f7fec0d2c81b550ff702d03c8
    191cd6b98e28f9da9e2c9c

  transaction hash, internal and display:
    8466ff8d3e1ca16c4f3bd6dc651c8bd9da9c0066d51dd1546957a9858c204caa
    aa4c208c85a9576954d11dd566009cdad98b1c65dcd63b4f6ca11c3e8dff6684
  witness hash, internal and display:
    3f2d5c43f31cb6d0379c5522bcedb8552d4da1bd1b1b9f4efa7288dc9789f7bf
    bff78997dc8872fa4e9f1b1bbda14d2d55b8edbc22559c37d0b61cf3435c2d3f
  full hash, internal and display:
    9a40e02e84c432d82dbdce8f62ab6bfce9ba3b28cbd4554529a29efc946736d2
    d2366794fc9ea2294555d4cb283bbae9fc6bab628fcebd2dd832c4842ee0409a
  ```
  Decoding the 127-byte prefix serialization yields a transaction with
  serialization type 1, one input and two outputs, whose transaction hash is
  the same as above. Its full hash, computed from the zeroed witness fields,
  is (display) \
  #hex("d2de7ea99bdc25cb96c3b0bcbc1ea8cc267d8b24e8f1ee673ca637077e890f28"),
  which differs from the full hash of the complete transaction.
]

=== Merkle Roots of a Block After DCP-0005 <sec:encoding-vec-block>

Main-network block 432100 (from dcrd's test data,
`internal/rpcserver/testdata/block432100.bz2`) is later than the activation of
`headercommitments` at block 431488. It has 2 regular and 5 stake
transactions.

#vector[Block 432100: roots and size][
  ```
  block hash (display):
    000000000000000023455b4328635d8e014dbeea99c6140aa715836cc7e55981
  regular tree root (display):
    703983b9e834362a3cd3b4e397b76465b85fde1a87325415ec7527d471f24ed8
  stake tree root (display):
    8ef384279548ac3965c0f972dcbc39992ffbc8563b4adba80e932887abe38102
  combined root = BLAKE-256(regular root || stake root), internal:
    0bc8a255edde9901ecc4cdb93e4e573cb38ae91e84495ecddc0c93c019351d5d
  header bytes 36..67 (MerkleRoot), equal to the combined root:
    0bc8a255edde9901ecc4cdb93e4e573cb38ae91e84495ecddc0c93c019351d5d
  header bytes 68..99 (StakeRoot), the commitment root:
    7731998be0a78e955f6fb98d2f35479905c3279f6257beab42a51d556cef55b9
  regular root computed with transaction-hash leaves (wrong), display:
    cccb5c46855861a22b010df67933286e9225f5cb55a5a8833d9a80fae27c1e1d
  header bytes 132..135 (Size):
    de0a0000 = 2782 = length of the serialized block
  ```
  The combined root is the BLAKE-256 hash of the 64 bytes formed by the
  regular and stake tree roots in internal byte order (the reverse of the
  display forms shown).
]

=== Decoding Failures <sec:encoding-vec-errors>

Each of the following modifications of the 118-byte genesis coinbase was
passed to dcrd's transaction decoder.

#vector[Transaction decoding failures][
  ```
  modification                          result
  byte 2 (low byte of type) := 03       reject: unsupported serialization type
  byte 41 (outpoint tree) := 80         reject: negative transaction tree (-128)
  byte 41 (outpoint tree) := 7f         decodes (tree 127)
  byte 98 (witness count) := 02         reject: witness count 2, prefix count 1
  byte 98 (witness count) := 00         reject: witness count 0, prefix count 1
  last byte removed                     reject: truncated
  byte 2 := 01                          decodes as a 98-byte prefix-only transaction;
                                        the remaining 20 bytes are not part of it
  ```
  The last case shows why a decoder must stop at the end of the structure:
  in a block, those 20 bytes would be read as the start of the next
  transaction or count.
]
