#import "../template.typ": *

= Proof of Work and Difficulty <ch:difficulty>

Every Decred block header carries two difficulty values. The *difficulty
bits* (header field `Bits`) encode the proof-of-work *target*: the hash of
the header, computed with the network's proof-of-work hash function and read
as a number, must not exceed it. The *stake difficulty* (header field
`SBits`), also called the *ticket price*, is the minimum amount, in atoms,
that a ticket purchased in the block must pay. Neither value is chosen by the
miner. Each is a deterministic function of the chain that the block extends,
and a block whose header states any other value is invalid.

This chapter specifies how the proof of work is checked, how targets are
encoded, how the work of a chain is measured, and how both difficulty values
are computed. Each of the three mechanisms has changed once by stakeholder
vote, and both forms of each are normative because a node validates the whole
chain from the genesis block:

- The proof-of-work hash was BLAKE-256 until the `blake3pow` agenda
  (#dcp(11) @dcp0011) and is BLAKE3 afterwards.
- The proof-of-work target was retargeted every 144 blocks by an
  exponentially weighted moving average (here called the *EMA algorithm*)
  until the same agenda, and is computed for every block by ASERT afterwards.
- The stake difficulty was computed by a windowed moving average (*stake
  difficulty version 1*) until the `sdiffalgorithm` agenda (#dcp(1)
  @dcp0001), and by the pool-size-based algorithm of that DCP (*version 2*)
  afterwards.

== Overview and Selection of Algorithms <sec:difficulty-overview>

@tab:difficulty-algos lists the mechanisms and the condition that selects
between them. "Active for the block" refers to the state of an agenda for the
block being validated, computed from its ancestors as described in
#chref("voting"). Throughout this chapter, *the block* is the block being
validated and *the parent* is the block it builds on; the parent always
exists, because the genesis block is not validated (it is valid by
definition, see @sec:difficulty-genesis).

#figure(
  caption: [Difficulty mechanisms and their selection],
  table(
    columns: (auto, 1fr, 1fr, auto),
    table.header([Quantity], [Original rule], [Replacement], [Selected by]),
    [Proof-of-work hash], [BLAKE-256 of the header (identical to the block hash)], [BLAKE3 of the header], [`blake3pow` active for the block],
    [`Bits`], [EMA algorithm (@sec:difficulty-ema)], [ASERT (@sec:difficulty-asert)], [`blake3pow` active for the block],
    [`SBits`], [Version 1 (@sec:difficulty-sdiff-v1)], [Version 2 (@sec:difficulty-sdiff-v2)], [`sdiffalgorithm` active for the block],
  ),
) <tab:difficulty-algos>

@tab:difficulty-agendas summarizes how the two agendas resolved on each
network defined by dcrd. An agenda that is *forced active* is active for
every block, including block 1, without a vote. The activation heights
restate the historical anchors of @tab:voting-anchors, which are part of the
activity predicate (@rule:voting-active): dcrd consults them before any
tally of votes.

