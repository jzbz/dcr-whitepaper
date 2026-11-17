#import "../template.typ": *

= Issuance and Block Subsidy <ch:subsidy>

New decred enters existence in exactly two ways: through the *block-one
ledger*, a fixed list of payments made by the coinbase transaction of the block
at height 1, and through the *block subsidy*, an amount created by every later
block and divided between the proof-of-work miner, the stakeholders whose votes
the block contains, and the project treasury. Transaction fees are not new
money; they move existing atoms from transaction inputs to the miner.

This chapter specifies the subsidy schedule (the *full block subsidy* as a
function of height and its periodic reduction), the three-way split of that
subsidy and the two changes made to the split by stakeholder vote
(#dcp(10), #dcp(12)), the coinbase transaction that pays the proof-of-work
share, the amount checks on the stake tree that pay the vote and treasury
shares, the block-one ledger, and the resulting total supply. The formats of
votes and of the treasurybase transaction are specified in #chref("staking")
and #chref("treasury")\; this chapter fixes only the amounts they carry.

All arithmetic in this chapter is on non-negative `int64` values, and every
division truncates. The order of the multiplications and divisions is part of
the consensus rules: reordering them, or replacing an iterated computation by
a closed form, changes results by a few atoms and splits the chain.

== Overview <sec:subsidy-overview>

@tab:subsidy-flows summarizes who receives each part of the subsidy, which
transaction carries it, and how its amount depends on the block. The
quantities named there are defined in @sec:subsidy-full and
@sec:subsidy-split.

#figure(
  caption: [Where each share of the subsidy of the block at height $h$ is paid],
  table(
    columns: (auto, auto, 1fr),
    table.header([Share], [Carried by], [Amount and dependencies]),
    [Block-one ledger], [Coinbase of block 1], [The fixed list of outputs in #param("BlockOneLedger")\; paid only at $h = 1$ (@sec:subsidy-ledger).],
    [Proof of work], [Coinbase (regular tree)], [$W(h, v)$: the work proportion of $S(h)$, scaled by the number of votes $v$ in the block from #param("StakeValidationHeight") on. Lost if the next block disapproves this block's regular tree.],
    [Votes], [Stakebase input of each vote (stake tree)], [$V(h - 1)$ per vote: the vote proportion of $S(h - 1)$, divided by #param("TicketsPerBlock"). Based on the height of the block *voted on*, not the block containing the vote. Not scaled by $v$.],
    [Treasury, before the `treasury` agenda], [Output 0 of the coinbase], [$T(h, v)$: one tenth of $S(h)$, scaled by $v$ from #param("StakeValidationHeight") on. Lost if the block is disapproved.],
    [Treasury, after the `treasury` agenda], [Treasurybase (first stake transaction)], [$T(h)$: one tenth of $S(h)$, not scaled by $v$. Unaffected by disapproval.],
  ),
) <tab:subsidy-flows>

@tab:subsidy-params lists the parameters and constants used. The full
per-network tables are in #chref("parameters")\; @tab:subsidy-networks
summarizes the subsidy-related values of all four networks because the derived
quantities given there (block-one subsidy, final subsidy interval) are
computed in this chapter.

#figure(
  caption: [Parameters and constants of the subsidy rules (main-network values)],
  table(
    columns: (auto, 27%, 1fr),
    table.header([Name], [Value], [Meaning]),
    [#param("BaseSubsidy")], [3119582664], [Full subsidy, in atoms, of every block in the first reduction interval (except blocks 0 and 1).],
    [#param("MulSubsidy")], [100], [Reduction multiplier.],
    [#param("DivSubsidy")], [101], [Reduction divisor.],
    [#param("SubsidyReductionInterval")], [6144], [Length of a reduction interval in blocks.],
    [#param("WorkRewardProportion")], [6], [Proof-of-work proportion of the original split.],
    [#param("StakeRewardProportion")], [3], [Vote proportion of the original split.],
    [#param("BlockTaxProportion")], [1], [Treasury proportion (all eras).],
    [#param("TicketsPerBlock")], [5], [Maximum number of votes per block; the divisor in all vote scaling.],
    [#param("StakeValidationHeight")], [4096], [First height whose blocks must contain votes.],
    [#param("CoinbaseMaturity")], [256], [Blocks before coinbase outputs may be spent (#chref("transactions")).],
    [#param("OrganizationPkScript")], [#hex("a914f5916158e3e2c4551c1796708db8367207ed13bb87")], [Script that coinbase output 0 must pay before the `treasury` agenda (a pay-to-script-hash script).],
    [#param("OrganizationPkScriptVersion")], [0], [Required script version of that output.],
    [#param("BlockOneLedger")], [3146 entries], [Required outputs of the block-one coinbase (@sec:subsidy-ledger).],
    [#const("MinCoinbaseScriptLen")], [2], [Minimum coinbase signature script length in bytes.],
    [#const("MaxCoinbaseScriptLen")], [100], [Maximum coinbase signature script length in bytes.],
    [#const("maxUniqueCoinbaseNullDataSize")], [256], [Maximum length of the data pushed by the coinbase height commitment.],
  ),
) <tab:subsidy-params>

Two derived quantities are used throughout. With $N$ =
#param("TicketsPerBlock"),

$ P = #param("WorkRewardProportion") + #param("StakeRewardProportion") + #param("BlockTaxProportion") = 10 $ <eq:subsidy-derived>

is the denominator of the original split and of the treasury share in every
era, and

$ m = floor(N / 2) + 1 = 3 $ <eq:subsidy-minvotes>

is the minimum number of votes a block at or above
#param("StakeValidationHeight") must contain (enforced in #chref("staking")).

#figure(
  caption: [Subsidy parameters and derived quantities on each network],
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    table.header([Network], [#param("BaseSubsidy")], [Interval], [#param("StakeValidationHeight")], [Block-one subsidy], [First zero-subsidy height]),
    [mainnet], [3119582664], [6144], [4096], [168000000000000], [11010048 (interval 1792)],
    [testnet3], [2500000000], [2048], [768], [10000000000000], [3622912 (interval 1769)],
    [simnet], [50000000000], [128], [144], [30000000000000], [265088 (interval 2071)],
    [regnet], [50000000000], [128], [144], [30000000000000], [265088 (interval 2071)],
  ),
) <tab:subsidy-networks>

All four networks use #param("MulSubsidy") $= 100$, #param("DivSubsidy")
$= 101$, proportions 6, 3 and 1, and #param("TicketsPerBlock") $= 5$.

#note[
  `chaincfg.Params` also carries fields named `WorkRewardProportionV2` (1) and
  `StakeRewardProportionV2` (8). They are deprecated and are not read by the
  consensus code: the proportions of the modified splits are fixed constants
  (@tab:subsidy-variants), the same on every network. (The fields
  #param("WorkRewardProportion") and #param("StakeRewardProportion") carry the
  same deprecation notice in dcrd but are read: they define the original
  split.)
]

== The Full Block Subsidy <sec:subsidy-full>

The *full block subsidy* $S(h)$ is the total amount a block at height $h$ may
create before it is divided into shares. It is constant within a *reduction
interval* of #param("SubsidyReductionInterval") consecutive blocks and is
multiplied by $100 / 101$ at the start of each new interval, so that it decays
geometrically, by roughly one percent every 6144 blocks (about three weeks on
the main network). Interval $k$ consists of the heights
$k dot 6144$ through $k dot 6144 + 6143$, so interval 0 contains the genesis
block and block 1, both of which are special.

Writing $B$, $M$, $D$ and $I$ for #param("BaseSubsidy"), #param("MulSubsidy"),
#param("DivSubsidy") and #param("SubsidyReductionInterval"), and $L$ for the sum
of the amounts in #param("BlockOneLedger"),

$ S(h) = cases(0 & "if" h <= 0, L & "if" h = 1, f(floor(h / I)) & "if" h >= 2,) quad quad f(k) = cases(B & "if" k = 0, floor((f(k - 1) dot M) / D) & "if" k >= 1.) $ <eq:subsidy-full>

#rule("Full block subsidy", src: "blockchain/standalone/subsidy.go · CalcBlockSubsidy")[
  The full block subsidy of height $h$ #MUST be computed by
  @alg:subsidy-full. In particular the reduction #MUST be applied once per
  completed interval, as a multiplication by #param("MulSubsidy") followed by
  a truncating division by #param("DivSubsidy"), each step operating on the
  result of the previous step. The genesis block has subsidy 0, and block 1
  has the sum of the block-one ledger instead of #param("BaseSubsidy").
] <rule:subsidy-full>

#algorithm("Full block subsidy", src: "blockchain/standalone/subsidy.go · CalcBlockSubsidy")[
  ```python
  def block_subsidy(height: int64) -> int64:
      if height <= 0:
          return 0                      # genesis (and negative heights)
      if height == 1:
          return block_one_subsidy()    # sum of BlockOneLedger amounts; 0 if empty
      s: int64 = BaseSubsidy
      for _ in range(height // SubsidyReductionInterval):
          s = s * MulSubsidy            # never overflows for valid parameters
          s = s // DivSubsidy           # truncating; both operands non-negative
          if s == 0:
              break                     # all later intervals are also 0
      return s
  ```
] <alg:subsidy-full>

#pitfall[
  Iterated truncating division is not the same as the closed form
  $floor(B dot (M / D)^k)$. The two first differ in interval 2, where the
  iteration gives 3058114560 and the closed form 3058114561. The gap grows to
  31 atoms by interval 100 and stays between 42 and 56 atoms from
  interval 200 on, and the closed form is still 56 atoms when the iterated
  value reaches zero. Exact rational or floating point
  evaluation of a power is therefore wrong. An implementation may cache
  per-interval values (dcrd does), but each cached value must be the result of
  the iteration.
]

=== When the Subsidy Reaches Zero <sec:subsidy-zero>

For $1 <= s <= 101$, $floor(100 s / 101) = s - 1$. Once the full subsidy
falls to 101 atoms or less it therefore decreases by exactly one atom per
interval. On the main network $S$ is 1 atom in interval 1791 (heights 11003904
to 11010047) and 0 from interval 1792 on: the first height with zero full
subsidy is 11010048. The shares reach zero earlier, because each is a
truncated fraction of $S$ (@sec:subsidy-supply gives the last heights).

#note[
  The parameter documentation states that #param("BaseSubsidy") must not exceed
  $140 739 635 871 744 = floor((2^63 - 1) / (2^16 - 1))$ atoms, so that the
  products in this chapter cannot overflow `int64`. All networks are far below
  this bound, and no consensus check enforces it.
]

== Splitting the Subsidy <sec:subsidy-split>

The full subsidy of a block is divided among proof of work, votes and the
treasury in fixed proportions. The proportions have changed twice by
stakeholder vote; each set is called a *split variant*.

=== Split Variants and Their Selection <sec:subsidy-variants>

#figure(
  caption: [Subsidy split variants. Each share is a fraction $n \/ d$ of $S$.],
  table(
    columns: (auto, auto, auto, auto, auto, 1fr),
    table.header([Variant], [Agenda], [PoW $w_n \/ w_d$], [Votes $s_n \/ s_d$], [Treasury], [Main-network activation]),
    [Original], [none], [6/10 (60%)], [3/10 (30%)], [1/10 (10%)], [From genesis],
    [DCP-0010], [`changesubsidysplit`], [10/100 (10%)], [80/100 (80%)], [1/10 (10%)], [Block 657280],
    [DCP-0012], [`changesubsidysplitr2`], [1/100 (1%)], [89/100 (89%)], [1/10 (10%)], [Block 794368],
  ),
) <tab:subsidy-variants>

In the original variant the work fraction is
#param("WorkRewardProportion")~$\/ P$ and the vote fraction is
#param("StakeRewardProportion")~$\/ P$, with $P$ from @eq:subsidy-derived; in the two modified variants they are the
fixed constants shown, on every network. The treasury share is
#param("BlockTaxProportion")~$\/ P = 1 \/ 10$ in all three variants. The
activation heights are those recorded in @dcp0010 and @dcp0012 for the main
network; an implementation derives activation from the chain
(#chref("voting")), not from this table.

#rule("Selection of the split variant", src: ("internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/agendas.go · isSubsidySplitAgendaActive, isSubsidySplitR2AgendaActive"))[
  The split variant used for every subsidy amount checked while connecting a
  block (its coinbase, its votes' stakebase inputs and its stake-tree totals)
  #MUST be chosen from the agendas that are active *for that block*, that is,
  as determined from the state after its parent:

  + if `changesubsidysplitr2` (#dcp(12)) is active for the block, the DCP-0012
    variant;
  + otherwise, if `changesubsidysplit` (#dcp(10)) is active for the block, the
    DCP-0010 variant;
  + otherwise, the original variant.

  The DCP-0012 variant takes precedence even if `changesubsidysplit` is not
  active. The same block's variant applies to the vote subsidy even though
  that subsidy is computed from the parent's height
  (@rule:subsidy-vote-height).
] <rule:subsidy-variant>

Whether the `treasury` agenda (#dcp(6)) is active for the block is likewise
determined from the state after its parent, and that agenda is never active
for blocks 0 and 1.

=== The Three Shares <sec:subsidy-shares>

@alg:subsidy-shares defines the three share functions. `WORK[variant]` and
`VOTE[variant]` are the pairs $(n, d)$ of @tab:subsidy-variants, and $m$ is
from @eq:subsidy-minvotes. The argument `voters` is the number of votes in the
block, which equals the `Voters` field of its header (#chref("blocks")); below
#param("StakeValidationHeight") it is 0 and is ignored.

#algorithm("Proof-of-work, per-vote and treasury subsidies", src: "blockchain/standalone/subsidy.go · calcWorkSubsidy, CalcWorkSubsidyV3, calcStakeVoteSubsidy, CalcStakeVoteSubsidyV3, CalcTreasurySubsidy")[
  ```python
  P = WorkRewardProportion + StakeRewardProportion + BlockTaxProportion   # 10
  MIN_VOTES = TicketsPerBlock // 2 + 1                                     # 3
  WORK = {ORIGINAL: (WorkRewardProportion, P), DCP0010: (10, 100), DCP0012: (1, 100)}
  VOTE = {ORIGINAL: (StakeRewardProportion, P), DCP0010: (80, 100), DCP0012: (89, 100)}

  def work_subsidy(height: int64, voters: int, variant) -> int64:
      if height == 1:
          return block_subsidy(1)
      if height >= StakeValidationHeight and voters < MIN_VOTES:
          return 0
      n, d = WORK[variant]
      s = block_subsidy(height) * n // d                 # first truncation
      if height < StakeValidationHeight:
          return s                                       # no vote scaling yet
      return (voters * s) // TicketsPerBlock             # second truncation

  def vote_subsidy(height: int64, variant) -> int64:     # amount per vote
      if height < StakeValidationHeight - 1:
          return 0
      n, d = VOTE[variant]
      return block_subsidy(height) * n // (d * TicketsPerBlock)   # one truncation

  def treasury_subsidy(height: int64, voters: int, treasury_active: bool) -> int64:
      if height <= 1:
          return 0
      if height >= StakeValidationHeight and voters < MIN_VOTES:
          return 0
      s = block_subsidy(height) * BlockTaxProportion // P
      if height < StakeValidationHeight or treasury_active:
          return s
      return (voters * s) // TicketsPerBlock
  ```
] <alg:subsidy-shares>

In formulas, for $h >= 2$ and $v$ votes (at least $m$ from
#param("StakeValidationHeight") on, and 0 below it), with $N$ = #param("TicketsPerBlock"):

$ W(h, v) = floor((v dot floor(S(h) dot w_n / w_d)) / N), quad V(h) = floor((S(h) dot s_n) / (s_d dot N)), quad T(h, v) = floor((v dot floor(S(h) / 10)) / N), $

where the outer scaling by $v / N$ is omitted below
#param("StakeValidationHeight"), and for $T$ also when the `treasury` agenda
is active. Three details of @alg:subsidy-shares are easy to miss:

- The work subsidy is truncated twice (once for the proportion, once for the
  vote scaling), in that order. Computing $floor(S dot w_n dot v \/ (w_d dot N))$
  instead gives different results: at height 6144 with three votes it gives
  1111930454 instead of the correct 1111930453.
- The vote subsidy is $S dot s_n$ divided by $s_d dot N$. Because nested
  truncating divisions of non-negative integers compose, this equals the
  collective stake share $floor(S dot s_n \/ s_d)$ divided by $N$; what
  matters is that the collective share is never scaled by the number of
  votes.
- The treasury share always uses the denominator $P = 10$ derived from the
  original parameters; the modified variants change only the work and vote
  shares. Before the `treasury` agenda it is scaled by the number of votes
  like the work share; afterwards it is not.

#rule("The vote subsidy is based on the height voted on", src: ("internal/blockchain/validate.go · checkVoteInputs, checkStakeBaseAmounts, checkTransactionsAndConnect", "blockchain/standalone/subsidy.go · calcStakeVoteSubsidy"))[
  The subsidy earned by each vote in the block at height $h$ #MUST be
  `vote_subsidy(h - 1, variant)`, where `variant` is the split variant of the
  block at height $h$ (@rule:subsidy-variant). The proof-of-work and treasury
  subsidies of the same block use height $h$.
] <rule:subsidy-vote-height>

#pitfall[
  Because of @rule:subsidy-vote-height, the votes in the first block of each
  reduction interval earn the subsidy of the *previous* interval, while the
  work and treasury shares of that block already use the reduced value. Under
  the modified variants the vote share dominates, so the total paid by such a
  block exceeds its own full subsidy: block 657408, the first block of
  interval 107, pays $107574538 + 5 dot 173840453 + 107574538 = 1084351341$
  atoms against $S(657408) = 1075745381$. The same offset makes the votes in
  the first voting block, at height #param("StakeValidationHeight"), earn the
  subsidy of height #param("StakeValidationHeight") $- 1$, which is why
  `vote_subsidy` returns a non-zero value from that height on. dcrd's source
  calls this basis unfortunate but it is part of consensus.
]

#rationale[
  The work subsidy is scaled by the number of votes so that a miner gains
  nothing by withholding votes from a block; each missing vote forfeits a
  fifth of the proof-of-work share. The vote subsidy is not scaled, since a
  vote that is not included simply earns nothing. #dcp(6) removed the vote
  scaling of the treasury share when that share moved to the treasurybase.
]

=== Rounding and Unissued Atoms <sec:subsidy-rounding>

The shares are truncated independently, so with five votes
$W + 5 V + T$ is normally a few atoms less than $S$; those atoms are never
created. @tab:subsidy-trunc shows the shortfall at some heights. Two further
amounts are never issued: the vote share of the blocks below
#param("StakeValidationHeight") $- 1$ (heights 2 to 4094 on the main
network, which no vote ever votes on), and every share lost to missing votes,
disapproved blocks, or coinbases that pay less than allowed.

#figure(
  caption: [Shortfall $S - W - 5V - T$ in atoms, five votes, $V$ evaluated at the same height],
  table(
    columns: (auto, auto, auto, auto, auto),
    table.header([Height], [$S(h)$], [Original], [DCP-0010], [DCP-0012]),
    [4096], [3119582664], [5], [2], [2],
    [6144], [3088695706], [3], [6], [4],
    [614400], [1153344657], [3], [2], [6],
    [1228800], [426404419], [2], [2], [4],
    [6144000], [148792], [3], [4], [6],
  ),
) <tab:subsidy-trunc>

=== Test Vectors <sec:subsidy-vectors>

The vectors below were produced by calling dcrd's `SubsidyCache` with the
main-network parameters. @tab:subsidy-vec-work gives the work and treasury
functions and @tab:subsidy-vec-vote the per-vote function, each evaluated at
the height in the first column (not shifted).

#figure(
  caption: [Main network: $S(h)$, `work_subsidy` per variant and `treasury_subsidy` with the `treasury` agenda inactive and active],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    align: right,
    table.header([$h$], [$v$], [$S(h)$], [$W$ orig.], [$W$ 0010], [$W$ 0012], [$T$ inactive], [$T$ active]),
    [0], [0], [0], [0], [0], [0], [0], [0],
    [1], [0], [168000000000000], [=$S(1)$], [=$S(1)$], [=$S(1)$], [0], [0],
    [2], [0], [3119582664], [1871749598], [311958266], [31195826], [311958266], [311958266],
    [4095], [0], [3119582664], [1871749598], [311958266], [31195826], [311958266], [311958266],
    [4096], [5], [3119582664], [1871749598], [311958266], [31195826], [311958266], [311958266],
    [4096], [4], [3119582664], [1497399678], [249566612], [24956660], [249566612], [311958266],
    [4096], [3], [3119582664], [1123049758], [187174959], [18717495], [187174959], [311958266],
    [4096], [2], [3119582664], [0], [0], [0], [0], [0],
    [6144], [5], [3088695706], [1853217423], [308869570], [30886957], [308869570], [308869570],
    [6144], [3], [3088695706], [1111930453], [185321742], [18532174], [185321742], [308869570],
    [552448], [4], [1286750131], [617640062], [102940010], [10294000], [102940010], [128675013],
    [657280], [5], [1086502835], [651901701], [108650283], [10865028], [108650283], [108650283],
    [794368], [3], [864249748], [311129908], [51854984], [5185498], [51854984], [86424974],
    [1000000], [5], [622348887], [373409332], [62234888], [6223488], [62234888], [62234888],
    [5000000], [4], [956745], [459237], [76539], [7653], [76539], [95674],
    [10000000], [3], [243], [87], [14], [1], [14], [24],
    [11010047], [5], [1], [0], [0], [0], [0], [0],
    [11010048], [5], [0], [0], [0], [0], [0], [0],
  ),
) <tab:subsidy-vec-work>

#figure(
  caption: [Main network: `vote_subsidy(h, variant)`, the amount per vote, at height $h$],
  table(
    columns: (auto, auto, auto, auto),
    align: right,
    table.header([$h$], [Original], [DCP-0010], [DCP-0012]),
    [4094], [0], [0], [0],
    [4095], [187174959], [499133226], [555285714],
    [6143], [187174959], [499133226], [555285714],
    [6144], [185321742], [494191312], [549787835],
    [552448], [77205007], [205880020], [229041523],
    [657280], [65190170], [173840453], [193397504],
    [794368], [51854984], [138279959], [153836455],
    [1000000], [37340933], [99575821], [110778101],
    [5000000], [57404], [153079], [170300],
    [10000000], [14], [38], [43],
  ),
) <tab:subsidy-vec-vote>

@tab:subsidy-vec-block combines the functions as consensus applies them to a
whole block at height $h$: the work and treasury shares at $h$, the per-vote
share at $h - 1$, and the required coinbase input value
(@rule:subsidy-cb-valuein). "Total" is $W + T + v dot V(h - 1)$.

#figure(
  caption: [Main network: subsidy amounts of a block at height $h$ with $v$ votes],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto, auto),
    align: right,
    table.header([$h$], [$v$], [Variant], [Treasury agenda], [Work], [Per vote], [Treasury], [Coinbase input], [Total]),
    [2], [0], [orig.], [no], [1871749598], [0], [311958266], [2183707864], [2183707864],
    [4096], [5], [orig.], [no], [1871749598], [187174959], [311958266], [2183707864], [3119582659],
    [4096], [3], [orig.], [no], [1123049758], [187174959], [187174959], [1310224717], [1871749594],
    [6144], [4], [orig.], [no], [1482573938], [187174959], [247095656], [1729669594], [2478369430],
    [552447], [4], [orig.], [no], [617640062], [77205007], [102940010], [720580072], [1029400100],
    [552448], [4], [orig.], [yes], [617640062], [77205007], [128675013], [617640062], [1055135103],
    [657280], [5], [0010], [yes], [108650283], [173840453], [108650283], [108650283], [1086502831],
    [657408], [5], [0010], [yes], [107574538], [173840453], [107574538], [107574538], [1084351341],
    [794368], [3], [0012], [yes], [5185498], [153836455], [86424974], [5185498], [553119837],
    [798720], [5], [0012], [yes], [8556928], [153836455], [85569281], [8556928], [863308484],
  ),
) <tab:subsidy-vec-block>

== The Coinbase Transaction <sec:subsidy-coinbase>

The *coinbase* is the first transaction of a block's regular transaction tree.
It has a single input that spends nothing, whose `ValueIn` field (part of the
input's witness data, #chref("encoding")) commits to the subsidy being
claimed, and its outputs pay the proof-of-work subsidy plus the block's fees
to whatever scripts the miner chooses. Before the `treasury` agenda its first
output also pays the treasury share. Except in blocks 0 and 1, one output
carries the block height, which makes every coinbase's transaction hash unique.

=== Identifying a Coinbase <sec:subsidy-cb-ident>

#algorithm("Coinbase identification", src: "blockchain/standalone/tx.go · IsCoinBaseTx")[
  ```python
  def is_coinbase(tx, treasury_active: bool) -> bool:
      if treasury_active and tx.version != 3:
          return False
      if len(tx.inputs) != 1:
          return False
      prev = tx.inputs[0].prev_out
      if prev.index != 0xffffffff or prev.hash != bytes(32):
          return False                              # prev.tree is not examined here
      if treasury_active and len(tx.outputs) >= 2:  # exclude treasury-spend look-alikes
          sig = tx.inputs[0].sig_script
          s0 = tx.outputs[0].pk_script
          s1 = tx.outputs[1].pk_script
          if (len(sig) > 0 and len(s0) > 0 and len(s1) > 0 and sig[-1] == 0xc2
                  and s0[0] == 0x6a and s1[0] == 0xc3):  # OP_TSPEND, OP_RETURN, OP_TGEN
              return False
      return True
  ```
] <alg:subsidy-is-coinbase>

Before the `treasury` agenda a coinbase may have any transaction version
permitted by the general version rules (#chref("transactions")); once the
agenda is active it must have version 3 (`TxVersionTreasury`), and a
transaction of any other version is not a coinbase at all.

#rule("The first regular transaction is the only coinbase", src: "internal/blockchain/validate.go · checkBlockContext")[
  For every block other than the genesis block, the first transaction of the
  regular tree #MUST satisfy `is_coinbase(tx, treasury_active)`, where
  `treasury_active` tells whether the `treasury` agenda is active for the
  block. Every other transaction of the regular tree #MUSTNOT satisfy it.
] <rule:subsidy-cb-first>

#rule("Coinbase input", src: "internal/blockchain/validate.go · checkTransactionContext, isNullOutpoint, isNullFraudProof")[
  For a regular-tree transaction that satisfies `is_coinbase`:

  + the previous outpoint of its input #MUST be the null outpoint: hash of 32
    zero bytes, index `0xffffffff` *and* tree 0 (regular);
  + the fraud-proof fields of its input #MUST be null: `BlockHeight` $= 0$
    (`NullBlockHeight`) and `BlockIndex` $=$ `0xffffffff` (`NullBlockIndex`);
  + the length of its signature script #MUST be at least
    #const("MinCoinbaseScriptLen") $= 2$ and at most
    #const("MaxCoinbaseScriptLen") $= 100$ bytes.

  The contents of the signature script are otherwise unconstrained. The
  input's `ValueIn` is constrained by @rule:subsidy-cb-valuein.
] <rule:subsidy-cb-input>

The general transaction rules of #chref("transactions") (sanity limits,
version and script-version limits, lock time and expiry, the prohibition on
stake opcodes in regular transactions) apply to the coinbase as to any other
regular transaction. The coinbase has no real inputs, so input existence,
script execution and sequence locks do not apply to it.

=== Required Outputs <sec:subsidy-cb-outputs>

The required leading outputs of the coinbase depend on whether the `treasury`
agenda is active for the block (@tab:subsidy-cb-layout). Outputs after the
required ones are free: any number of them, with any scripts and amounts
allowed by the general rules, subject only to the total of
@rule:subsidy-cb-value. They normally pay the miner.

#figure(
  caption: [Leading outputs of the coinbase of a block at height $h >= 2$],
  table(
    columns: (auto, 1fr, 1fr),
    table.header([Output], [`treasury` agenda not active], [`treasury` agenda active]),
    [0], [Treasury payment: script #param("OrganizationPkScript"), version #param("OrganizationPkScriptVersion"), amount exactly `treasury_subsidy(h, v, False)` (@rule:subsidy-cb-org)], [Height commitment (@rule:subsidy-cb-height)],
    [1], [Height commitment (@rule:subsidy-cb-height)], [Free],
    [2, ...], [Free], [Free],
  ),
) <tab:subsidy-cb-layout>

#rule("Treasury output before the treasury agenda", src: ("internal/blockchain/subsidy.go · coinbasePaysTreasuryAddress", "internal/blockchain/validate.go · checkConnectBlock"))[
  If the `treasury` agenda is not active for a block at height $h >= 2$, its
  coinbase #MUST have at least one output, and output 0 #MUST have script
  version equal to #param("OrganizationPkScriptVersion"), a public key script
  byte-for-byte equal to #param("OrganizationPkScript"), and an amount equal to
  `treasury_subsidy(h, v, False)`, where $v$ is the number of votes in the
  block. Blocks 0 and 1 are exempt.
] <rule:subsidy-cb-org>

Once the `treasury` agenda is active the coinbase carries no treasury payment;
the treasury share is paid by the *treasurybase*, which must be the first
transaction of the stake tree. Its format, its own height commitment and its
effect on the treasury balance are specified in #chref("treasury")\; its amount
is fixed by @rule:subsidy-tb-amount.

=== The Height Commitment <sec:subsidy-cb-height>

The height commitment is a provably unspendable output (#chref("script"))
whose script is `OP_RETURN` followed by a single data push. The first four
bytes of the pushed data are the block height as a little-endian `uint32`;
any further bytes, up to 252 of them, are free and conventionally hold an
*extra nonce* that miners vary to change the coinbase hash, and with it the
block's Merkle root, without changing anything else.

#rule("Coinbase height commitment", src: "internal/blockchain/validate.go · checkCoinbaseUniqueHeight")[
  For a block at height $h >= 2$, let $i = 1$ if the `treasury` agenda is not
  active for the block and $i = 0$ if it is. The coinbase #MUST have at least
  $i + 1$ outputs; output $i$ #MUST have script version 0; and its public key
  script, parsed by `commitment_data` of @alg:subsidy-height, #MUST yield
  between 4 and #const("maxUniqueCoinbaseNullDataSize") $= 256$ bytes
  inclusive, whose first four bytes, read as a little-endian `uint32`, #MUST
  equal `uint32(h)`. The output's amount is not constrained by this rule.
  Blocks 0 and 1 are exempt.
] <rule:subsidy-cb-height>

#algorithm("Extracting the coinbase height commitment", src: ("internal/blockchain/validate.go · checkCoinbaseUniqueHeight", "txscript/tokenizer.go · ScriptTokenizer.Next"))[
  ```python
  def commitment_data(pk: bytes) -> bytes:
      # pk must be OP_RETURN followed by exactly one push opcode (0x00..0x4e)
      # and nothing else; any other form yields the empty string.
      if len(pk) < 2 or pk[0] != 0x6a:          # OP_RETURN
          return b""
      op, rest = pk[1], pk[2:]
      if op <= 0x4b:                            # OP_0 and OP_DATA_1..OP_DATA_75
          n, body = op, rest
      elif op == 0x4c and len(rest) >= 1:       # OP_PUSHDATA1
          n, body = rest[0], rest[1:]
      elif op == 0x4d and len(rest) >= 2:       # OP_PUSHDATA2
          n, body = le16_decode(rest[0:2]), rest[2:]
      elif op == 0x4e and len(rest) >= 4:       # OP_PUSHDATA4
          n, body = le32_decode(rest[0:4]), rest[4:]
      else:
          return b""
      if n != len(body):                        # truncated push or trailing bytes
          return b""
      return body

  def check_height_commitment(coinbase, h: int, treasury_active: bool):
      if h < 2:
          return
      i = 0 if treasury_active else 1
      if len(coinbase.outputs) < i + 1:
          reject("missing height commitment output")
      out = coinbase.outputs[i]
      if out.script_version != 0:
          reject("height commitment script version")
      data = commitment_data(out.pk_script)
      if len(data) > 256 or len(data) < 4:
          reject("height commitment data length")
      if le32_decode(data[0:4]) != h % 2**32:
          reject("wrong height in coinbase")
  ```
] <alg:subsidy-height>

Minimal push encoding is not required: the height may be pushed with
`OP_PUSHDATA1`, `OP_PUSHDATA2` or `OP_PUSHDATA4` as well as with a direct push,
and the number is never interpreted with script-number semantics.
@tab:subsidy-cb-nulldata shows the 14-byte form that dcrd's block template
generator produces (a policy choice). The treasurybase is required to use
exactly this form (#chref("treasury")).

#fieldtable(
  caption: [Standard coinbase height-commitment script (policy; 14 bytes)],
  ("opcode", "byte", "1", [`0x6a` (`OP_RETURN`).]),
  ("push", "byte", "1", [`0x0c` (`OP_DATA_12`).]),
  ("height", "uint32", "4", [Block height, little-endian (consensus: must equal the block height).]),
  ("extra nonce", "uint64", "8", [Random value chosen by the miner, little-endian.]),
) <tab:subsidy-cb-nulldata>

=== Coinbase Amounts <sec:subsidy-cb-amounts>

The coinbase may pay out at most the subsidy it is entitled to plus the fees of
the block, and its input must state the subsidy part exactly. The fees are the
sum of the fees of all transactions of *both* trees of the block, as computed
by the input checks of #chref("transactions")\; the stake-tree fees (from
tickets, votes, revocations, treasury adds and treasury spends) are added to
those of the regular tree. A vote whose outputs total less than its inputs
(the ticket amount plus the stakebase subsidy), as the fee limits of its
ticket may allow (#chref("staking")), therefore contributes the difference as
a fee that the coinbase may claim. From #param("StakeValidationHeight") on, the fee total is
scaled by the number of votes, so that a block with fewer than five votes can
claim only part of its fees; the unclaimable part is destroyed.

#algorithm("Coinbase amount checks", src: "internal/blockchain/validate.go · checkTransactionsAndConnect, checkConnectBlock")[
  ```python
  def check_coinbase_amounts(block, h: int, voters: int, variant, treasury_active: bool,
                             stake_fees: int64, regular_fees: list[int64]):
      fees: int64 = stake_fees              # fees of all stake-tree transactions, summed
                                            # with the same overflow check as below
      for f in regular_fees:                # regular-tree fees (coinbase contributes 0)
          fees = fees + f
          if overflows_int64(fees):
              reject("total fees overflow")
      if h >= StakeValidationHeight:
          fees = fees * voters // TicketsPerBlock
      if h == 1:
          expected = block_subsidy(1)       # fees are not added at height 1
      else:
          work = work_subsidy(h, voters, variant)
          if treasury_active:
              expected = work + fees        # treasury share is in the treasurybase
          else:
              expected = work + treasury_subsidy(h, voters, False) + fees
      coinbase = block.regular[0]
      if coinbase.inputs[0].value_in != expected - fees:
          reject("coinbase ValueIn does not commit to the subsidy")
      if sum(out.value for out in coinbase.outputs) > expected:
          reject("coinbase pays more than subsidy plus fees")
  ```
] <alg:subsidy-cb-amounts>

#rule("Coinbase input value", src: "internal/blockchain/validate.go · checkTransactionsAndConnect")[
  The `ValueIn` of the coinbase input of a block at height $h >= 1$ #MUST equal
  `expected - fees` as computed by @alg:subsidy-cb-amounts. For $h >= 2$ this is
  `work_subsidy(h, v, variant)` plus, while the `treasury` agenda is not active
  for the block, `treasury_subsidy(h, v, False)`. For $h = 1$ it is the
  block-one subsidy minus the block's fees.
] <rule:subsidy-cb-valuein>

#rule("Coinbase output total", src: "internal/blockchain/validate.go · checkTransactionsAndConnect")[
  The sum of the amounts of all outputs of the coinbase of a block at height
  $h >= 1$, including the treasury output and the height commitment where
  present, #MUSTNOT exceed `expected` as computed by
  @alg:subsidy-cb-amounts. Paying less is permitted; the difference is never
  created. The running fee total #MUSTNOT overflow `int64`.
] <rule:subsidy-cb-value>

