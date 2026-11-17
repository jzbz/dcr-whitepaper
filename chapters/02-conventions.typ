#import "../template.typ": *

= Conventions and Notation <ch:conventions>

This chapter fixes the vocabulary and notation used in the rest of the
document. It is short, but several of its conventions, in particular the
treatment of integer arithmetic and of hash byte order, are the source of most
consensus failures in independent implementations and are worth reading
closely.

== Normative Language <conv:normative>

The key words #MUST, #MUSTNOT, #SHOULD, #SHOULDNOT and #MAY are to be
interpreted as described in RFC 2119 @rfc2119. They are set in semibold sans-serif capitals
whenever they carry that meaning.

Requirements come in two kinds, and the distinction matters:

- A *consensus rule* determines whether a block, and therefore everything in
  it, is valid. Every full node must reach the same verdict on every block, so
  a consensus rule has exactly one correct implementation. Consensus rules are
  set apart in numbered boxes, like @rule:conv-example, and are listed together
  in #chref("rule-index").
- A *policy rule* governs what a node chooses to relay, store in its memory
  pool, or include in the blocks it creates. Nodes are free to differ on
  policy without splitting the network. Policy is described in ordinary prose
  and in #chref("policy").

#rule("Example of a consensus rule", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  A rule box states one requirement completely, using #MUST or #MUSTNOT. The
  line at the bottom right names the place in the reference implementation
  that enforces it, as a path within the dcrd source tree followed by the
  function.
] <rule:conv-example>

Besides rule boxes, four kinds of aside appear throughout the text.

#note[
  A note adds informative detail. Nothing in a note is required for consensus.
]

#rationale[
  A rationale explains why a rule exists or why it takes the form it does.
]

#history[
  A history box describes how a rule changed over the life of the chain.
  Because a node must validate every block since the genesis block, historical
  behaviour is as binding as current behaviour: where a rule changed at some
  height or through a vote, both forms are specified.
]

#pitfall[
  A pitfall marks behaviour that is easy to implement almost correctly.
]

== The Reference Implementation <conv:reference>

Decred has no specification separate from its software. The protocol is
defined by the behaviour of _dcrd_ @dcrd, the full-node implementation
maintained by the Decred developers, and by the Decred Change Proposals
(DCPs) @dcp0000 that document each change to the consensus rules put to a
stakeholder vote. This document describes dcrd as of the commit named on the
title page. Where this document and dcrd disagree, dcrd is correct and this
document is in error.

Source references such as #src("blockchain/stake/lottery.go", "findTicketIdxs")
give a path relative to the root of the dcrd repository and one or more
identifiers within that file. A DCP is cited as, for example, #dcp(11).

Each network that runs the protocol (the main network, the test network and
two kinds of private network) is defined by a set of *network parameters*.
A parameter is written in the form #param("TicketMaturity"), using the name of
the corresponding field in dcrd's `chaincfg.Params` structure. The values for
every network are tabulated in #chref("parameters"). Unless a passage says
otherwise, concrete numbers in the text are main-network values. Constants
that are the same on every network are written in the form
#const("MaxAmount").

== Integers and Arithmetic <conv:integers>

Consensus code is integer code. No rule in this document involves floating
point arithmetic, and an implementation #MUSTNOT use floating point to
evaluate any formula given here.

@tab:conv-types lists the integer types used. All are two's complement.

#figure(
  caption: [Integer types],
  table(
    columns: (auto, auto, 1fr),
    table.header([Type], [Width], [Range]),
    [`uint8`, `byte`], [8 bits], [$0$ to $2^8 - 1$],
    [`uint16`], [16 bits], [$0$ to $2^16 - 1$],
    [`uint32`], [32 bits], [$0$ to $2^32 - 1$],
    [`int32`], [32 bits], [$-2^31$ to $2^31 - 1$],
    [`uint64`], [64 bits], [$0$ to $2^64 - 1$],
    [`int64`], [64 bits], [$-2^63$ to $2^63 - 1$],
    [`bigint`], [unbounded], [Arbitrary-precision signed integer],
  ),
) <tab:conv-types>

Three properties of fixed-width arithmetic are relied upon and must be
reproduced exactly:

/ Wrapping: Addition, subtraction and multiplication of fixed-width integers
  wrap modulo $2^w$, where $w$ is the width, unless a rule explicitly checks
  for overflow. Where a computation is specified on a fixed-width type, the
  text names the type.
/ Truncating division: Integer division rounds toward zero, so
  $-7 div 2 = -3$, and the remainder takes the sign of the dividend, so
  $-7 mod 2 = -1$. This is the behaviour of Go, C and Rust, and differs from
  the flooring division of Python and of mathematical convention whenever
  exactly one operand is negative and the division is inexact.
/ Arithmetic shift: A right shift of a signed integer replicates the sign
  bit, so $-7 >> 1 = -4$. A right shift of a `bigint` likewise rounds toward
  negative infinity.

In formulas, $floor(x)$ denotes the floor function, and $a div b$ and
$a mod b$ denote truncating division and its remainder as just defined. For
non-negative operands the two notions of division coincide and plain
fraction notation with an explicit floor is used.

== Bytes, Byte Order and Hashes <conv:bytes>

A *byte string* is a finite sequence of bytes. Byte strings are written in
hexadecimal, lowest index first, in a fixed-width face:
#hex("0100000000") is five bytes, the first of which is `0x01`. The
concatenation of byte strings $a$ and $b$ is written $a || b$, and the length
of $a$ in bytes is $|a|$.