#figure(
  caption: [Status of the difficulty-related agendas per network (informative)],
  table(
    columns: (auto, 1fr, 1fr),
    table.header([Network], [`blake3pow` (#dcp(11))], [`sdiffalgorithm` (#dcp(1))]),
    [mainnet], [Voted; active from block 794368], [Voted; active from block 149248],
    [testnet3], [Voted; active from block 1170048], [Forced active],
    [simnet], [Forced active], [Forced active],
    [regnet], [Decided by vote on each regnet chain], [Decided by vote on each regnet chain],
  ),
) <tab:difficulty-agendas>

The parameters used in this chapter are collected in
@tab:difficulty-params. They are fields of the network parameters
(#chref("parameters")); values are given for all four networks because the
special cases below differ between them.

#figure(
  caption: [Difficulty parameters],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([Parameter], [mainnet], [testnet3], [simnet], [regnet]),
    [#param("PowLimit")], [$2^224 - 1$], [$2^232 - 1$], [$2^255 - 1$], [$2^255 - 1$],
    [#param("PowLimitBits")], [`0x1d00ffff`], [`0x1e00ffff`], [`0x207fffff`], [`0x207fffff`],
    [#param("TargetTimePerBlock")], [300 s], [120 s], [1 s], [1 s],
    [#param("WorkDiffWindowSize")], [144], [144], [8], [8],
    [#param("WorkDiffWindows")], [20], [20], [4], [4],
    [#param("WorkDiffAlpha")], [1], [1], [1], [1],
    [#param("TargetTimespan")], [43200 s], [17280 s], [8 s], [8 s],
    [#param("RetargetAdjustmentFactor")], [4], [4], [4], [4],
    [#param("ReduceMinDifficulty")], [false], [true], [false], [false],
    [#param("MinDiffReductionTime")], [(unused)], [600 s], [(unused)], [(unused)],
    [#param("WorkDiffV2Blake3StartBits")], [`0x1b00a5a6`], [`0x1e00ffff`], [`0x207fffff`], [`0x207fffff`],
    [#param("WorkDiffV2HalfLifeSecs")], [43200], [720], [6], [6],
    [#param("MinimumStakeDiff")], [200000000], [20000000], [20000], [20000],
    [#param("StakeDiffWindowSize")], [144], [144], [8], [8],
    [#param("StakeDiffWindows")], [20], [20], [8], [8],
    [#param("StakeDiffAlpha")], [1], [1], [1], [1],
    [#param("TicketPoolSizeWeight")], [4], [4], [4], [4],
    [#param("TicketPoolSize")], [8192], [1024], [64], [64],
    [#param("TicketsPerBlock")], [5], [5], [5], [5],
    [#param("TicketMaturity")], [256], [16], [16], [16],
    [#param("CoinbaseMaturity")], [256], [16], [16], [16],
    [#param("BaseSubsidy")], [3119582664], [2500000000], [50000000000], [50000000000],
    [#param("MulSubsidy") / #param("DivSubsidy")], [100 / 101], [100 / 101], [100 / 101], [100 / 101],
    [#param("SubsidyReductionInterval")], [6144], [2048], [128], [128],
    [Block-one subsidy (sum of #param("BlockOneLedger"))], [168000000000000], [10000000000000], [30000000000000], [30000000000000],
    [Genesis `Bits`], [`0x1b01ffff`], [`0x1e00ffff`], [`0x207fffff`], [`0x207fffff`],
    [Genesis `SBits`], [200000000], [20000000], [0], [0],
  ),
) <tab:difficulty-params>

#note[
  #param("TargetTimespan") equals #param("WorkDiffWindowSize") $times$
  #param("TargetTimePerBlock") on every network, but the EMA algorithm uses
  the parameter as given and an implementation should not derive it.
  #param("RetargetAdjustmentFactor") is shared by the EMA algorithm and
  stake difficulty version 1. Time durations are used as whole seconds.
]

=== Notation <sec:difficulty-notation>

The pseudocode follows the conventions of #xref("conv:pseudocode") in #chref("conventions"). In
addition:

- A block is represented by an object with the fields `height`,
  `timestamp`, `bits`, `sbits`, `pool_size` and `fresh_stake`, which are the
  header fields `Height`, `Timestamp`, `Bits`, `SBits`, `PoolSize` and
  `FreshStake` (#chref("encoding")), and `parent`, which is `None` for the
  genesis block. Timestamps are used as signed integers.
- `ancestor(b, h)` is the block at height `h` on the chain ending at `b`
  (`b` itself if `h = b.height`), or `None` if `h < 0`.
- `back(b, d)` is `ancestor(b, max(b.height - d, 0))`: the block `d` blocks
  before `b`, or the genesis block if `b` has fewer than `d` ancestors.
- `fdiv(a, b)` is *floor* division for `b > 0`. It is used where dcrd
  applies the Euclidean division of Go's `big.Int.Div` to a dividend that
  may be negative; for a positive divisor Euclidean division and floor
  division coincide. Where both operands are known to be non-negative, `//`
  is used.
- `>>` on a negative integer is an arithmetic shift, rounding toward
  negative infinity; dcrd's `big.Int.Rsh` behaves this way.
- `blake3pow_active_for(b)` is true if the `blake3pow` agenda is active for
  block `b`, and `blake3pow_active_for_child_of(p)` if it is active for a
  block whose parent is `p` (similarly for `sdiffalgorithm`).
  `blake3pow_forced_active` is true on a network where the agenda is forced
  active, and `is_testnet3` on testnet3.

== The Proof-of-Work Check <sec:difficulty-pow>

=== Targets and the range rule <sec:difficulty-range>

The target $T$ of a block is obtained by decoding its `Bits` field with the
compact decoding of @sec:difficulty-compact. A valid target is a positive
integer no greater than the network's #param("PowLimit"). The larger the
target, the easier the block is to mine, so #param("PowLimit") defines the
*minimum* difficulty.

#rule("Target range", src: ("internal/blockchain/validate.go · checkProofOfWorkSanity", "blockchain/standalone/pow.go · checkProofOfWorkRange"))[
  Let $T = "compact_to_big"("Bits")$ (@alg:difficulty-compact-decode),
  evaluated with unbounded signed integers. The block #MUST be rejected
  (`ErrUnexpectedDifficulty`) if $T <= 0$ or $T > $ #param("PowLimit").
  This check is context free and applies to every block other than the
  genesis block, independently of the proof-of-work hash check.
] <rule:difficulty-range>

A `Bits` value whose sign bit is set and whose mantissa decodes to a nonzero
magnitude yields $T < 0$; one whose decoded magnitude is zero (for example
`0x00000000`, `0x01003456`, or `0x01800000`) yields $T = 0$. Both are
rejected by this rule.

=== The proof-of-work hash <sec:difficulty-powhash>

The proof-of-work hash is computed over the serialized 180-byte block header
(#chref("encoding")): the same byte string from which the block hash is
computed. Two hash functions are used:

- *Version 1* is BLAKE-256 with 14 rounds @blake, as specified in
  #chref("crypto"). Its output is exactly the block hash.
- *Version 2* is BLAKE3 @blake3 with a 32-byte output and no key
  (#chref("crypto")). It is used only for the proof of work. The block hash
  remains the BLAKE-256 hash in every role (identifying the block, linking it
  to its parent, merkle and commitment structures) after the change.

The 32-byte digest is interpreted as an unsigned 256-bit integer in
*little-endian* byte order: byte 0 of the digest is the least significant
byte. Read this way, the human-readable display form of a hash
(#chref("conventions")) is the big-endian hexadecimal representation of the
integer, which is why solved hashes are displayed with leading zeros.

#rule("Proof-of-work hash", src: ("internal/blockchain/validate.go · checkProofOfWorkSanity, checkProofOfWorkContext", "blockchain/standalone/pow.go · checkProofOfWorkHash", "wire/blockheader.go · PowHashV1, PowHashV2"))[
  Let $H$ be the BLAKE3 hash of the serialized header if the `blake3pow`
  agenda is active for the block, and the BLAKE-256 hash of the serialized
  header otherwise. Let $h$ be $H$ read as a little-endian unsigned 256-bit
  integer and $T$ the target of @rule:difficulty-range. The block #MUST be
  rejected (`ErrHighHash`) if $h > T$. A hash equal to the target is valid.
] <rule:difficulty-powhash>

#note[
  dcrd applies this rule in two stages. The context-free header check, which
  cannot evaluate the agenda, accepts a header whose BLAKE-256 hash *or*
  whose BLAKE3 hash satisfies the target (and rejects one for which neither
  does). The contextual check later requires the hash selected by the agenda,
  as stated in the rule. The combined effect is exactly
  @rule:difficulty-powhash. A block that satisfies the target only with the
  other hash function is invalid, even though it passes the first stage.
]

#note[
  dcrd has a processing flag that skips the hash comparison (but not the
  range check) when it validates a block template that it built itself for
  mining. It has no effect on which blocks are valid.
]

=== The genesis block <sec:difficulty-genesis>

The genesis block of each network is hard-coded and is not subjected to any
of the rules in this chapter. Its `Bits`, `SBits` and `Timestamp` serve only
as inputs to the difficulty calculations for its descendants. In particular
the main-network genesis header does not satisfy its own target: its hash
#hex("298e5cc3d985bfe7f81dc135f360abe089edd4396b86d2de66b0cef42b21d980")
(display form) is far above the target `0x1b01ffff` encodes.

#vector[BLAKE3 proof of work (testnet3 block 1170048)][
  This is the first BLAKE3 block of testnet3, from the reference vectors of
  #dcp(11), recomputed with dcrd. Hashes are in display form except where
  marked.
  #table(
    columns: (auto, 1fr),
    table.header([Item], [Value]),
    [Serialized header (180 bytes)], [#hex("0b00000027d7ae5c9872a879b9a9da0b63915121d741e4cee3a96faea6eabf96b30000003271fd283c087219f14c7b26389fa1b22a639632d59e02e4f8e0456f36cbf740e9bba84160577d03ca9d858f07d6c78426421887cd6dc518d13fa06cfa000b5a01000b4e00a52a7705000400d4130000ffff001e9d7152e80000000080da1100e7100000085fb464f9a00f009cb73ed0429619d10000000000000000000000000000000000000000000000000b000000")],
    [`Bits`], [`0x1e00ffff` (#param("PowLimitBits") of testnet3)],
    [Target $T$], [#hex("000000ffff000000000000000000000000000000000000000000000000000000")],
    [Block hash = BLAKE-256 PoW hash], [#hex("c7da7b548a2a9463dc97adb48433c4ffff18c3873f7e2ae99338a990dae039f0")],
    [BLAKE3 PoW hash, digest bytes in order], [#hex("331e3590bd3988f55d1e69cc0163ff98e23824686ff19853e9db0530ce000000")],
    [BLAKE3 PoW hash as integer $h$ (= display form)], [#hex("000000ce3005dbe95398f16f682438e298ff6301cc691e5df58839bd90351e33")],
    [Result], [$h <= T$ with BLAKE3: valid. The BLAKE-256 value exceeds $T$, so the header would fail @rule:difficulty-powhash before activation.],
  )
]

== The Compact Target Encoding <sec:difficulty-compact>

Targets are 256-bit quantities but are carried in headers as a 32-bit
*compact* value, a base-256 floating-point format inherited from Bitcoin.
Bits 31 to 24 hold an unsigned exponent $e$, bit 23 a sign flag, and bits 22
to 0 an unsigned mantissa $m$. The encoded number is

$ N = (-1)^"sign" dot.c floor(m dot.c 256^(e - 3)) $ <eq:difficulty-compact>

so that the exponent is the length in bytes of the magnitude and the mantissa
holds its three most significant bytes. The floor matters only for $e < 3$,
where low-order mantissa bytes are discarded.

#algorithm("Compact decoding (CompactToBig)", src: "blockchain/standalone/pow.go · CompactToBig")[
  ```python
  def compact_to_big(c: uint32) -> int:
      m = c & 0x007fffff
      negative = (c & 0x00800000) != 0
      e = c >> 24
      if e <= 3:
          n = m >> (8 * (3 - e))
      else:
          n = m << (8 * (e - 3))         # may exceed 256 bits; no overflow
      return -n if negative else n
  ```
] <alg:difficulty-compact-decode>

Decoding is defined for every 32-bit value; the result can be negative, zero,
or far larger than $2^256$ (up to $(2^23 - 1) dot.c 2^2016$). An
implementation that decodes into a fixed-width unsigned 256-bit type #MUST
still reject exactly the values @rule:difficulty-range rejects: those with the
sign bit set and a nonzero decoded magnitude, those whose decoded magnitude is
zero, and those whose value exceeds #param("PowLimit") (which includes every
value that overflows 256 bits: a nonzero mantissa with exponent $>= 35$,
exponent 34 with $m >$ `0xff`, or exponent 33 with $m >$ `0xffff`).

Encoding produces the canonical compact form of a non-negative integer by
truncating it to its three most significant bytes. It is used by consensus
code only on non-negative values (every computed target is positive).

#algorithm("Compact encoding (BigToCompact) of a non-negative integer", src: "blockchain/standalone/pow.go · BigToCompact")[
  ```python
  def big_to_compact(n: int) -> uint32:      # n >= 0
      if n == 0:
          return 0
      e = (n.bit_length() + 7) // 8          # length of n in bytes
      if e <= 3:
          m = n << (8 * (3 - e))
      else:
          m = n >> (8 * (e - 3))             # truncates: discards low bytes
      if m & 0x00800000:                     # would collide with the sign bit
          m = m >> 8
          e = e + 1
      return uint32((e << 24) | m)
  ```
] <alg:difficulty-compact-encode>

The final normalization means a canonical mantissa never has bit 23 set; for
$e > 3$ it lies in the range `0x008000` to `0x7fffff`. As a consequence, for
canonical encodings of positive values the order of the 32-bit compact values
as unsigned integers is the same as the order of the targets they encode,
which some testnet rules rely on (@sec:difficulty-testnet).

#pitfall[
  The encoding is lossy and not unique. Many 32-bit values decode to the same
  target (`0x04001234` and `0x03123400` both decode to `0x123400`), and
  encoding then decoding a target generally yields a smaller number
  (`0x12345678` encodes to `0x04123456`, which decodes to `0x12345600`).
  Consensus compares *compact values*, never decoded targets: the `Bits`
  field must equal, as a 32-bit integer, the canonical encoding of the
  required target (@rule:difficulty-bits). An implementation that compares
  decoded targets instead would wrongly accept a header carrying a
  non-canonical encoding of the required target. Likewise, a computed target is always passed through
  `big_to_compact` before it is compared or reused; for example the decoded
  value of #param("PowLimitBits") is smaller than #param("PowLimit") on every
  network.
]

#note[
  dcrd's encoder also accepts negative inputs, setting the sign bit. For a
  negative input with more than three bytes it rounds the magnitude of the
  mantissa *up* rather than down (it shifts the signed value arithmetically),
  so `-0x1234567` encodes as `0x04812346`. No consensus computation encodes a
  negative value, so this has no effect on validity.
]

#vector[Compact decoding][
  #table(
    columns: (auto, 1fr, auto),
    table.header([`Bits`], [Decoded value (hexadecimal)], [Note]),
    [`0x1d00ffff`], [#hex("ffff") followed by 52 zero digits ($= "ffff" dot.c 2^208$)], [mainnet #param("PowLimitBits")],
    [`0x1b01ffff`], [#hex("1ffff000000000000000000000000000000000000000000000000")], [mainnet genesis],
    [`0x1b00a5a6`], [#hex("a5a6000000000000000000000000000000000000000000000000")], [mainnet BLAKE3 start],
    [`0x1e00ffff`], [#hex("ffff") followed by 54 zero digits], [testnet3 limit],
    [`0x207fffff`], [#hex("7fffff") followed by 58 zero digits], [simnet/regnet limit],
    [`0x00000000`, `0x00123456`, `0x01003456`], [0], [rejected],
    [`0x01123456`], [`0x12`], [low bytes dropped],
    [`0x02123456`], [`0x1234`], [],
    [`0x03123456`], [`0x123456`], [],
    [`0x04123456`], [`0x12345600`], [],
    [`0x05009234`], [`0x92340000`], [],
    [`0x04923456`], [`-0x12345600`], [sign bit; rejected],
    [`0x01810000`], [`-1`], [sign bit; rejected],
    [`0x01010000`], [`1`], [hardest valid target],
    [`0x20123456`], [#hex("123456") followed by 58 zero digits], [above every #param("PowLimit")],
  )
]

#vector[Compact encoding][
  #table(
    columns: (1fr, auto, auto),
    table.header([Input (hexadecimal)], [Encoding], [Decodes back to]),
    [`0`], [`0x00000000`], [`0`],
    [`1`], [`0x01010000`], [`1`],
    [`7f`], [`0x017f0000`], [`7f`],
    [`80`], [`0x02008000`], [`80`],
    [`ff`], [`0x0200ff00`], [`ff`],
    [`1234`], [`0x02123400`], [`1234`],
    [`123456`], [`0x03123456`], [`123456`],
    [`800000`], [`0x04008000`], [`800000`],
    [`12345678`], [`0x04123456`], [`12345600`],
    [`ffffffff`], [`0x0500ffff`], [`ffff0000`],
    [$2^224 - 1$], [`0x1d00ffff`], [$"ffff" dot.c 2^208$],
    [$2^232 - 1$], [`0x1e00ffff`], [$"ffff" dot.c 2^216$],
    [$2^255 - 1$], [`0x207fffff`], [$"7fffff" dot.c 2^232$],
    [$2^256 - 1$], [`0x2100ffff`], [$"ffff" dot.c 2^240$],
    [$2^226 - 1$], [`0x1d03ffff`], [$"3ffff" dot.c 2^208$],
  )
]

== Work and Chain Work <sec:difficulty-work>

The *work* of a block measures the expected number of hash evaluations
needed to find a header that meets its target. It is computed from the `Bits`
field alone:

#algorithm("Work of a block (CalcWork)", src: ("internal/staging/primitives/pow.go · CalcWork", "blockchain/standalone/pow.go · CalcWork"))[
  ```python
  def calc_work(bits: uint32) -> int:
      t = compact_to_big(bits)
      if t <= 0:
          return 0
      return (1 << 256) // (t + 1)
  ```
] <alg:difficulty-work>

For any target that overflows 256 bits the quotient is zero, so the result is
zero for every `Bits` value outside the valid range except targets between
#param("PowLimit") and $2^256 - 1$, which @rule:difficulty-range excludes
anyway. (dcrd's block index uses a fixed-width 256-bit implementation that
returns zero for negative, zero, and overflowing values and is otherwise
equal to this formula.)

The *cumulative work* (chain work) of a block is the sum of `calc_work` over
the block and all of its ancestors, including the genesis block. It is the
quantity by which competing chains are compared; chain selection is specified
in #chref("blocks").

#vector[Work][
  #table(
    columns: (auto, 1fr),
    table.header([`Bits`], [`calc_work` (hexadecimal)]),
    [`0x1d00ffff`], [`100010001`],
    [`0x1b01ffff`], [`800040002000`],
    [`0x1b00a5a6`], [`18ba210ed6b21`],
    [`0x1e00ffff`], [`1000100`],
    [`0x207fffff`], [`2`],
    [`0x01010000`], [#hex("8000000000000000000000000000000000000000000000000000000000000000")],
    [`0x04923456`, `0x00000000`], [`0`],
  )
]

== Required Difficulty Bits <sec:difficulty-required>

#rule("Difficulty bits", src: ("internal/blockchain/validate.go · checkBlockHeaderContext, checkDifficultyPositional", "internal/blockchain/difficulty.go · calcNextRequiredDifficulty"))[
  The `Bits` field of the block #MUST equal, as a 32-bit unsigned integer,
  the value returned by `next_required_bits(parent, timestamp)`
  (@alg:difficulty-required), where `parent` is the parent block and
  `timestamp` is the block's own `Timestamp` field. Otherwise the block
  #MUST be rejected (`ErrUnexpectedDifficulty`).
] <rule:difficulty-bits>

#algorithm("Required difficulty bits", src: "internal/blockchain/difficulty.go · calcNextRequiredDifficulty")[
  ```python
  def next_required_bits(parent, timestamp: int64) -> uint32:
      if blake3pow_active_for_child_of(parent):
          return next_bits_asert(parent)              # Algorithm "ASERT required bits"
      return next_bits_ema(parent, timestamp)         # Algorithm "EMA required bits"
  ```
] <alg:difficulty-required>

The block's own timestamp is an input only in the EMA algorithm, and only
through the testnet minimum-difficulty rule (@sec:difficulty-testnet). In all
other cases the required bits are a function of the parent chain alone.

#note[
  Before the full contextual checks, dcrd checks `Bits` while accepting every
  new header, with only the ancestor headers available, where the agenda
  state is not yet known in general. On a network where `blake3pow` is forced
  active that earlier check computes the ASERT result directly. Otherwise, if
  an anchor that dcrd has already determined from full block data is an
  ancestor of the header, it requires the ASERT result for that anchor. Failing that, it
  requires the EMA result, except that a header that is solved under BLAKE3,
  has a version of at least 10 (mainnet) or 11 (other networks), and is at a
  height of at least #param("StakeValidationHeight") $+ 2 times$
  #param("RuleChangeActivationInterval") is also accepted if its `Bits`
  matches the ASERT result for a candidate anchor: the final block of an
  earlier rule change interval, tried from the most recent backwards while
  the candidate's version is at least that same minimum and its height is at
  least #param("StakeValidationHeight") $+ 2 times$
  #param("RuleChangeActivationInterval") $- 1$. This check never rejects a
  block that satisfies @rule:difficulty-bits, @rule:difficulty-powhash and
  the block version rule of #chref("blocks"): the `blake3pow` deployment has
  version 10 on mainnet and 11 on the other networks, it can leave the
  defined state only once a majority of recent blocks has at least that
  version (#chref("voting")), and from then on the block version rule rejects
  every block with a lower version. A conforming implementation needs only
  @rule:difficulty-bits.
]

When dcrd connects the full data of a block that is an ancestor of its
assumed-valid block (#chref("blocks")), or runs in bulk-import mode, it skips
this comparison together with the stake difficulty comparison of
@rule:difficulty-sbits (the header-acceptance check of the note above still
applies to `Bits`); this is an optimization that presumes those blocks
satisfy the rules, not a relaxation of them.

== The EMA Difficulty Algorithm <sec:difficulty-ema>

The EMA algorithm is the original proof-of-work retargeting rule. It applies
to every block for which `blake3pow` is not active: on mainnet, blocks 1
to 794367.

The target changes only at *retarget blocks*, those whose height is a
multiple of #param("WorkDiffWindowSize") (144 on mainnet); every other block
must repeat its parent's `Bits` (except under the testnet rule of
@sec:difficulty-testnet). At a retarget block, the algorithm looks back over
#param("WorkDiffWindows") (20) consecutive *windows* of
#param("WorkDiffWindowSize") blocks each, ending at the parent. For each
window it measures the time the window took relative to
#param("TargetTimespan"), as a 32.32 fixed-point ratio. The ratios are
averaged with weights that double from each window to the next more recent
one, and the old target is multiplied by the average. The result is clamped
to between one quarter and four times the old target
(#param("RetargetAdjustmentFactor") $= 4$) and to at most
#param("PowLimit").

=== Windows <sec:difficulty-ema-windows>

Let the block be at height $H$, a multiple of $W =$
#param("WorkDiffWindowSize"), so the parent $P$ is at height $H - 1$. Window
$k$ (for $k = 0, ..., N - 1$, $N =$ #param("WorkDiffWindows")) is delimited by
the two blocks `back(P, k W)` (its newer end) and `back(P, (k+1) W)` (its
older end). Its time difference is the difference of their timestamps,
except that *if the older end is the genesis block* the window is taken to
have lasted exactly #param("TargetTimespan"). With `back` clamping at the
genesis block, this covers every window that reaches back to or beyond the
genesis block, including a window whose newer end is itself the genesis
block. Window $k$ has weight $2^((N - k) alpha)$ with $alpha =$
#param("WorkDiffAlpha"), so with mainnet parameters window 0 (the most
recent) has weight $2^20$ and window 19 has weight $2^1$; the weights sum to
$2^21 - 2$.

#figure(
  caption: [EMA windows for the mainnet retarget block at height $H = 144 m$],
  table(
    columns: (auto, auto, auto, auto),
    align: (right, right, right, right),
    table.header([Window $k$], [Newer end (height)], [Older end (height)], [Weight]),
    [0], [$144 m - 1$], [$144(m - 1) - 1$], [$2^20$],
    [1], [$144(m - 1) - 1$], [$144(m - 2) - 1$], [$2^19$],
    [...], [...], [...], [...],
    [19], [$144(m - 19) - 1$], [$144(m - 20) - 1$], [$2^1$],
  ),
) <tab:difficulty-ema-windows>

Heights below 0 in @tab:difficulty-ema-windows mean the genesis block. A
window's time difference may be negative if timestamps decrease; the
arithmetic below is defined for that case and uses floor division.

=== Algorithm <sec:difficulty-ema-alg>

#algorithm("EMA required bits", src: "internal/blockchain/difficulty.go · calcNextBlake256Diff, findPrevTestNetDifficulty")[
  ```python
  TESTNET3_MAX_DIFF_HEIGHT = 962928

  def next_bits_ema(parent, timestamp: int64) -> uint32:
      W, N, ALPHA = WorkDiffWindowSize, WorkDiffWindows, WorkDiffAlpha
      SPAN = TargetTimespan                      # in seconds
      RAF = RetargetAdjustmentFactor
      next_height = parent.height + 1

      if next_height % W != 0:                   # not a retarget block
          if ReduceMinDifficulty and (not is_testnet3 or
                                      next_height < TESTNET3_MAX_DIFF_HEIGHT):
              if timestamp > parent.timestamp + MinDiffReductionTime:
                  return PowLimitBits
              return last_non_min_diff_bits(parent)
          return parent.bits

      old = compact_to_big(parent.bits)
      lower = fdiv(old, RAF)
      upper = old * RAF

      weighted_sum = 0
      weights = 0
      for k in range(N):                         # k = 0 is the most recent window
          newer = back(parent, k * W)
          older = back(parent, (k + 1) * W)
          elapsed = newer.timestamp - older.timestamp
          if older.height == 0:
              elapsed = SPAN
          ratio = fdiv(elapsed << 32, SPAN)      # 32.32 fixed point, may be < 0
          weighted_sum += ratio << ((N - k) * ALPHA)
          weights += 1 << ((N - k) * ALPHA)

      target = (fdiv(weighted_sum, weights) * old) >> 32

      if old == 0:
          pass                                   # unreachable for valid chains
      elif target == 0:
          target = PowLimit
      elif target > upper:
          target = upper
      elif target < lower:
          target = lower
      if target > PowLimit:
          target = PowLimit
      if is_testnet3 and target < MIN_TESTNET_TARGET and \
              next_height >= TESTNET3_MAX_DIFF_HEIGHT:
          target = MIN_TESTNET_TARGET            # 2**226 - 1, see testnet rules
      return big_to_compact(target)

  def last_non_min_diff_bits(b) -> uint32:
      period = WorkDiffWindowSize * WorkDiffWindows
      while b is not None and b.height % period != 0 and b.bits == PowLimitBits:
          b = b.parent
      return b.bits if b is not None else PowLimitBits
  ```
] <alg:difficulty-ema>

The order of operations is significant and must be reproduced exactly:
each window ratio is floored before it is weighted; the weighted sum is
floor-divided by the sum of weights *before* multiplication by the old
target; and the product is shifted right by 32 (flooring) only at the end.
The clamping is a chain of alternatives evaluated in the order shown, of
which at most one applies, followed by the #param("PowLimit") clamp. A
computed target of exactly zero (when the floored average ratio times the
old target is below $2^32$) becomes #param("PowLimit"), whereas a negative
computed target (possible only with decreasing timestamps) falls into the
`lower` branch.

#pitfall[
  Every intermediate quantity is unbounded: `elapsed << 32` exceeds 64 bits
  for elapsed times above $2^31$ seconds, and the weighted terms grow with the
  window weights. An implementation using 64-bit integers for the ratio sum
  overflows on realistic inputs. Division of a negative weighted sum must
  floor (not truncate).
]

#pitfall[
  The retarget condition uses #param("WorkDiffWindowSize") alone (retargets
  every 144 blocks), while `last_non_min_diff_bits` stops at multiples of
  #param("WorkDiffWindowSize") $times$ #param("WorkDiffWindows") (2880
  blocks). This asymmetry is part of the testnet rule as implemented.
]

#rationale[
  Each window ratio is the factor by which the target would need to change
  to make that window last exactly #param("TargetTimespan") at the same hash
  rate. Weighting recent windows more heavily makes the estimate an
  exponentially weighted moving average over roughly the last 2880 blocks
  (10 days on mainnet), smoothing short-term hash-rate fluctuations while
  still tracking trends. Treating windows that extend before the genesis
  block as on-target lets the algorithm run unchanged from block 144.
]

#vector[EMA retargets with mainnet parameters][
  Chains of `n` blocks after the mainnet genesis block (timestamp 1454954400),
  with the stated block spacing and every block carrying the stated `Bits`.
  The result is `next_bits_ema` for the block at height `n + 1`, which is a
  retarget block in every case. For each case the block at height `n` (not a
  retarget block) required the parent's `Bits` unchanged.
  #table(
    columns: (auto, auto, auto, auto),
    table.header([`n`], [Block spacing], [Parent `Bits`], [Required `Bits`]),
    [2879], [300 s], [`0x1b01ffff`], [`0x1b01ffff`],
    [2879], [600 s], [`0x1b01ffff`], [`0x1b03fffd`],
    [5759], [600 s], [`0x1b01ffff`], [`0x1b03fffe`],
    [5759], [150 s], [`0x1b01ffff`], [`0x1b00ffff`],
    [5759], [60 s], [`0x1b01ffff`], [`0x1a7fffc0` (clamped to old/4)],
    [5759], [3000 s], [`0x1b01ffff`], [`0x1b07fffc` (clamped to old $times$ 4)],
    [143], [150 s], [`0x1b01ffff`], [`0x1b01ffff` (all windows reach genesis)],
    [287], [150 s], [`0x1b01ffff`], [`0x1b017fff`],
    [5759], [300 s; 600 s for the last 144 blocks], [`0x1b01ffff`], [`0x1b02fffe`],
    [5759], [600 s for blocks 1 to 3023; 300 s after], [`0x1b01ffff`], [`0x1b01ffff`],
    [5759], [$200 + 50 dot.c (h mod 7)$ s before block $h$], [`0x1a0f00ff`], [`0x1a1184d6`],
  )
  In the 600 s case with `n` = 2879, windows 0 to 18 each lasted 86400 s
  (ratio $2 dot.c 2^32$) and window 19 reaches the genesis block and counts as
  on target (ratio $2^32$). The weighted sum is 18014372739678208; divided by
  the weight sum $2^21 - 2$ it gives 8589930495 (`0x1ffffefff`), slightly
  below $2 dot.c 2^32$; multiplying by the old target `0x1ffff` $dot.c 2^192$
  and shifting right by 32 gives
  #hex("3fffddffe10010000000000000000000000000000000000000000"), which
  encodes to `0x1b03fffd`.
]

== ASERT <sec:difficulty-asert>

Once `blake3pow` is active, the required target is computed for every block
by ASERT ("absolutely scheduled exponentially rising targets", @asert,
#dcp(11)). ASERT fixes an *anchor block* and an ideal schedule from it: one
block every #param("TargetTimePerBlock") seconds. If the parent is $Delta t$
seconds after the anchor and $Delta h$ blocks above it, it is
$Delta t - Delta h dot.c$ #param("TargetTimePerBlock") seconds behind
schedule, and the target is set to the starting target
#param("WorkDiffV2Blake3StartBits") multiplied by $2$ raised to that delay
divided by the half-life #param("WorkDiffV2HalfLifeSecs"):

$ T = min(max(T_s dot.c 2^((Delta t - Delta h dot.c I_b) slash tau), 1), "PowLimit") $ <eq:difficulty-asert-ideal>

with $T_s$ the decoded starting target, $I_b =$ #param("TargetTimePerBlock")
and $tau =$ #param("WorkDiffV2HalfLifeSecs"). The target doubles (difficulty
halves) for every half-life the chain is behind schedule and halves for
every half-life it is ahead. @eq:difficulty-asert-ideal is the design goal;
the normative computation is the integer approximation of
@alg:difficulty-asert-core, which uses a 16-bit fixed-point exponent and a
cubic polynomial for the fractional power of two.

=== The anchor block and the difficulty reset <sec:difficulty-asert-anchor>

The anchor is determined as follows:

- *If `blake3pow` was activated by a vote* (mainnet, testnet3, and regnet
  once voted): the anchor is the last block, on the chain of the block being
  validated, for which `blake3pow` is *not* active; equivalently, the parent
  of the first block for which it is active. Because an agenda's state
  changes only at the start of a rule change interval (#chref("voting")), the
  anchor is the final block of a rule change interval. The first BLAKE3 block
  is the block immediately after the anchor; its parent is the anchor itself,
  so $Delta t = Delta h = 0$ and its required bits are exactly
  #param("WorkDiffV2Blake3StartBits") (see the vectors). The proof-of-work
  hash switches to BLAKE3 at the same block (@rule:difficulty-powhash).
- *If `blake3pow` is forced active* (simnet): block 1 must
  carry #param("WorkDiffV2Blake3StartBits"), and block 1 is the anchor for
  every later block. The genesis block is never the anchor, because its
  hard-coded timestamp is typically far in the past when mining starts.

#figure(
  caption: [ASERT anchors of the networks where the agenda was voted (informative)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Anchor height], [Anchor block hash (display form)]),
    [mainnet], [794367], [#hex("0000000000000000c293d8c67409d05e960447ea25cdaf770e864d995c764ef0")],
    [testnet3], [1170047], [#hex("000000b396bfeaa6ae6fa9e3cee441d7215191630bdaa9b979a872985caed727")],
  ),
) <tab:difficulty-anchors>

Note that the anchor's own `Bits` are not used: the difficulty is *reset*
to #param("WorkDiffV2Blake3StartBits") at activation, because a target
appropriate for specialized BLAKE-256 hardware would be unattainable with
BLAKE3. Only the anchor's height and timestamp enter the calculation.

=== Algorithm <sec:difficulty-asert-alg>

#algorithm("ASERT target calculation (CalcASERTDiff)", src: "blockchain/standalone/pow.go · CalcASERTDiff")[
  ```python
  POLY_C1 = 195766423245049     # ceil(0.695502049712533 * 2**48)
  POLY_C2 = 971821376           # ceil(0.2262697964 * 2**32)
  POLY_C3 = 5127                # ceil(0.0782318 * 2**16)

  def asert(start_bits: uint32, pow_limit: int, block_secs: int,
            dt: int, dh: int, half_life: int) -> uint32:
      start = compact_to_big(start_bits)
      assert 0 < start <= pow_limit and dh >= 0       # guaranteed by callers

      # Exponent in 16.16 fixed point, truncated toward zero.
      x = tdiv((dt - dh * block_secs) << 16, half_life)
      n = x >> 16                  # integer part: arithmetic shift (floor)
      f = x & 0xffff               # fractional part, 0 <= f < 2**16

      # 2**16 * 2**(f / 2**16), cubic approximation, 16.48 fixed point inside.
      factor = (1 << 16) + ((POLY_C1 * f + POLY_C2 * f * f +
                             POLY_C3 * f * f * f + (1 << 47)) >> 48)

      target = start * factor
      s = n - 16
      if s >= 0:
          target = target << s
      else:
          target = target >> -s    # floor
      if target == 0:
          target = 1
      elif target > pow_limit:
          target = pow_limit
      return big_to_compact(target)
  ```
] <alg:difficulty-asert-core>

#algorithm("ASERT required bits", src: "internal/blockchain/difficulty.go · calcNextBlake3Diff, calcNextBlake3DiffFromAnchor, blake3WorkDiffAnchor")[
  ```python
  MIN_TESTNET_BITS = 0x1d03ffff             # big_to_compact(MIN_TESTNET_TARGET)

  def next_bits_asert(parent) -> uint32:
      if blake3pow_forced_active:
          if parent.height == 0:
              return WorkDiffV2Blake3StartBits
          anchor = ancestor(parent, 1)
      else:
          # Last block on this chain for which blake3pow is not active.
          anchor = parent
          while blake3pow_active_for(anchor):
              anchor = anchor.parent
      dt = parent.timestamp - anchor.timestamp      # may be negative
      dh = parent.height - anchor.height            # >= 0
      bits = asert(WorkDiffV2Blake3StartBits, PowLimit, TargetTimePerBlock,
                   dt, dh, WorkDiffV2HalfLifeSecs)
      if is_testnet3 and bits < MIN_TESTNET_BITS:   # unsigned 32-bit comparison
          bits = MIN_TESTNET_BITS
      return bits
  ```
] <alg:difficulty-asert>

dcrd locates the anchor by stepping back one rule change interval at a time
from the final block of the interval preceding the block, testing only those
interval-final blocks, and caches the result; because the agenda state can
change only at interval boundaries, the block-by-block loop in
@alg:difficulty-asert finds the same block. If `blake3pow` is active for the
block but not for its parent, the anchor is the parent. The loop always
terminates before the genesis block, since an agenda activated by vote is
never active for block 1.

#pitfall[
  The exponent uses *truncating* division (toward zero), but its integer
  part uses *flooring* (an arithmetic shift) and its fractional part is the
  non-negative remainder modulo $2^16$, so that $x = 2^16 n + f$ exactly. For
  example $Delta t = 299$, $Delta h = 1$ on mainnet gives
  $x = "tdiv"(-65536, 43200) = -1$, hence $n = -1$ and $f = 65535$; floor
  division would give $x = -2$ and a different result. A logical (unsigned)
  shift for $n$ is also wrong.
]

#pitfall[
  The polynomial numerator needs the full unsigned 64-bit range: at
  $f = 65535$ it equals 18446563080438344768, just below $2^64$. It is always
  positive and the resulting factor is at most 17 bits ($2^16 <= "factor" <
  2^17$). In the final step the shift amount $n - 16$ is unbounded in
  principle; for consensus inputs ($Delta h < 2^32$, timestamps 32-bit) the
  exponent stays far inside the 64-bit range, but the target before clamping
  can exceed 256 bits (on testnet3, whose half-life is 720 seconds, by more
  than a thousand bits for a chain stalled for two weeks).
  An implementation may clamp early, provided the result is identical: any
  left shift by at least the bit length of #param("PowLimit") yields
  #param("PowLimit"), and any right shift by at least the bit length of
  `start * factor` yields 1.
]

#pitfall[
  The testnet3 lower bound in @alg:difficulty-asert compares the 32-bit
  compact values, not targets. Because `asert` returns a canonical encoding
  of a positive target, this ordering agrees with the ordering of the
  targets (@sec:difficulty-compact).
]

#rationale[
  An absolutely scheduled algorithm measures the cumulative deviation from
  the ideal schedule since a fixed point, so errors do not accumulate and
  there are no windows whose boundaries a miner could exploit. Using a fixed
  anchor makes each target an exact function of two numbers, which is
  cheaper to compute and to verify than a windowed average. The polynomial
  approximates $2^x$ on $[0, 1)$ with a relative error below 0.013%, and
  integer arithmetic keeps the result identical across implementations.
]

#vector[ASERT with mainnet parameters][
  Start bits `0x1b00a5a6`, #param("PowLimit") $= 2^224 - 1$, block time 300,
  half-life 43200. `dt` and `dh` are the deltas of the parent from the
  anchor.
  #table(
    columns: (auto, auto, auto, 1fr),
    table.header([`dt`], [`dh`], [Result], [Comment]),
    [0], [0], [`0x1b00a5a6`], [first BLAKE3 block],
    [300], [1], [`0x1b00a5a6`], [on schedule],
    [299], [1], [`0x1b00a5a5`], [$x = -1$, $n = -1$, $f = 65535$, factor 131071],
    [301], [1], [`0x1b00a5a6`], [$x = 1$, $n = 0$, $f = 1$, factor 65537],
    [1], [0], [`0x1b00a5a6`], [],
    [-1], [0], [`0x1b00a5a5`], [],
    [43200], [0], [`0x1b014b4c`], [one half-life behind: target doubles],
    [-43200], [0], [`0x1a52d300`], [one half-life ahead: target halves],
    [21600], [0], [`0x1b00ea3e`], [$x = 32768$, factor 92674],
    [-21600], [0], [`0x1a751f03`], [$x = -32768$, $n = -1$, $f = 32768$],
    [86400], [144], [`0x1b014b4c`], [],
    [86400], [0], [`0x1b029698`], [],
    [0], [144], [`0x1a52d300`], [],
    [0], [288], [`0x1a296980`], [],
    [172800], [288], [`0x1b029698`], [],
    [864000], [0], [`0x1d00ffff`], [clamped to #param("PowLimit")],
    [-1728000], [0], [`0x1600a5a6`], [40 half-lives ahead],
    [-4320000], [0], [`0x0e0a5a60`], [100 half-lives ahead],
    [-8942400], [0], [`0x01010000`], [207 half-lives ahead: the shift leaves exactly 1],
    [-8985600], [0], [`0x01010000`], [208 half-lives ahead: the shift leaves 0, clamped to 1],
  )
]

#vector[ASERT reference vectors of DCP-0011 (excerpt)][
  From the test vector file shipped with dcrd and #dcp(11)\; mainnet
  parameters, anchor height 0 and anchor time as stated. dcrd reproduces all
  of them.
  #table(
    columns: (auto, auto, auto, auto, auto),
    table.header([Start bits], [Anchor time], [Height], [Timestamp], [Result]),
    [`0x1d00ffff`], [0], [1], [691200], [`0x1d00ffff`],
    [`0x1d00ffff`], [0], [6], [11793600], [`0x1d00ffff`],
    [`0x1b00a5a6`], [0], [4], [1199], [`0x1b00a5a5`],
    [`0x1b00a5a6`], [300], [1], [299], [`0x1b00a4da`],
    [`0x1b00a5a6`], [300], [6], [294], [`0x1b00a0ed`],
    [`0x01010000`], [0], [1], [43500], [`0x01020000`],
    [`0x01010000`], [0], [7], [304500], [`0x02008000`],
  )
]

#vector[ASERT with testnet3 parameters and the testnet3 bound][
  Start bits `0x1e00ffff`, #param("PowLimit") $= 2^232 - 1$, block time 120,
  half-life 720.
  #table(
    columns: (auto, auto, auto, auto),
    table.header([`dt`], [`dh`], [`asert` result], [Required bits]),
    [0], [0], [`0x1e00ffff`], [`0x1e00ffff`],
    [1200], [10], [`0x1e00ffff`], [`0x1e00ffff`],
    [600], [10], [`0x1e008faf`], [`0x1e008faf`],
    [-720], [0], [`0x1d7fff80`], [`0x1d7fff80`],
    [-7200], [0], [`0x1c3fffc0`], [`0x1d03ffff` (testnet3 bound)],
  )
]

== Test Network Rules <sec:difficulty-testnet>

Version 3 of the test network (testnet3) has rules that keep it usable with
ordinary hardware. They are selected by the network identity (the
`TestNet3` network magic), not by a parameter, except for the
minimum-difficulty rule, which is selected by #param("ReduceMinDifficulty")
and limited on testnet3 by height. On testnet3, `MIN_TESTNET_TARGET` is
#param("PowLimit") shifted right by 6 bits, $2^226 - 1$ (a maximum
difficulty of $2^6 = 64$ relative to the limit), and `MIN_TESTNET_BITS`
$=$ `big_to_compact(MIN_TESTNET_TARGET)` $=$ `0x1d03ffff`. The threshold
height is 962928.

/ Minimum-difficulty blocks: On a network with #param("ReduceMinDifficulty")
  set (only testnet3 among dcrd's networks), for a block that is not an EMA
  retarget block and, on testnet3, whose height is below 962928: if its
  timestamp is more than #param("MinDiffReductionTime") (600 s) after its
  parent's timestamp, the required bits are #param("PowLimitBits")\;
  otherwise they are the bits of the most recent ancestor (starting with the
  parent) that does not carry #param("PowLimitBits"), stopping at the first
  block whose height is a multiple of #param("WorkDiffWindowSize") $times$
  #param("WorkDiffWindows") (@alg:difficulty-ema). Retarget blocks are never
  minimum-difficulty blocks, and the retarget calculation uses the parent's
  `Bits` as the old target even if it is #param("PowLimitBits"). The rule
  never applies to ASERT.
/ Maximum difficulty: On testnet3, from height 962928 on, an EMA retarget
  result below `MIN_TESTNET_TARGET` is replaced by `MIN_TESTNET_TARGET`
  before encoding, and an ASERT result whose compact value is below
  `MIN_TESTNET_BITS` is replaced by `MIN_TESTNET_BITS` (at all heights;
  ASERT begins above 962928 on testnet3). Both forms produce the same
  compact result for every target, because every target between the decoded
  value of `0x1d03ffff` and $2^226 - 1$ encodes to `0x1d03ffff`.
/ Block spacing and checkpoint: @rule:difficulty-testnet-checkpoint and
  @rule:difficulty-testnet-spacing below.

#rule("Testnet3 maximum-difficulty checkpoint", src: "internal/blockchain/validate.go · checkBlockHeaderPositional")[
  On testnet3, a block at height 962928 whose block hash is not the hash
  below (display form) #MUST be rejected (`ErrBadMaxDiffCheckpoint`):
  #hex("0000004fd1b267fd39111d456ff557137824538e6f6776168600e56002e23b93")
] <rule:difficulty-testnet-checkpoint>

#rule("Testnet3 minimum block spacing at maximum difficulty", src: "internal/blockchain/validate.go · checkBlockHeaderPositional")[
  On testnet3, a block at height 962928 or above whose `Bits`, compared as an
  unsigned 32-bit integer, is less than or equal to `0x1d03ffff` #MUST have
  a timestamp at least 60 seconds after its parent's timestamp (equality
  allowed); otherwise it #MUST be rejected (`ErrTimeTooOld`).
] <rule:difficulty-testnet-spacing>

#history[
  The testnet3 maximum-difficulty rules were introduced at height 962928.
  dcrd invalidates, at startup, any stored testnet3 chain whose block at that
  height is not the checkpoint block, which has the same effect as
  @rule:difficulty-testnet-checkpoint for chains received before the rule
  existed.
]

== Stake Difficulty <sec:difficulty-stake>

The stake difficulty is the ticket price: the minimum value, in atoms, of the
stake submission output (output 0) of every ticket purchase in a block. It is
carried in the header field `SBits`, an `int64`. Like the proof-of-work
target it is recomputed only at *stake retarget blocks*, those whose height
is a multiple of #param("StakeDiffWindowSize") (144 blocks on mainnet), and
every other block repeats its parent's value. The ticket structure, the
ticket pool and the header fields `PoolSize` (the number of live tickets)
and `FreshStake` (the number of ticket purchases in the block) are specified
in #chref("staking").

#rule("Stake difficulty", src: ("internal/blockchain/validate.go · checkBlockHeaderContext", "internal/blockchain/difficulty.go · calcNextRequiredStakeDifficulty"))[
  The `SBits` field of the block #MUST equal `next_required_sbits(parent)`
  (@alg:difficulty-sdiff), where `parent` is the parent block. Otherwise the
  block #MUST be rejected (`ErrUnexpectedDifficulty`).
] <rule:difficulty-sbits>