#note[
  At height 1 the fee total is necessarily zero: no output that a non-coinbase
  transaction could spend exists before block 1's coinbase outputs mature, so
  block 1 cannot contain fee-paying transactions. The rules are stated as
  implemented nonetheless. The individual coinbase outputs of block 1 are fixed
  by @rule:subsidy-b1-outputs.
]

#pitfall[
  The fee scaling uses the votes of the block whose coinbase is being checked
  and is applied to the combined fee total, with one truncation: for 999 atoms
  of fees and three votes the coinbase may claim $floor(999 dot 3 / 5) = 599$
  atoms. The fees are those of the block's own two trees only; nothing from the
  parent block is included.
]

=== Disapproval and the Coinbase <sec:subsidy-disapproval>

When the votes of block $N + 1$ disapprove block $N$ (#chref("blocks")),
every transaction of $N$'s regular tree, the coinbase included, is
disconnected as if it had never been mined, while $N$'s stake tree remains
in effect. Consequently:

- $N$'s proof-of-work subsidy and all fees its coinbase claimed are never
  created. This includes the stake-tree fees of $N$, which stay spent because
  $N$'s stake transactions remain valid.
- Before the `treasury` agenda, the treasury payment in output 0 of $N$'s
  coinbase is lost as well. Afterwards the treasury share is paid by the
  treasurybase in the stake tree and survives disapproval, which #dcp(6) gives
  as an intended consequence.
- The vote subsidies paid by $N$'s votes are unaffected.
- The non-coinbase transactions of $N$'s regular tree, and their fees, return
  to the unconfirmed state and may be included again, by $N + 1$ or later.

The coinbase of block $N + 1$ is checked against $N + 1$'s own subsidy and fees
by @alg:subsidy-cb-amounts whether or not it disapproves $N$.

=== Maturity <sec:subsidy-maturity>

Outputs of a coinbase cannot be spent until #param("CoinbaseMaturity") $= 256$
blocks have passed (the treasury balance and vote outputs have related
maturity rules). These rules are specified in #chref("transactions") and
#chref("treasury").

=== Coinbase Construction (Policy) <sec:subsidy-cb-policy>

The following describes what dcrd's block template generator produces; none
of it is required beyond the rules above. Its coinbase has version 1 before
the `treasury` agenda and 3 afterwards; a signature script of two zero bytes
followed by the ASCII text `/dcrd/`; input sequence `0xffffffff`; and the
outputs, in order: the treasury payment (before the agenda), a zero-value
height commitment of the form in @tab:subsidy-cb-nulldata with a random extra
nonce, and a single output paying the work subsidy to the miner's address.
For blocks above height 1, once the block's transactions are selected, the
fee total of both trees, scaled by the number of votes from
#param("StakeValidationHeight") on exactly as in @alg:subsidy-cb-amounts, is
added to that last output, so a dcrd-built coinbase claims its full
entitlement. Its `ValueIn` is set as required by @rule:subsidy-cb-valuein
(the subsidy only, without the fees). Three cases differ: the coinbase of
block 1 has only the ledger outputs; before the agenda, on a network whose
#param("BlockTaxProportion") is zero, output 0 is a zero-value `OP_TRUE`
script; and with no mining address configured the work output pays to
`OP_TRUE`.

== Subsidy Checks in the Stake Tree <sec:subsidy-stake>

Each vote (#chref("staking")) has a *stakebase* input, its first input, which,
like the coinbase input, spends nothing and whose `ValueIn` states the subsidy
the vote creates. Its second input spends the ticket. The vote's outputs pay
the ticket amount plus the subsidy to the addresses committed to by the ticket;
how that total is divided among the outputs is specified in
#chref("staking"). The following rules fix the amounts.

#rule("Vote stakebase value", src: "internal/blockchain/validate.go · checkVoteInputs")[
  The `ValueIn` of the stakebase input of every vote #MUST equal
  `vote_subsidy(H, variant)`, where $H$ is the height of the block the vote
  votes on, as encoded in the vote itself, and `variant` is the split variant
  of the block containing the vote. #chref("staking") requires $H = h - 1$ for
  every vote in a block at height $h$.
] <rule:subsidy-vote-valuein>

#rule("Vote output limits", src: "internal/blockchain/validate.go · checkStakeBaseAmounts, getStakeBaseAmounts, checkTransactionsAndConnect")[
  For a block at height $h$ containing votes, let
  $A = $ `vote_subsidy(h - 1, variant)`, and for each vote let its *excess* be
  the sum of its output amounts minus the amount of the ticket output its
  second input spends.

  + The excess of each vote #MUSTNOT exceed $A$.
  + The sum of the excesses of all votes in the block #MUSTNOT exceed
    $A dot v$ if $h >=$ #param("StakeValidationHeight"), where $v$ is the
    number of votes, and #MUSTNOT exceed 0 otherwise.
] <rule:subsidy-vote-limits>