Unless stated otherwise, multi-byte integers are serialized *little-endian*:
least significant byte first. The functions $"LE"_16$, $"LE"_32$ and
$"LE"_64$ map an integer to its 2-, 4- or 8-byte little-endian encoding, and
$"BE"_n$ denotes the big-endian counterparts, which occur in a small number
of places that are pointed out individually.

A *hash* is a 32-byte string produced by one of the hash functions of
#chref("crypto"). Hashes are subject to a display convention inherited from
Bitcoin that must be kept firmly in mind.

#pitfall[
  When a block hash or transaction hash is shown to people (in block
  explorers, in RPC results, and in this document wherever it is called a
  hash _in display form_), its 32 bytes are written in *reverse* order. The
  hash whose bytes in memory and on the wire are
  #hex("80d9212bf4ceb066ded2866b39d4ed89e0ab60f335c11df8e7bf85d9c35c8e29")
  is displayed as
  #hex("298e5cc3d985bfe7f81dc135f360abe089edd4396b86d2de66b0cef42b21d980"),
  which is the hash of the main-network genesis block. Serialized structures
  always carry the bytes in their natural, un-reversed order, which this
  document calls the hash's _internal byte order_.
]

When a 32-byte hash is compared with a numeric target, as in the proof-of-work
check, it is interpreted as a 256-bit unsigned integer in little-endian byte
order. Read as a number, the display form is therefore the big-endian
hexadecimal representation, which is why the hashes of blocks mined before the
change of proof-of-work function are displayed with leading zeros. Since that
change the proof-of-work hash and the block hash are different values
(#chref("difficulty")), and block hashes no longer have this appearance.

== Amounts <conv:amounts>

The unit of account is the *decred*, abbreviated DCR. All amounts in the
protocol are integers counting *atoms*, where

$ 1 "DCR" = 10^8 "atoms". $

Amounts are carried in the `int64` type. The largest amount that is valid
anywhere in the protocol is #const("MaxAmount") $= 21 times 10^6 times 10^8$
atoms, twenty-one million decred. This is a bound used in range checks on
individual amounts. It is not derived from the issuance schedule, whose exact
total is computed in #chref("subsidy").

== Heights, Time and Intervals <conv:time>

The *height* of a block is its distance from the genesis block, which has
height 0. Heights are carried on the wire as `uint32` and used in
computations as `int64`.

Timestamps are Unix time: whole seconds since 1970-01-01 00:00:00 UTC,
ignoring leap seconds. Block header timestamps are `uint32` on the wire.

Many rules operate on fixed-length runs of consecutive blocks. An *interval*
or *window* of length $n$ always begins at a height that is a multiple of $n$
unless a rule specifies an offset. The text states, for each such rule, which
block is the first to which a newly computed value applies, because this is
where off-by-one errors occur.

== Pseudocode <conv:pseudocode>

Algorithms are given in a Python-like pseudocode. It is meant to be read, not
executed, and follows these conventions:

- Integers are unbounded unless a variable is annotated with a fixed-width
  type or a conversion such as `uint32(x)` is applied. A conversion to an
  unsigned type reduces its argument modulo $2^w$. A conversion to a signed
  type reduces modulo $2^w$ and reinterprets the result as two's complement.
- `a // b` is used only where both operands are non-negative, where floor and
  truncating division agree. Where an operand may be negative the functions
  `tdiv(a, b)` and `tmod(a, b)` denote truncating division and its remainder,
  and `fdiv(a, b)`, for `b > 0`, denotes flooring division, which rounds
  toward negative infinity.
- `>>` and `<<` are shifts with the semantics given in @conv:integers.
- `x[i]` indexes a sequence from zero, and `x[i:j]` is the subsequence from
  index `i` up to but not including `j`.
- `a + b` on byte strings is concatenation. `le16`, `le32`, `le64`, `be32`
  and so on serialize integers as described in @conv:bytes.
- `reject(reason)` aborts validation: the object being validated is invalid.

@alg:conv-example shows the style.

#algorithm("Example: the sum of a list of amounts, with range checks", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  ```python
  MAX_AMOUNT = 21_000_000 * 100_000_000

  def checked_sum(amounts: list[int64]) -> int64:
      total = 0
      for amount in amounts:
          if amount < 0 or amount > MAX_AMOUNT:
              reject("output value out of range")
          total = total + amount          # cannot overflow int64 here; dcrd
                                          # checks for it all the same
          if total > MAX_AMOUNT:
              reject("total output value out of range")
      return total
  ```
] <alg:conv-example>

== Consensus Votes and Rule Activation <conv:agendas>

Decred's consensus rules have changed many times since launch, and since
the first agendas of 2017 each change to the validation rules has been
activated by a vote of the stakeholders (#chref("voting")); the
exceptions are the rules keyed to a proof-of-work majority of block versions
(the rejection of superseded block versions and the enforcement of the
header stake version, #chref("blocks")) and the testnet3 difficulty rules
fixed at a hard-coded height (#chref("difficulty")). Each change is identified by the
DCP that specifies it and by the short *agenda identifier* under which it was
voted, such as `blake3pow`. A rule that depends on a vote is described in
terms of whether the agenda *is active for a block*, which is a deterministic
function of the block's ancestors defined in #chref("voting"). The heights at
which each agenda became active on the main network are listed there as well,
but an implementation must derive activation from the chain itself and not
from a table of heights, since the other networks activate at different
points.

== Test Vectors <conv:vectors>

Where a computation can be checked in isolation, test vectors are supplied.

#vector[BLAKE-256 of the empty string][
  ```
  input   (0 bytes)
  output  716f6e863f744b9ac22c97ec7b76ea5f5908bc5b2f67c61510bfc4751384ea7a
  ```
]

Every vector in this document was produced by running the reference
implementation, not transcribed from secondary sources.