The `SBits` field is in turn the minimum price of every ticket in the block:
@rule:staking-ticket-price requires output 0 of each ticket purchase in the
stake tree to be worth at least the block's `SBits` and at least
#param("MinimumStakeDiff").

#algorithm("Required stake difficulty", src: "internal/blockchain/difficulty.go · calcNextRequiredStakeDifficulty")[
  ```python
  def next_required_sbits(parent) -> int64:
      if sdiffalgorithm_active_for_child_of(parent):
          return next_sbits_v2(parent)
      return next_sbits_v1(parent)
  ```
] <alg:difficulty-sdiff>

Both versions share the retarget schedule and carry the parent's value
forward between retargets. They differ by one block in their start-up rule:
version 1 returns #param("MinimumStakeDiff") whenever the *parent's* height
is at most #param("CoinbaseMaturity"), version 2 whenever the *block's*
height is at most #param("CoinbaseMaturity"). Before
#param("CoinbaseMaturity") $+ 1$ no output exists that could fund a ticket.

#note[
  On mainnet the `sdiffalgorithm` agenda became active at block 149248, which
  is not a stake retarget block ($149248 = 1036 times 144 + 64$). Blocks
  149248 to 149327 therefore carry forward the value computed by version 1
  for block 149184, and block 149328 is the first to be computed by version
  2, from that carried-forward value. No other transition step exists.
]