These two limits are implied by @rule:subsidy-vote-valuein together with the
general rule that outputs may not exceed inputs and the output commitments of
#chref("staking"), but dcrd checks them separately and they are consensus
rules in their own right.

#rule("Treasurybase amount", src: ("internal/blockchain/subsidy.go · checkTreasuryBase", "internal/blockchain/validate.go · checkTransactionsAndConnect"))[
  If the `treasury` agenda is active for a block at height $h >= 2$, both the
  amount of output 0 of its treasurybase and the `ValueIn` of the
  treasurybase's input #MUST equal `treasury_subsidy(h, v, True)`, which does
  not depend on the number of votes $v$ once $v >= m$. All other properties of
  the treasurybase are specified in #chref("treasury").
] <rule:subsidy-tb-amount>

#note[
  dcrd maintains a running "total subsidy" in its chain state (reported by its
  RPC interface) by adding, for each block, the coinbase `ValueIn` of the
  parent if the block approves it, the treasurybase `ValueIn`, and the
  stakebase `ValueIn` of each vote. The figure counts claimed subsidy, not the
  amounts actually paid out, and is not used by any consensus rule.
]

== The Block-One Ledger <sec:subsidy-ledger>

Decred has no subsidy at height 1 in the usual sense. Instead, the coinbase of
block 1 must pay exactly the outputs listed in the network's
#param("BlockOneLedger"): an ordered list of entries, each a script version,
a public key script and an amount. On the main network the ledger distributes
1680000 DCR, eight percent of 21 million: according to the Decred
documentation @dcrdocs, half to the project's founding developers in
compensation for initial development and half airdropped to registered
participants.