=== Version 1 <sec:difficulty-sdiff-v1>

Version 1 computes two independent estimates of the new price, each a
weighted moving average over #param("StakeDiffWindows") windows of
#param("StakeDiffWindowSize") blocks in the style of the EMA algorithm, and
combines them:

- The *pool-size estimate* compares the live ticket pool size, sampled once
  per window, with the target pool size $"TicketsPerBlock" times
  "TicketPoolSize"$ (40960 on mainnet). Deviations are amplified by
  #param("TicketPoolSizeWeight").
- The *fresh-stake estimate* compares the number of tickets bought in each
  window with $"StakeDiffWindowSize" times "TicketsPerBlock"$ (720 on
  mainnet).

Each estimate is clamped to a factor of #param("RetargetAdjustmentFactor")
around the old price, the two are combined multiplicatively, the result is
clamped again, and finally raised to at least #param("MinimumStakeDiff").

For a stake retarget block at height $H = 144 m$ with mainnet parameters, the
pool-size estimate uses the `PoolSize` of the blocks at heights
$144(m - 1 - k)$ for $k = 0, ..., 19$ (the first block of each of the last
20 intervals), and the fresh-stake estimate sums `FreshStake` over the
complete intervals $[144(m - 1 - k), 144(m - k) - 1]$. Window $k$ has weight
$2^((20 - k) alpha)$ with $alpha =$ #param("StakeDiffAlpha") $= 1$. Blocks
before the genesis block are replaced by the genesis block (whose
`PoolSize` and `FreshStake` are 0 on every network); in the fresh-stake sum,
a window extending before the genesis block therefore counts the genesis
block repeatedly.

#algorithm("Stake difficulty version 1", src: "internal/blockchain/difficulty.go · calcNextRequiredStakeDifficultyV1, mergeDifficulty")[
  ```python
  def next_sbits_v1(parent) -> int64:
      SW, SN, ALPHA = StakeDiffWindowSize, StakeDiffWindows, StakeDiffAlpha
      RAF = RetargetAdjustmentFactor
      if parent.height < CoinbaseMaturity + 1:
          return MinimumStakeDiff
      old = parent.sbits
      if (parent.height + 1) % SW != 0:
          return old
      if old == 0:
          return 0                                # unreachable for valid chains

      # Pool-size estimate.
      target_pool = TicketsPerBlock * TicketPoolSize
      weighted_sum, weights = 0, 0
      for k in range(SN):
          b = back(parent, (k + 1) * SW - 1)
          skew = (b.pool_size - target_pool) * TicketPoolSizeWeight + target_pool
          if skew <= 0:
              skew = 1
          ratio = (skew << 32) // target_pool
          weighted_sum += ratio << ((SN - k) * ALPHA)
          weights += 1 << ((SN - k) * ALPHA)
      by_pool = int64(((weighted_sum // weights) * old) >> 32)
      by_pool = clamp_v1(old, by_pool)

      # Fresh-stake estimate.
      target_fresh = SW * TicketsPerBlock
      weighted_sum, weights = 0, 0
      for k in range(SN):
          fresh = 0
          for d in range(k * SW, (k + 1) * SW):
              fresh += back(parent, d).fresh_stake
          if fresh <= 0:
              fresh = 1
          ratio = (fresh << 32) // target_fresh
          weighted_sum += ratio << ((SN - k) * ALPHA)
          weights += 1 << ((SN - k) * ALPHA)
      by_fresh = int64(((weighted_sum // weights) * old) >> 32)
      by_fresh = clamp_v1(old, by_fresh)

      nxt = clamp_v1(old, merge(old, by_pool, by_fresh))
      if nxt < MinimumStakeDiff:
          return MinimumStakeDiff
      return nxt

  def clamp_v1(old: int64, x: int64) -> int64:   # old > 0, x >= 0
      if x == 0:
          return old // RetargetAdjustmentFactor
      if x // old > RetargetAdjustmentFactor - 1:
          return old * RetargetAdjustmentFactor
      if old // x > RetargetAdjustmentFactor - 1:
          return old // RetargetAdjustmentFactor
      return x

  def merge(old: int64, d1: int64, d2: int64) -> int64:   # all > 0
      a = (old << 32) // d1
      b = (d2 << 32) // old
      return int64((((b << 32) // a) * old) >> 32)
  ```
] <alg:difficulty-sdiff-v1>