#rule("Block-one coinbase", src: "internal/blockchain/subsidy.go · blockOneCoinbasePaysTokens")[
  If #param("BlockOneLedger") is non-empty, the coinbase of the block at
  height 1 #MUST have lock time 0, expiry 0 (`NoExpiryValue`), and input
  sequence number `0xffffffff`.
] <rule:subsidy-b1-tx>

#rule("Block-one outputs", src: "internal/blockchain/subsidy.go · blockOneCoinbasePaysTokens")[
  If #param("BlockOneLedger") is non-empty, the coinbase of the block at
  height 1 #MUST have exactly as many outputs as the ledger has entries, and
  for every index $i$, output $i$ #MUST have the script version, the public key
  script (byte for byte) and the amount of ledger entry $i$. The order is
  significant. If the ledger is empty this rule imposes nothing.
] <rule:subsidy-b1-outputs>

Together with @rule:subsidy-cb-valuein and @rule:subsidy-cb-value this fixes
the coinbase of block 1 completely except for its transaction version and its
signature script (2 to 100 bytes). Block 1 has no height commitment and no
treasury output. All four networks have a non-empty ledger, and every entry on
every network is a version-0 pay-to-pubkey-hash script of 25 bytes
(`76 a9 14` $||$ 20-byte hash $||$ `88 ac`).