`merge` computes approximately $d_1 d_2 slash "old"$: the product of the two
estimated change factors applied to the old price. All divisions in version
1 are of non-negative operands. The `int64` conversions take the value
modulo $2^64$ as two's complement; for every reachable input the values fit,
so the conversion has no effect. (Wrapping requires a price far above the
total supply. dcrd also evaluates `clamp_v1` in 64-bit
arithmetic, and the pseudocode above does not describe its results in that
unreachable range, where the estimates can wrap to negative values.) The clamp conditions are integer
comparisons of truncated quotients: `x // old > RAF - 1` holds exactly when
$x >= "RAF" dot.c "old"$, and `old // x > RAF - 1` exactly when
$"old" >= "RAF" dot.c x$.

#pitfall[
  The early return for `old == 0` reproduces dcrd, which returns the
  (necessarily zero) pool-size estimate when the old price is zero. `merge`
  divides by `d1`, `old` and `a`; these are nonzero because a valid chain's
  price is at least #param("MinimumStakeDiff"), which exceeds
  #param("RetargetAdjustmentFactor") on every network. dcrd would fail on a
  zero divisor rather than reject the block.
]

#vector[Stake difficulty version 1, mainnet parameters][
  Chains of 5759 blocks in which every block has the stated `PoolSize` and
  `FreshStake` and `SBits` 5000000000; the result is the required `SBits` of
  block 5760.
  #table(
    columns: (auto, auto, auto, 1fr),
    table.header([`PoolSize`], [`FreshStake`], [Result], [Comment]),
    [40960], [5], [5000000000], [both estimates on target],
    [45056], [5], [6999999999], [skew $= 4096 times 4 + 40960$: factor 1.4],
    [36864], [5], [2999999998], [factor 0.6],
    [40960], [20], [20000000000], [fresh estimate clamped to $times 4$],
    [40960], [0], [1250000000], [fresh estimate clamped to $div 4$],
    [0], [0], [1250000000], [],
    [41779], [10], [10799804684], [],
  )
  `merge(5000000000, 6000000000, 4000000000)` $= 4799999998$; \
  `merge(200000000, 800000000, 800000000)` $= 3200000000$.
]

=== Version 2 (DCP-0001) <sec:difficulty-sdiff-v2>

Version 2 adjusts the price in proportion to two ratios: the relative change
of the pool size (including immature tickets) since the previous retarget,
and the ratio of the current pool size to its target. With $S$ the current
price, $P_N$ and $P_(N-1)$ the current and previous pool sizes including
immature tickets, and $T_P = "TicketsPerBlock" times ("TicketPoolSize" +
"TicketMaturity")$ (42240 on mainnet):

$ S' = max(min(floor((S dot.c P_N^2) / (P_(N-1) dot.c T_P)), S_"ub"), S_"lb") $

where $S_"lb" =$ #param("MinimumStakeDiff") and $S_"ub"$ is an estimate of
the total supply divided by #param("TicketPoolSize"). The normative
computation, including the order in which the bounds are applied, is
@alg:difficulty-sdiff-v2.

The pool size including immature tickets "as of" a block $b$ is
$b."pool_size"$ plus the `FreshStake` of $b$ and of its
#param("TicketMaturity") $- 1$ nearest ancestors (#param("TicketMaturity")
blocks in total, fewer if the genesis block is reached). For a retarget
block at height $H$, the current value is taken as of the parent (height
$H - 1$) and the previous value as of the block at height
$H - "StakeDiffWindowSize" - 1$, the parent of the previous retarget block.
The `PoolSize` header field counts live tickets only and does not yet include
tickets that mature in that very block (#chref("staking")); the formula uses
the header values as they are.

#algorithm("Stake difficulty version 2", src: "internal/blockchain/difficulty.go · calcNextRequiredStakeDifficultyV2, calcNextStakeDiffV2, sumPurchasedTickets, estimateSupply")[
  ```python
  def next_sbits_v2(parent) -> int64:
      next_height = parent.height + 1
      if next_height < CoinbaseMaturity + 1:
          return MinimumStakeDiff
      cur = parent.sbits
      if next_height % StakeDiffWindowSize != 0:
          return cur

      prev_node = ancestor(parent, next_height - StakeDiffWindowSize - 1)
      prev_all = 0
      if prev_node is not None:
          prev_all = prev_node.pool_size + sum_fresh(prev_node, TicketMaturity)
      if prev_all == 0:
          return cur                     # avoids division by zero at start-up
      cur_all = parent.pool_size + sum_fresh(parent, TicketMaturity)

      target_all = TicketsPerBlock * (TicketPoolSize + TicketMaturity)
      nxt = int64((cur * cur_all * cur_all) // prev_all // target_all)
      maximum = estimate_supply(next_height) // TicketPoolSize
      if nxt > maximum:
          nxt = maximum
      if nxt < MinimumStakeDiff:
          nxt = MinimumStakeDiff
      return nxt

  def sum_fresh(b, count: int) -> int:
      total = 0
      while b is not None and count > 0:
          total += b.fresh_stake
          b = b.parent
          count -= 1
      return total

  def estimate_supply(height: int64) -> int64:
      if height <= 0:
          return 0
      I = SubsidyReductionInterval
      supply = BLOCK_ONE_SUBSIDY        # sum of the BlockOneLedger amounts
      subsidy = BaseSubsidy
      for _ in range(height // I):
          supply += I * subsidy
          subsidy = subsidy * MulSubsidy // DivSubsidy
      supply += (1 + height % I) * subsidy
      supply -= BaseSubsidy * 2         # blocks 0 and 1 were counted at full subsidy
      return supply
  ```
] <alg:difficulty-sdiff-v2>