#figure(
  caption: [Block-one ledgers. The digest is BLAKE-256 over the concatenation, in ledger order, of each entry serialized as $"LE"_64("amount") || "LE"_16("version") || "varint"(|"script"|) || "script"$, the serialization of the outputs in the block-one coinbase without the leading output count; it is given in natural byte order.],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Network], [Entries], [Total (atoms)], [Ledger digest]),
    [mainnet], [3146], [168000000000000], [#hex("fc5c40905a817a6d6d2407648cdbb5ad39a2875c31c309f5ee62d7e33da737ab")],
    [testnet3], [2], [10000000000000], [#hex("80b7d8ec820546e6a40c7720435bf03f895812316bf3756d66dedb7cb0a04110")],
    [simnet], [3], [30000000000000], [#hex("d6f72c64c85ed781166656e579807aede52e88aa97810fc3a359cfe29385020b")],
    [regnet], [3], [30000000000000], [#hex("77b5ee4b9abcb50abb51322f4227aa9617524ac7f90dbbcb5f320f59a6fe1be2")],
  ),
) <tab:subsidy-ledgers>

The serialized main-network list is 113256 bytes ($3146 times 36$). A second
identifier follows from the fact that a Decred transaction hash covers only
the transaction prefix, which excludes the signature script and `ValueIn`
(#chref("encoding")): the hash of block 1's coinbase is determined by the
ledger and the transaction version. With version 1, as on the main network,
it is, in display form,

#align(center, hex("5e29cdb355b3fc7e76c98a9983cd44324b3efdd7815c866e33f6c72292cb8be6"))

which matches the premine transaction identified in the Decred documentation
@dcrdocs.

#figure(
  caption: [Main-network ledger: distribution of amounts],
  table(
    columns: (auto, auto, auto),
    align: (right, right, right),
    table.header([Amount (atoms)], [Entries], [Subtotal (atoms)]),
    [500000000000], [167], [83500000000000],
    [28263795424], [2972], [84000000000128],
    [201801801802], [1], [201801801802],
    [80900900901], [1], [80900900901],
    [72072072072], [1], [72072072072],
    [63063063063], [1], [63063063063],
    [54054054054], [1], [54054054054],
    [18018018018], [1], [18018018018],
    [10090089962], [1], [10090089962],
    [], [3146], [168000000000000],
  ),
) <tab:subsidy-ledger-amounts>

The first main-network entry pays 500000000000 atoms to
#hex("76a91464e20eb6075561d30c23a517c5b73badbc120f0588ac") and the last pays
28263795424 atoms to
#hex("76a9145e4cde3d3d959bbc1efe5e5f0f63b9fbe00f486488ac").
The ledgers of the test and private networks are short enough to list in full
(@tab:subsidy-ledger-small).

#figure(
  caption: [Block-one ledgers of the test and private networks (all script version 0)],
  table(
    columns: (auto, 1fr, auto),
    table.header([Network], [Public key script], [Amount (atoms)]),
    [testnet3], [#hex("76a914bb56576997d9f7abeebac585821b4d9a79d7ea0a88ac")], [8000000000000],
    [testnet3], [#hex("76a9147a5c4cca76f2e0b36db4763daacbd6cbb6ee6e7b88ac")], [2000000000000],
    [simnet], [#hex("76a91494ff37a0ee4d48abc45f70474f9b86f9da69a70988ac")], [10000000000000],
    [simnet], [#hex("76a914a6753ebbc08e2553e7dd6d64bdead4bcbff4fcf188ac")], [10000000000000],
    [simnet], [#hex("76a9147aa3211c2ead810bbf5911c275c69cc196202bd888ac")], [10000000000000],
    [regnet], [#hex("76a9147e4765ae88ba9ad5c9e4715c484e90b34d358d5188ac")], [10000000000000],
    [regnet], [#hex("76a91402fb1ac0137666d79165e13cecd403883615270788ac")], [10000000000000],
    [regnet], [#hex("76a91469de627d3231b14228653dd09cba75eeb872754288ac")], [10000000000000],
  ),
) <tab:subsidy-ledger-small>

#note[
  In the dcrd source the ledger exists in two forms. `chaincfg/subsidydefinitions.go`
  holds the human-readable list of (script, amount) entries per network; it is
  compiled only with the build tag `subsidydefs` and serves as the input to the
  generator `chaincfg/generatesubsidytables.go`. The generator writes
  `chaincfg/subsidytables.go`, which stores, per network, all scripts
  concatenated into one hexadecimal string and a list of (end offset, amount)
  pairs; at start-up these are sliced back into the entries of
  #param("BlockOneLedger"). Only the generated file is compiled into the node,
  and it is consensus-critical through @rule:subsidy-b1-outputs and the
  block-one subsidy. The two forms were checked to agree entry for entry on all
  four networks. Earlier versions kept the list in a file named
  `chaincfg/premine.go`, which no longer exists.
]

== Total Supply <sec:subsidy-supply>

The supply of decred is the block-one ledger plus everything paid by the
subsidy rules. For a given history of agenda activations it is largest when
every block from #param("StakeValidationHeight") on contains five votes, no
block is disapproved, and every coinbase, vote and treasurybase claims its
full entitlement. Under those assumptions, and with each split variant and
the `treasury` agenda applied from its main-network activation height and
never changed again (552448 for `treasury`, 657280 for DCP-0010, 794368 for
DCP-0012: in each case the first block to which the new rules apply, the
`Active` block of the deployment tables in @dcp0006, @dcp0010 and @dcp0012),
summing the per-block amounts of @tab:subsidy-vec-block over every height
with dcrd's subsidy functions gives the figures of
@tab:subsidy-supply-totals. They are an upper bound on the main-network
supply under these assumptions, not a value fixed by any consensus rule.

#figure(
  caption: [Maximum main-network supply under the stated assumptions (atoms)],
  table(
    columns: (1fr, auto),
    align: (left, right),
    table.header([Component], [Atoms]),
    [Block-one ledger], [168000000000000],
    [Proof-of-work subsidy], [779527937380932],
    [Vote subsidy], [958890472085010],
    [Treasury subsidy], [193583145837068],
    [*Total*], [*2100001555303010*],
    [Sum of $S(h)$ over $h >= 2$ (nominal, for comparison)], [1935831507356784],
    [Less: $S(h) - W - T$ of blocks 2 to 4095, which pay no vote share (4094 × 935874800; the table attributes $V(h)$ to the block at height $h$ that contains the votes, and the last row corrects for votes being paid at the rate of the block they vote on)], [3831471431200],
    [Less: truncation $S(h) - W - 5V(h) - T$ of blocks from 4096 on], [37531264],
    [Plus: net effect of votes in block $h$ earning $V(h - 1)$ rather than $V(h)$], [1556908690],
  ),
) <tab:subsidy-supply-totals>

The last four rows reconcile the total: $168000000000000 + 1935831507356784 -
3831471431200 - 37531264 + 1556908690 = 2100001555303010$. Further results
under the same assumptions:

- The cumulative supply first exceeds $21 times 10^14$ atoms in block 8605295
  (interval 1400). The maximum exceeds 21 million DCR by 1555303010 atoms,
  about 15.55 DCR, because of the one-block offset of the vote subsidy
  (@rule:subsidy-vote-height): without the last row of
  @tab:subsidy-supply-totals the total would be 2099999998394320 atoms. The
  offset contributes, for each era of constant split variant, five times the
  per-vote subsidy at the start of the era minus five times that at its end
  ($609923945 + 177802470 + 769182275$ atoms for the three eras). dcrd's own
  test suite, which sums $V(h)$ instead of $V(h - 1)$, checks the figure
  2099999999800912 for the original variant applied forever.
- Under DCP-0012 the proof-of-work subsidy is last non-zero at height 10401791,
  the treasury subsidy at height 10954751, and the vote subsidy in block
  10979328, whose five votes earn one atom each. No block after 10979328
  creates any subsidy, although the full subsidy $S$ stays positive until
  height 11010047.
- The realized supply is lower than the maximum: every missing vote forfeits
  one vote subsidy and part of the proof-of-work share (and, before the
  `treasury` agenda, part of the treasury share), every disapproved block
  forfeits its coinbase, and coinbases may claim less than allowed.
  #const("MaxAmount") (#chref("conventions")) bounds individual amounts and is
  not a supply cap; no consensus rule limits the cumulative supply.

#figure(
  caption: [Main-network schedule by reduction interval (five votes per block). Per-block shares are for a block whose votes vote within the same interval, under the variant in force at the start of the interval (original through interval 106, DCP-0010 for intervals 107 to 129, DCP-0012 from interval 130); "Issued" is the total created in the interval and "Cumulative" includes the ledger. Interval 0 starts its vote share at height 4096.],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    align: right,
    table.header([$k$], [First height], [$S$], [Work], [Per vote], [Treasury], [Issued], [Cumulative]),
    [0], [0], [3119582664], [1871749598], [187174959], [311958266], [15329005280848], [183329005280848],
    [1], [6144], [3088695706], [1853217423], [185321742], [308869570], [18976955665317], [202305960946165],
    [2], [12288], [3058114560], [1834868736], [183486873], [305811456], [18789065012553], [221095025958718],
    [3], [18432], [3027836198], [1816701718], [181670171], [302783619], [18603034647158], [239698060605876],
    [4], [24576], [2997857621], [1798714572], [179871457], [299785762], [18418846204706], [258116906810582],
    [5], [30720], [2968175862], [1780905517], [178090551], [296817586], [18236481376082], [276353388186664],
    [10], [61440], [2824117486], [1694470491], [169447049], [282411748], [17351386294046], [364862896567950],
    [25], [153600], [2432552105], [1459531263], [145953126], [243255210], [14945607418487], [605440778188861],
    [50], [307200], [1896827356], [1138096413], [113809641], [189682735], [11654112947312], [934590216157870],
    [89], [546816], [1286750131], [772050078], [77205007], [128675013], [7905796634394], [1309421832808688],
    [100], [614400], [1153344657], [692006794], [69200679], [115334465], [7086153014211], [1391386193254264],
    [106], [651264], [1086502835], [651901701], [65190170], [108650283], [6675476671217], [1432453826242617],
    [107], [657408], [1075745381], [107574538], [172119260], [107574538], [6609388196109], [1439063214438726],
    [129], [792576], [864249748], [86424974], [138279959], [86424974], [5309957348048], [1569006292865055],
    [130], [798720], [855692819], [8556928], [152313321], [85569281], [5257384264886], [1574263677129941],
    [150], [921600], [701278308], [7012783], [124827538], [70127830], [4308660135012], [1669136082867336],
    [200], [1228800], [426404419], [4264044], [75899986], [42640441], [2619832520760], [1838018828956872],
    [300], [1843200], [157646462], [1576464], [28061070], [15764646], [968581253295], [2003143923576476],
    [500], [3072000], [21548080], [215480], [3835558], [2154808], [132391583007], [2086762823622948],
    [750], [4608000], [1790825], [17908], [318766], [179082], [11002814020], [2098901612484732],
    [1000], [6144000], [148792], [1487], [26484], [14879], [914142509], [2099910396925214],
    [1250], [7680000], [12320], [123], [2192], [1232], [75663475], [2099994163967890],
    [1500], [9216000], [979], [9], [174], [97], [5996554], [2100001050474236],
    [1700], [10444800], [92], [0], [16], [9], [546816], [2100001531476498],
    [1782], [10948608], [10], [0], [1], [1], [36864], [2100001555180125],
    [1786], [10973184], [6], [0], [1], [0], [30720], [2100001555303005],
    [1787], [10979328], [5], [0], [0], [0], [5], [2100001555303010],
    [1791], [11003904], [1], [0], [0], [0], [0], [2100001555303010],
    [1792], [11010048], [0], [0], [0], [0], [0], [2100001555303010],
  ),
) <tab:subsidy-schedule>

Intervals 89, 106 and 129 contain an activation (of `treasury`, DCP-0010 and
DCP-0012 respectively); their "Issued" figures include both rules. The
figures in this section other than $S$ are exact consequences of the rules
only under the stated assumptions; $S$ and the share functions themselves are
exact for every chain.

== Summary of Checks <sec:subsidy-checks>

@tab:subsidy-errors maps each rule of this chapter to the error kind dcrd
reports when it is violated, for use when testing an implementation against
dcrd.

#figure(
  caption: [Rules of this chapter and the corresponding dcrd error kinds],
  table(
    columns: (auto, 1fr),
    table.header([Rule], [dcrd error kind(s)]),
    [@rule:subsidy-cb-first], [`ErrFirstTxNotCoinbase`, `ErrMultipleCoinbases`],
    [@rule:subsidy-cb-input], [`ErrBadCoinbaseOutpoint`, `ErrBadCoinbaseFraudProof`, `ErrBadCoinbaseScriptLen`],
    [@rule:subsidy-cb-height], [`ErrFirstTxNotCoinbase` (missing output, wrong version, malformed or wrongly sized push), `ErrCoinbaseHeight` (wrong height)],
    [@rule:subsidy-cb-org], [`ErrNoTxOutputs`, `ErrNoTreasury`],
    [@rule:subsidy-cb-valuein], [`ErrBadCoinbaseAmountIn`],
    [@rule:subsidy-cb-value], [`ErrBadCoinbaseValue`, `ErrBadFees`],
    [@rule:subsidy-vote-valuein], [`ErrBadStakebaseAmountIn`],
    [@rule:subsidy-vote-limits], [`ErrSSGenSubsidy` (per vote), `ErrBadStakebaseValue` (total)],
    [@rule:subsidy-tb-amount], [`ErrTreasurybaseOutValue` (output), `ErrBadTreasurybaseAmountIn` (input)],
    [@rule:subsidy-b1-tx], [`ErrBlockOneTx` (lock time, expiry), `ErrBlockOneInputs` (sequence)],
    [@rule:subsidy-b1-outputs], [`ErrBlockOneOutputs`],
  ),
) <tab:subsidy-errors>