The numerator is formed first and divided by `prev_all` and then by
`target_all`, each time with flooring; since all operands are non-negative
this equals a single floored division by their product. The maximum is
applied before the minimum, so when the supply-based maximum is below
#param("MinimumStakeDiff") the minimum prevails. (#dcp(1) writes the bounds in
the opposite nesting; the difference is unobservable on dcrd's networks,
where the maximum exceeds the minimum at every height at which a retarget can
occur, and dcrd's order is normative.) `estimate_supply` is evaluated at the
height of the block being validated. It is a deliberately simplified model of
issuance that assumes every block paid its full subsidy; it does not account
for missing votes, disapproved blocks, or changes in the subsidy split, which
do not alter the total block subsidy.

#pitfall[
  The product `cur * cur_all * cur_all` can exceed 64 bits on realistic
  inputs (for example $2 times 10^(10) times 72845^2 approx 10^(20)$) and
  #MUST be computed with wider arithmetic. The quotient is then converted to
  `int64` modulo $2^64$, as with version 1; it fits for every reachable
  input.
]

#vector[Supply estimate, mainnet parameters][
  #table(
    columns: (auto, auto, auto),
    align: (right, right, right),
    table.header([Height], [`estimate_supply`], [Maximum price (`// 8192`)]),
    [0 (and negative)], [0], [0],
    [1], [168000000000000], [20507812500],
    [2], [168003119582664], [20508193308],
    [4096], [180774691009080], [22067223023],
    [6143], [187160476722288], [22846737881],
    [6144], [187163565417994], [22847114919],
    [149248], [583636569410475], [71244698414],
    [794368], [1569076628758532], [191537674409],
  )
]

#vector[Stake difficulty version 2, mainnet parameters][
  A chain from dcrd's tests: no purchases in blocks 1 to 256, then 20 ticket
  purchases in every block, with no votes before block 4096 and 5 per block
  from 4096. Each row is a retarget block; "prev" and "cur" are pool sizes and
  immature counts as defined above.
  #table(
    columns: (auto, auto, auto, auto, auto, auto, auto),
    align: (right, right, right, right, right, right, right),
    table.header([Height], [Parent `SBits`], [Prev pool], [Prev imm.], [Cur pool], [Cur imm.], [Result]),
    [2304], [200000000], [32920], [5120], [35800], [5120], [208418769],
    [2448], [208418769], [35800], [5120], [38680], [5120], [231326567],
    [2592], [231326567], [38680], [5120], [41560], [5120], [272451490],
    [3456], [1354989669], [55960], [5120], [58840], [5120], [2148473276],
    [4032], [10947547379], [67480], [5120], [70360], [5120], [20338554623],
    [4176], [20338554623], [70360], [5120], [72845], [5120], [22097687698],
  )
  For example, at height 2304: $"prev_all" = 32920 + 5120 = 38040$ and
  $"cur_all" = 35800 + 5120 = 40920$; $200000000 dot.c 40920^2 =
  334889280000000000$; divided by 38040 this gives 8803608832807, and divided
  by 42240 it gives 208418769, which is within the bounds. The last row
  (height 4176) is the only one that is clamped to the maximum: the
  unclamped value 38776057578 exceeds the estimated supply divided by the
  target pool size, 22097687698.
]

#note[
  dcrd also provides an estimate of the next stake difficulty for wallets,
  which simulates the remaining blocks of the interval under assumed
  purchase counts. It is not part of consensus.
]

== Summary of Header Rules <sec:difficulty-summary>

For every block other than the genesis block:

+ `Bits` decodes to a target in $[1, "PowLimit"]$ (@rule:difficulty-range).
+ The proof-of-work hash selected by `blake3pow` does not exceed the target
  (@rule:difficulty-powhash).
+ `Bits` equals the required bits computed from the parent chain and the
  block's timestamp by the EMA algorithm or ASERT (@rule:difficulty-bits).
+ `SBits` equals the required stake difficulty computed from the parent chain
  by version 1 or version 2 (@rule:difficulty-sbits).
+ Every ticket purchase pays at least `SBits` and at least
  #param("MinimumStakeDiff") (@rule:staking-ticket-price).
+ On testnet3 only: @rule:difficulty-testnet-checkpoint and
  @rule:difficulty-testnet-spacing.
