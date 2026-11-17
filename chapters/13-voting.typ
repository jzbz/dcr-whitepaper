#import "../template.typ": *

= Consensus Rule Changes <ch:voting>

Decred changes its consensus rules by an on-chain vote of the stakeholders.
New rules are shipped in node software in a dormant state, together with a
description of the vote that can enable them. Proof-of-work miners signal
that they run the new software through the block version, and voters signal
it through the version they attach to their votes. Once enough of both have
upgraded, the stakeholders vote on the change for a fixed interval of blocks;
a qualified majority locks the outcome in, and the new rules take effect one
interval later. Every step is a deterministic function of the block chain, so
every node reaches the same verdict on every block.

Other chapters state rules of the form "if agenda _X_ is active for the
block". This chapter defines exactly what that means, specifies the version
rules that the upgrade process imposes on block headers, lists every agenda
ever defined on every network, and records the outcome of each vote on the
main network.

== Overview <sec:voting-overview>

=== Terminology <sec:voting-terms>

@tab:voting-terms defines the vocabulary used throughout the chapter.

#figure(
  caption: [Terms used in this chapter],
  table(
    columns: (auto, 1fr),
    table.header([Term], [Meaning]),
    [Agenda], [A proposed consensus change, identified by a short ASCII
      _agenda ID_ such as `blake3pow`. The rules of other chapters refer to
      agendas by ID.],
    [Deployment], [The parameters under which an agenda is voted on: the vote
      definition (mask and choices), a start time, an expire time and,
      optionally, a forced choice. Deployments are part of the network
      parameters (#param("Deployments")).],
    [Deployment version], [The key under which a deployment is listed in
      #param("Deployments"). Several deployments can share a version and are
      then voted on in parallel. Only votes whose vote version equals the
      deployment version count toward it.],
    [Vote version], [A 32-bit number carried in every vote (@sec:voting-votes).
      Voting software sets it to the highest deployment version it knows.],
    [Vote bits], [The 16-bit field of a vote that carries the approval of the
      previous block in bit 0 and the voter's choices on agendas in the other
      bits.],
    [Block version], [The `Version` field of the block header (signed 32-bit).
      Miners raise it to signal that they run upgraded software.],
    [Stake version], [The `StakeVersion` field of the block header (unsigned
      32-bit). It records the majority vote version of the stakeholders and,
      once enforced, is fully determined by the chain (@sec:voting-stake-version).],
    [Stake version interval (SVI)], [A run of #param("StakeVersionInterval")
      blocks over which vote versions are tallied.],
    [Rule change interval (RCI)], [A run of
      #param("RuleChangeActivationInterval") blocks over which the votes on an
      agenda are tallied. The threshold state of a deployment can change only
      at the boundary between two such intervals.],
    [Threshold state], [One of `Defined`, `Started`, `LockedIn`, `Active` and
      `Failed`: the stage that a deployment has reached
      (@sec:voting-threshold).],
    [Active for block $B$], [The predicate consulted by agenda-dependent rules
      when validating block $B$ (@rule:voting-active).],
  ),
) <tab:voting-terms>

=== The upgrade cycle <sec:voting-cycle>

The following sequence is informative; the normative rules are in the rest of
the chapter. A summary for users is in the Decred documentation @dcrdocs, and the governance
process that precedes a vote (an off-chain proposal and a Decred Change
Proposal, or DCP) is described in #dcp(0) @dcp0000.

+ A DCP specifies the change and a deployment: a new deployment version $v$,
  an agenda ID, a mask of vote bits, the choices, and start and expire times.
  New node software containing the dormant rules and the deployment is
  released. The software mines blocks of version $v$ (on the main network)
  and casts votes of version $v$.
+ *Proof-of-work upgrade.* The upgrade of the miners is complete for the
  purposes of a deployment of version $v$ once #param("BlockRejectNumRequired")
  (950) of the last #param("BlockUpgradeNumToCheck") (1000) blocks have a block
  version of at least $v$. The same count, applied to version $v + 1$, makes
  blocks of version $v$ and below invalid (@rule:voting-old-block-version).
+ *Proof-of-stake upgrade.* The upgrade of the voters is complete once 75 % of
  the votes in a stake version interval carry vote version $v$. From the
  following interval on, the header stake version of every block must be
  $v$ (@rule:voting-stake-version).
+ *Voting.* At the first rule change interval boundary at which both upgrades
  are complete and the start time has passed, the deployment moves to
  `Started`. During each interval in the `Started` state the votes of version
  $v$ are tallied. If at least #param("RuleChangeActivationQuorum") (4032)
  votes are not abstentions and one choice receives at least 75 % of them, the
  vote is decided: a winning "yes" choice moves the deployment to `LockedIn`,
  a winning "no" choice to `Failed`. Otherwise voting continues in the next
  interval until the expire time passes.
+ *Activation.* A deployment that is `LockedIn` for one interval becomes
  `Active` at the next boundary, and its rules apply to every block from then
  on. The lock-in interval gives everyone the time to upgrade.

On the main network a rule change interval is 8064 blocks (four weeks), so a
successful vote takes at least eight weeks from the start of voting to
activation.

#rationale[
  The design descends from Bitcoin's BIP 9 version bits @bip9, which also
  defines the five threshold states. It differs in who decides: in Decred the
  proof-of-work miners only signal readiness, and the decision is taken by
  the stakeholders through their votes. Abstentions are excluded from
  both the majority calculation and the quorum, so that an uninformed
  or indifferent stakeholder does not bias the outcome in either direction.
]

=== Parameters <sec:voting-params>

@tab:voting-params lists the network parameters used by the algorithms of
this chapter. The complete parameter sets are in #chref("parameters").

#figure(
  caption: [Voting-related network parameters. The last row is a constant of
    the validation code, not a field of the parameters (@sec:voting-block-version).],
  table(
    columns: (1fr, auto, auto, auto, auto),
    align: (left, right, right, right, right),
    table.header([Parameter], [mainnet], [testnet3], [simnet], [regnet]),
    [#param("RuleChangeActivationInterval") (RCI)], [8064], [5040], [320], [320],
    [#param("RuleChangeActivationQuorum")], [4032], [2520], [160], [160],
    [#param("RuleChangeActivationMultiplier")], [3], [3], [3], [3],
    [#param("RuleChangeActivationDivisor")], [4], [4], [4], [4],
    [#param("StakeVersionInterval") (SVI)], [2016], [2016], [112], [112],
    [#param("StakeValidationHeight") (SVH)], [4096], [768], [144], [144],
    [#param("StakeEnabledHeight")], [512], [32], [32], [32],
    [#param("StakeMajorityMultiplier")], [3], [3], [3], [3],
    [#param("StakeMajorityDivisor")], [4], [4], [4], [4],
    [#param("BlockEnforceNumRequired")], [750], [51], [51], [51],
    [#param("BlockRejectNumRequired")], [950], [75], [75], [75],
    [#param("BlockUpgradeNumToCheck")], [1000], [100], [100], [100],
    [#param("TicketsPerBlock")], [5], [5], [5], [5],
    [Latest enforced block version], [11], [12], [12], [12],
  ),
) <tab:voting-params>

#param("StakeEnabledHeight") is listed because it bounds the earliest votes,
but none of the algorithms below consults it directly: they key on
#param("StakeValidationHeight"), the first height at which blocks carry votes
(#chref("staking")). On the main network the quorum is 10 % of the maximum
number of votes in a rule change interval ($8064 times 5 = 40320$).

== Interval Arithmetic <sec:voting-intervals>

Both kinds of interval are aligned to the stake validation height rather than
to height 0. An interval of length $I$ consists of the heights
$"SVH" + k I$ through $"SVH" + (k+1) I - 1$ for an integer $k$; on the main
network the rule change intervals are $[4096, 12159]$, $[12160, 20223]$, and
so on. Every rule in this chapter that consults "the previous interval" uses
the function of @alg:voting-want-height, which returns the height of the last
block of the interval preceding the one that contains height $h$.

#algorithm("Final block of the previous interval", src: "internal/blockchain/stakeversion.go · calcWantHeight")[
  ```python
  def want_height(svh: int64, interval: int64, h: int64) -> int64:
      # Height of the final block of the interval that precedes the interval
      # containing height h.  Intervals start at heights svh + k*interval.
      offset = tmod(svh, interval)
      adjusted = h - offset - 1
      return adjusted - tmod(adjusted + 1, interval) + offset
  ```
] <alg:voting-want-height>

For $h >= "SVH"$ this simplifies to $h - 1 - ((h - "SVH") mod I)$. All
consensus uses of the function satisfy $h >= "SVH"$. The uses that locate
the previous interval of a block (the threshold state and the stake version
interval preceding a block) have $h >= "SVH" + I$, so their result is at
least $"SVH" + I - 1$ and refers to a block whose whole interval lies at or
above the stake validation height; the one use with a smaller argument,
finding the first block of a stake version interval in
@alg:voting-stake-version, has $h >= "SVH" + I - 1$ and a result of at
least $"SVH" - 1$. If $h$ is the first height of an interval, the result is
$h - 1$.

#vector[Previous-interval heights with main-network parameters][
  ```
  RCI = 8064, SVH = 4096                SVI = 2016, SVH = 4096
  want_height(..., 4096)    =   4095    want_height(..., 6111) = 4095
  want_height(..., 12159)   =   4095    want_height(..., 6112) = 6111
  want_height(..., 12160)   =  12159    want_height(..., 6113) = 6111
  want_height(..., 12161)   =  12159    want_height(..., 8127) = 6111
  want_height(..., 20224)   =  20223    want_height(..., 8128) = 8127
  want_height(..., 149247)  = 141183
  want_height(..., 149248)  = 149247
  want_height(..., 1052416) = 1052415
  ```
]

== Block Versions <sec:voting-block-version>

The block version is the miners' signal. It plays three roles: old block
versions become invalid once nearly all miners have upgraded, a deployment
cannot start until nearly all miners mine its version, and the stake version
rules are enforced only once the miners have moved to version 3. All three
use the same count, @alg:voting-pow-majority, over the most recent blocks.

#algorithm("Proof-of-work version majority", src: "internal/blockchain/chain.go · isMajorityVersion")[
  ```python
  def pow_majority(min_version: int32, start: Node | None, required: uint64) -> bool:
      # Counts, among BlockUpgradeNumToCheck blocks ending with `start` and going
      # back through its ancestors (fewer near genesis), those whose header
      # version is >= min_version.  Versions compare as signed 32-bit integers.
      found = 0
      node = start
      i = 0
      while i < BLOCK_UPGRADE_NUM_TO_CHECK and found < required and node is not None:
          if node.header.version >= min_version:
              found += 1
          node = node.parent
          i += 1
      return found >= required
  ```
] <alg:voting-pow-majority>

The early exit once `found` reaches `required` does not change the result. A
block's own version is never part of the count used to judge it: every caller
passes the parent of the block being validated, or an older block.

#rule("Obsolete block versions", src: ("internal/blockchain/validate.go · checkBlockHeaderPositional, isOldBlockVersionByMajority, isDCP0005Violation"))[
  Let $B$ be a block other than the genesis block, $P$ its parent, and $V$ its
  header version (`int32`). Let $L = 11$ on the main network and $L = 12$ on
  every other network. If $V < L$, $B$ is not one of the exempt blocks of
  @tab:voting-dcp5-exempt, and
  `pow_majority(V + 1, P, BlockRejectNumRequired)` holds, then $B$ #MUST be rejected
  (`ErrBlockVersionTooOld`). Blocks with $V >= L$ are never rejected by this
  rule.
] <rule:voting-old-block-version>

On the main network the rule rejects a block of version $V < 11$ once 950 of
the 1000 blocks ending with its parent have version $V + 1$ or higher. Since the
count is monotone in the version, this single comparison is equivalent to
rejecting $V$ when a 95 % majority exists for _any_ version above it.

#figure(
  caption: [Blocks exempt from @rule:voting-old-block-version. They were mined
    with the old version after the version-7 (main network) or version-8
    (testnet3) majority had formed, and were accepted because of a bug in
    software of the time.],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Height], [Condition]),
    [mainnet], [413762], [version 6 and block hash
      #hex("00000000000000002086ed61f62a546f3bfa8f3e567b003f097efa982008c47b")],
    [mainnet], [414036], [version 6 and block hash
      #hex("0000000000000000194fa59310b9e988ecb23de0c716d6e8f1b2aa31d9592387")],
    [mainnet], [424011], [version 6 and block hash
      #hex("0000000000000000317fc6c7a8a6578be7dfa9c96eb81d620050a3732b02d572")],
    [mainnet], [428809], [version 6 and block hash
      #hex("00000000000000003147798ccffcecaa420fb1c7934d8f4e33809a871ee34aaa")],
    [mainnet], [430191], [version 6 and block hash
      #hex("00000000000000002127ad6d4cb30cc16f6344589b417e42650388bb0690a88e")],
    [testnet3], [$<= 323282$], [every block of version 7 whose header height is
      at most 323282],
  ),
) <tab:voting-dcp5-exempt>

Hashes are in display form. The main-network condition compares the header
height field, the block hash and the version; the testnet3 condition compares
only the header height field and the version.

#history[
  The rule was originally a series of explicit checks, one per version ("reject
  version 6 once 95 % are version 7", and so on); dcrd replaced them with a
  loop over the versions in 2020 and with the single comparison above
  in 2022. The block version that the reference
  miner produces has been raised with each set of deployments: version 3 came
  with the stake version mechanism (dcrd source, December 2016), and versions
  4 through 11 came with deployment versions 4 through 11 of the main network.
  On the test networks the miner produces version 12, matching their
  deployment versions, which are one higher than the main network's. The
  heights at which each main-network version reached its majorities are not
  recorded in the sources used for this document.
]

The block version also gates deployments (@sec:voting-threshold): a
deployment of version $v$ cannot move from `Defined` to `Started` until
`pow_majority(v, W, BlockRejectNumRequired)` holds at the end
$W$ of a rule change interval. The block version number is compared directly
with the deployment version number, which is why the reference software mines
blocks whose version equals its newest deployment version.

#pitfall[
  The rule is checked against the parent's ancestry, not against a
  fixed height, so a side chain is judged on its own blocks. dcrd applies it
  to every header when the header is first accepted, including ancestors of
  its configured assumed-valid block: the assume-valid optimization skips only
  the contextual checks listed in #chref("blocks").
]

== Votes, Vote Versions and Vote Bits <sec:voting-votes>

=== The votes of a block <sec:voting-block-votes>

Every block at or above the stake validation height carries votes: vote
transactions (also called SSGen) in its stake tree, whose structure is
specified in #chref("staking"). For this chapter a vote is reduced to a pair
(version, bits) taken from its second output, an `OP_RETURN` script of the
form `OP_RETURN` $||$ push opcode $||$ data.

#rule("Vote bits and vote version", src: ("blockchain/stake/staketx.go · SSGenVoteBits, SSGenVersion, FindSpentTicketsInBlock", "internal/blockchain/blockindex.go · populateTicketInfo"))[
  Let `s` be the script of output 1 of a vote, indexed from 0. The vote bits
  are the unsigned 16-bit little-endian integer formed by the bytes `s[2:4]`.
  The vote version is the unsigned 32-bit little-endian integer formed by the
  bytes `s[4:8]` if $|s| >= 8$, and 0 otherwise. The *votes of block
  $B$* are the (version, bits) pairs of all vote transactions in $B$'s stake
  tree. Every vote counts once, in every tally of this chapter that covers $B$.
] <rule:voting-vote-fields>

The structural rules of #chref("staking") guarantee that `s[0]` is
`OP_RETURN`, that `s[1]` is a single-byte push opcode of 2 to 75 bytes, and
that $4 <= |s| <= 77$, so the two vote-bits bytes always exist. No consensus
rule restricts the vote version: any value is valid, and votes whose version
does not match a deployment are simply not counted for it. The vote version
occupies the first four bytes of what #chref("staking") calls the extended
vote bits; no rule of this chapter interprets the bytes after it.

=== Layout of the vote bits <sec:voting-bits-layout>

#figure(
  caption: [Use of the 16 vote bits],
  table(
    columns: (auto, 1fr),
    table.header([Bits], [Use]),
    [0], [Approval of the regular transaction tree of the parent block
      (`1` = approve). This bit is not part of any agenda; its consensus
      effect is specified in #chref("blocks") and #chref("staking").],
    [1–15], [Agenda choices. Each deployment owns a mask of consecutive bits;
      the masks of the deployments sharing a deployment version are disjoint.
      Bits outside every mask of the vote's version carry no meaning.],
  ),
) <tab:voting-bits>

Because masks are only required to be disjoint within one deployment version,
different versions reuse the same bits: bits 1 and 2 (mask `0x0006`) carry
`sdiffalgorithm` for version 4, `lnfeatures` for version 5, and so on. The
vote version selects which deployments a vote addresses.

=== Choices <sec:voting-choices>

A deployment's vote has an ordered list of choices. Each has an ID, a bit
pattern within the mask, and two flags: `IsAbstain` marks the abstain choice
and `IsNo` marks the choice that rejects the change. A choice with neither
flag is a passing choice. Every deployment defined on any network has exactly
three choices: index 0 `abstain` (bits `0x0000`, `IsAbstain`), index 1 `no`
(`IsNo`) and index 2 `yes`. A deployment could define several passing
choices, and the tally supports that, but none has.

The tally does not look up a vote's bit pattern in the choice list. It
decodes the vote bits to a choice _index_,

```python
idx = (bits & mask) >> trailing_zeros16(mask)
```

where `trailing_zeros16` is the number of trailing zero bits of the 16-bit
mask. A vote whose index is not smaller than the number of choices is
_invalid_ for that deployment and is ignored entirely; it counts neither as a
choice nor toward the quorum. For this to agree with the bit patterns, the
choice at index `i` must have bits `i << trailing_zeros16(mask)`; every
deployment defined on every network satisfies this, as checked by the
program that generated the tables of @sec:voting-deployments.

#rule("Well-formed deployments", src: ("internal/blockchain/agendas.go · makeAgendas, validateDeploymentChoices, determineForcedThresholdState", "internal/blockchain/agendas.go · makeHistoricalAgendas"))[
  The deployments of a network #MUST satisfy all of the following; dcrd
  refuses to start with parameters that violate any of them.
  + Agenda IDs are unique across all deployment versions.
  + Within one deployment version, the masks are pairwise disjoint.
  + A mask is non-zero, does not include bit 0, and consists of one run of
    consecutive set bits.
  + The number of choices is at most $2^p$, where $p$ is the number of bits
    in the mask.
  + Every choice has a non-empty ID; choice IDs are unique within the vote,
    compared case-insensitively.
  + Every choice except the abstain choice has non-zero bits; every choice's
    bits are a subset of the mask.
  + No choice has both `IsAbstain` and `IsNo`; exactly one choice has
    `IsAbstain` and exactly one has `IsNo`.
  + A forced choice, if given, names an existing choice that is not the
    abstain choice. Forced choices are not permitted on the main network.
  + A historical activation (@tab:voting-anchors) names an agenda that has a
    deployment without a forced choice, and a winning choice that exists and
    is not the abstain choice. (An entry whose winning choice is the `no`
    choice would be ignored; every entry in @tab:voting-anchors names `yes`.)
] <rule:voting-well-formed>

These conditions do not require the abstain choice to have bits `0x0000` or
to come first, nor do they require the index property above; an
implementation that adds deployments of its own must ensure the latter, or
reproduce the index-based decoding exactly.

#vector[Decoding vote bits for the four main-network version-9 deployments][
  ```
              reverttreasury-  explicitver-   autorevocations  changesubsidy-
              policy           upgrades                        split
  vote bits   mask 0x0006      mask 0x0018    mask 0x0060      mask 0x0180
  0x0001      0 abstain        0 abstain      0 abstain        0 abstain
  0x0015      2 yes            2 yes          0 abstain        0 abstain
  0x0155      2 yes            2 yes          2 yes            2 yes
  0x00ab      1 no             1 no           1 no             1 no
  0x0007      3 invalid        0 abstain      0 abstain        0 abstain
  ```
  Each entry is the decoded index and the choice; an invalid index is
  ignored by the tally. Bit 0 (parent approval) is set in all five examples
  and plays no part in the decoding.
]

== Stake Version <sec:voting-stake-version>

The header stake version records which vote version a qualified majority of
the voters uses. Because the votes of earlier blocks are on the chain, the
value is computable by every node, and once a 75 % majority of miners mine
version 3 blocks the header field #MUST equal the computed value. The
threshold state machine then reads the computed value to decide whether the
voters have upgraded for a deployment.

The computation for a block $B$ with parent $P$ proceeds in three steps.

+ Find the most recent stake version interval that ends before the interval
  containing $B$ and in which one vote version accounts for at least 75 % of
  all votes. If no interval qualifies, the result is 0.
+ Return 0 unless 950 of the 1000 blocks ending with the _first_ block of
  that interval have block version 3 or higher (main-network values).
+ Prevent regression: if at least 75 % of the headers in that interval
  already carry a stake version of at least the voter majority version, and
  a header stake version with a 75 % majority among those headers is higher
  still, return that higher header version instead.

#algorithm("Required header stake version", src: ("internal/blockchain/stakeversion.go · findStakeVersionPriorNode, calcVoterVersionInterval, calcVoterVersion", "internal/blockchain/stakeversion.go · isStakeMajorityVersion, calcPriorStakeVersion, calcStakeVersion"))[
  ```python
  def prior_svi_end(prev: Node) -> Node | None:
      # Final block of the stake version interval preceding the one that
      # contains the block after `prev`.
      h = prev.height + 1
      if h < SVH + SVI:
          return None
      return prev.ancestor(want_height(SVH, SVI, h))

  def svi_blocks(end: Node) -> list[Node]:
      # The SVI blocks ending with `end` (all at or above SVH when used below).
      return [end.ancestor(end.height - i) for i in range(SVI)]

  def voter_majority(end: Node) -> uint32 | None:
      total = 0                                    # int32 in dcrd; cannot overflow
      count = {}                                   # vote version -> number of votes
      for node in svi_blocks(end):
          total += len(node.votes)
          for vote in node.votes:
              count[vote.version] = count.get(vote.version, 0) + 1
      required = total * STAKE_MAJORITY_MULTIPLIER // STAKE_MAJORITY_DIVISOR
      for version, n in count.items():             # at most one can qualify
          if n >= required:
              return version
      return None

  def voter_version(prev: Node) -> tuple[uint32, Node | None]:
      node = prior_svi_end(prev)
      while node is not None and node.height >= SVH:
          v = voter_majority(node)
          if v is not None:
              return (v, node)
          node = node.ancestor(node.height - SVI)  # one interval further back
      return (0, None)

  def headers_at_least(min_version: uint32, end: Node) -> bool:
      # `end` is the final block of a stake version interval.
      n = sum(1 for node in svi_blocks(end) if node.header.stake_version >= min_version)
      return n >= SVI * STAKE_MAJORITY_MULTIPLIER // STAKE_MAJORITY_DIVISOR

  def header_majority(end: Node) -> uint32:
      count = {}
      for node in svi_blocks(end):
          v = node.header.stake_version
          count[v] = count.get(v, 0) + 1
      required = SVI * STAKE_MAJORITY_MULTIPLIER // STAKE_MAJORITY_DIVISOR
      for version, n in count.items():
          if n >= required:
              return version
      return 0                                     # no header majority

  def required_stake_version(prev: Node) -> uint32:
      # The stake version required in the header of the block after `prev`.
      version, end = voter_version(prev)
      if version == 0 or end is None:
          return 0
      first = end.ancestor(want_height(SVH, SVI, end.height) + 1)
      if not pow_majority(3, first, BLOCK_REJECT_NUM_REQUIRED):
          return 0
      if headers_at_least(version, end):
          prior = header_majority(end)
          if prior > version:
              version = prior
      return version
  ```
] <alg:voting-stake-version>

`first` is the first block of the interval ending at `end`, since
`want_height(SVH, SVI, end.height)` is the final block of the interval before
it. The interval end found by `voter_version` is always at height
$"SVH" + k dot "SVI" - 1$ for some $k >= 1$, so every window examined lies
entirely at or above the stake validation height. On the main network a
voter majority needs 75 % of at least $3 times 2016$ votes (a block at or
above the stake validation height carries at least three votes), and a header majority
needs $floor(2016 times 3 slash 4) = 1512$ headers.

#rule("Header stake version", src: "internal/blockchain/validate.go · checkBlockHeaderContext")[
  Let $B$ be a block other than the genesis block and $P$ its parent. If $B$'s
  header version is at least 3 and
  `pow_majority(3, P, BlockEnforceNumRequired)` holds, the header stake version of $B$
  #MUST equal `required_stake_version(P)` (`ErrBadStakeVersion`). Otherwise
  the header stake version is unconstrained.
] <rule:voting-stake-version>

On the main network the condition is that 750 of the 1000 blocks ending with
the parent have version 3 or higher. Note
the two different thresholds: the stake version is _enforced_ once 75 % of
recent blocks are version 3 (#param("BlockEnforceNumRequired")), but it is
_non-zero_ only once 95 % of the blocks ending with the start of the relevant
stake version interval are (#param("BlockRejectNumRequired")).

#pitfall[
  `voter_majority` counts _all_ votes, whatever their version, in the total,
  and requires $"count" >= floor(3 "total" slash 4)$ with truncating integer
  division. With at least three votes the qualifying version, if any, is
  unique, so the iteration order of the tally (a hash map in dcrd) does not
  matter. The same holds for `header_majority`, whose total is the fixed
  interval length.
]

#pitfall[
  The stake version never decreases while the header majority holds: once 75
  % of an interval's headers carry version $v$, later intervals whose voter
  majority is a lower version $u$ still yield $v$, because
  `headers_at_least(u, end)` holds and `header_majority(end)` returns $v > u$. dcrd's test
  `TestCalcStakeVersionCorners` exercises this sequence and its assertions
  are consistent with it: vote versions 2, 4, 2
  (three intervals each), then 5 for two intervals, then 4 for two
  intervals; the required version at the end of these five phases is 2, 4,
  4, 5, 5. A lower voter majority is adopted only if the higher
  header version itself has lost its 75 % header majority, which cannot
  happen while miners follow the rule.
]

#vector[Stake version on a simulated regression-network chain][
  ```
  network     regnet: SVH 144, SVI 112, RCI 320, BlockRejectNumRequired 75 of 100
  blocks      every block has block version 12 and the required stake version;
              blocks at heights >= 144 carry 5 votes of version 12
  result      required_stake_version(P) is 0 for blocks at heights 1 .. 255
              and 12 from height 256 on (first SVI window 144 .. 255)
  ```
  Produced by running dcrd's `calcStakeVersion` over a chain of block index
  nodes. The threshold states on the same chain are given in
  @sec:voting-majority.
]

== The Threshold State Machine <sec:voting-threshold>

=== States <sec:voting-states>

Each deployment has, for every block, a threshold state together with a
choice ID (@tab:voting-states). The state applies to whole rule change
intervals: all blocks of one interval share it, and it is a function of the
blocks up to and including the last block of the _preceding_ interval.

#figure(
  caption: [Threshold states],
  table(
    columns: (auto, 1fr, auto),
    table.header([State], [Meaning], [Choice ID]),
    [`Defined`], [Initial state. The start time has not passed or the upgrade
      conditions are not met. The genesis interval and every block below
      $"SVH" + "RCI"$ are in this state.], [empty],
    [`Started`], [Votes cast in this interval are tallied at its end.], [empty],
    [`LockedIn`], [A passing choice won. The interval runs without further
      tallying.], [winning choice],
    [`Active`], [The change is in force. Terminal.], [winning choice],
    [`Failed`], [The vote expired or the `no` choice won. Terminal.], [the
      `no` choice if it won; empty if expired],
  ),
) <tab:voting-states>

#let vt-box(x, y, name) = place(dx: x * 1cm, dy: y * 1cm, rect(
  width: 2.6cm,
  height: 0.95cm,
  radius: 3pt,
  stroke: 0.8pt + palette.ink,
  fill: palette.wash-blue,
  inset: 0pt,
  align(center + horizon, text(font: sans, size: 8.5pt, weight: "semibold", fill: palette.ink, name)),
))
#let vt-seg(x1, y1, x2, y2) = place(line(
  start: (x1 * 1cm, y1 * 1cm),
  end: (x2 * 1cm, y2 * 1cm),
  stroke: 0.8pt + palette.ink,
))
#let vt-arrow(x1, y1, x2, y2) = {
  let ang = calc.atan2(x2 - x1, y2 - y1)
  let ux = calc.cos(ang)
  let uy = calc.sin(ang)
  let l = 0.22
  let w = 0.085
  vt-seg(x1, y1, x2 - l * ux, y2 - l * uy)
  place(polygon(
    fill: palette.ink,
    stroke: none,
    (x2 * 1cm, y2 * 1cm),
    ((x2 - l * ux + w * uy) * 1cm, (y2 - l * uy - w * ux) * 1cm),
    ((x2 - l * ux - w * uy) * 1cm, (y2 - l * uy + w * ux) * 1cm),
  ))
}
#let vt-label(x, y, n) = place(dx: x * 1cm - 0.22cm, dy: y * 1cm - 0.22cm, box(
  width: 0.44cm,
  height: 0.44cm,
  radius: 0.22cm,
  fill: white,
  stroke: 0.6pt + palette.teal,
  align(center + horizon, text(font: sans, size: 7pt, weight: "semibold", fill: palette.teal, str(n))),
))

#figure(
  caption: [Threshold state transitions. Transitions happen only at the
    boundary between two rule change intervals; the numbers refer to
    @tab:voting-transitions.],
  block(width: 15.6cm, height: 5.5cm, {
    vt-box(0.3, 1.0, [Defined])
    vt-box(4.6, 1.0, [Started])
    vt-box(8.9, 1.0, [LockedIn])
    vt-box(12.9, 1.0, [Active])
    vt-box(4.6, 4.3, [Failed])
    // self loops on Defined and Started
    vt-seg(1.1, 1.0, 1.1, 0.35)
    vt-seg(1.1, 0.35, 2.1, 0.35)
    vt-arrow(2.1, 0.35, 2.1, 1.0)
    vt-label(1.6, 0.35, 1)
    vt-seg(5.4, 1.0, 5.4, 0.35)
    vt-seg(5.4, 0.35, 6.4, 0.35)
    vt-arrow(6.4, 0.35, 6.4, 1.0)
    vt-label(5.9, 0.35, 4)
    // forward transitions
    vt-arrow(2.9, 1.475, 4.6, 1.475)
    vt-label(3.75, 1.475, 2)
    vt-arrow(7.2, 1.475, 8.9, 1.475)
    vt-label(8.05, 1.475, 5)
    vt-arrow(11.5, 1.475, 12.9, 1.475)
    vt-label(12.2, 1.475, 7)
    // to Failed
    vt-arrow(1.6, 1.95, 4.6, 4.55)
    vt-label(3.1, 3.25, 3)
    vt-arrow(5.9, 1.95, 5.9, 4.3)
    vt-label(5.9, 3.1, 6)
  }),
) <fig:voting-states>

=== When and over which blocks the state is evaluated <sec:voting-windows>

Let $B$ be a block other than the genesis block and $h$ its height.

- If $h < "SVH" + "RCI"$, every deployment is `Defined` for $B$ (forced and
  historical cases aside, @sec:voting-activation).
- Otherwise let $W$ be the ancestor of $B$ at height
  `want_height(SVH, RCI, h)`: the last block of the rule change interval
  before the one containing $B$. The state for $B$ is the state _computed at_
  $W$, written $S(W)$ below.

$S(W)$ is defined recursively from $S(W')$, where $W'$ is the ancestor of $W$
one interval earlier (height $W.h - "RCI"$), by the transitions of
@tab:voting-transitions. The recursion bottoms out when $W'$ does not exist
(negative height) or when the median time of $W$ is before the start time.
All times are compared as unsigned 64-bit integers: the *median time* of a
block, written $"MTP"(W)$, is the median of the timestamps of $W$ and its ten
predecessors, as defined in #chref("blocks"), and the start and expire times
are the deployment's #raw("StartTime") and #raw("ExpireTime").

On the main network, $W$ ranges over the heights $4095 + 8064 k$. The first
block whose state can differ from `Defined` is at height
$4096 + 8064 = 12160$, judged at $W = 12159$.

#figure(
  caption: [Transitions at the end $W$ of a rule change interval, for a
    deployment of version $v$. Conditions in a row are tested in the order
    listed; the first row whose condition holds applies.],
  table(
    columns: (auto, auto, 1fr, auto),
    table.header([\#], [From], [Condition at $W$], [To]),
    [–], [any], [$"MTP"(W) < "StartTime"$ (no recursion)], [`Defined`],
    [1], [`Defined`], [$W.h < "SVH"$], [`Defined`],
    [3], [`Defined`], [$"MTP"(W) >= "ExpireTime"$], [`Failed`],
    [1], [`Defined`], [`required_stake_version(W)` $< v$], [`Defined`],
    [1], [`Defined`], [not `pow_majority(v, W, BlockRejectNumRequired)`], [`Defined`],
    [2], [`Defined`], [otherwise ($"MTP"(W) >= "StartTime"$ holds)], [`Started`],
    [6], [`Started`], [$"MTP"(W) >= "ExpireTime"$], [`Failed`],
    [4], [`Started`], [non-abstaining votes in the interval ending at $W$ fewer
      than #param("RuleChangeActivationQuorum")], [`Started`],
    [5], [`Started`], [first passing choice (in choice order) with at least the
      threshold of votes], [`LockedIn`],
    [6], [`Started`], [the `no` choice has at least the threshold of votes],
      [`Failed`],
    [4], [`Started`], [otherwise], [`Started`],
    [7], [`LockedIn`], [always], [`Active`],
    [–], [`Active`, `Failed`], [always], [unchanged],
  ),
) <tab:voting-transitions>

#algorithm("Threshold state of a deployment", src: ("internal/blockchain/thresholdstate.go · nextThresholdState", "internal/blockchain/blockindex.go · CalcPastMedianTime"))[
  ```python
  DEFINED, STARTED, LOCKED_IN, ACTIVE, FAILED = range(1, 6)

  def deployment_state(d, B: Node) -> tuple[int, str]:
      # State and choice ID of deployment d for block B (B is not genesis).
      if B.height < SVH + RCI:
          return (DEFINED, "")
      W = B.parent.ancestor(want_height(SVH, RCI, B.height))
      return state_at(d, W)

  def state_at(d, W: Node | None) -> tuple[int, str]:
      # State that applies to the RCI blocks following the interval end W.
      if W is None:
          return (DEFINED, "")
      if uint64(mtp(W)) < d.start_time:
          return (DEFINED, "")
      prev_state, prev_choice = state_at(d, W.ancestor(W.height - RCI))  # None if < 0
      return transition(d, prev_state, prev_choice, W)

  def transition(d, state: int, choice: str, W: Node) -> tuple[int, str]:
      t = uint64(mtp(W))
      if state == DEFINED:
          if W.height < SVH:
              return (DEFINED, "")
          if t >= d.expire_time:
              return (FAILED, "")
          if required_stake_version(W) < d.version:
              return (DEFINED, "")
          if not pow_majority(int32(d.version), W, BLOCK_REJECT_NUM_REQUIRED):
              return (DEFINED, "")
          if t >= d.start_time:                    # always true at this point
              return (STARTED, "")
          return (DEFINED, "")

      if state == STARTED:
          if t >= d.expire_time:
              return (FAILED, "")
          shift = trailing_zeros16(d.mask)
          counts = [0] * len(d.choices)            # uint32
          non_abstain = 0                          # uint32
          node = W
          for i in range(RCI):                     # the RCI blocks ending with W
              for vote in node.votes:
                  if vote.version != d.version:
                      continue
                  idx = (vote.bits & d.mask) >> shift
                  if idx > len(d.choices) - 1:
                      continue                     # invalid choice: ignored
                  counts[idx] += 1
                  if not d.choices[idx].is_abstain:
                      non_abstain += 1
              node = node.parent
          if non_abstain < RULE_CHANGE_ACTIVATION_QUORUM:
              return (STARTED, "")
          threshold = non_abstain * RULE_CHANGE_ACTIVATION_MULTIPLIER \
              // RULE_CHANGE_ACTIVATION_DIVISOR
          for idx, c in enumerate(d.choices):
              if c.is_abstain or counts[idx] < threshold:
                  continue
              if c.is_no:
                  return (FAILED, c.id)
              return (LOCKED_IN, c.id)
          return (STARTED, "")

      if state == LOCKED_IN:
          return (ACTIVE, choice)
      return (state, choice)                       # ACTIVE and FAILED are terminal
  ```
] <alg:voting-threshold>

#rule("Threshold state", src: ("internal/blockchain/thresholdstate.go · nextThresholdState, agendaState"))[
  For a deployment $d$ that has no forced choice, the threshold state of $d$
  for a block $B$ other than the genesis block is `deployment_state(d, B)` of
  @alg:voting-threshold, using the vote fields of @rule:voting-vote-fields,
  `required_stake_version` of @alg:voting-stake-version, `pow_majority` of
  @alg:voting-pow-majority and the median time of #chref("blocks").
] <rule:voting-threshold>

The tally window of a `Started` interval is exactly that interval: if $W$ is
the end of an interval in the `Started` state, the blocks counted are
$W.h - "RCI" + 1$ through $W.h$, which are the blocks whose state was
`Started` (computed at the previous interval end). Votes for a deployment are
therefore counted only while it is `Started`, and votes cast before voting
started never count.

=== Quorum and majority <sec:voting-majority>

The quorum counts the valid votes of the deployment's version whose choice is
not the abstain choice; that is, the votes for `yes` and `no` together.
Abstentions, votes of other versions and votes with an invalid choice index
are not counted. With $N$ such votes and $N >=$
#param("RuleChangeActivationQuorum"), a choice wins if its count $c$
satisfies

$ c >= floor(N dot "RuleChangeActivationMultiplier" / "RuleChangeActivationDivisor"), $ <eq:voting-majority>

computed in unsigned 32-bit arithmetic with truncation. The product cannot
overflow: $N$ is at most $"RCI" times "TicketsPerBlock" = 40320$ on the main
network. The threshold is the truncated product, not a rounded-up 75 %:
with $N = 4033$ the threshold is 3024, which is 74.98 % of $N$.

#vector[Majority thresholds with main-network parameters (quorum 4032, 3/4)][
  ```
  non-abstaining votes N    4031    4032    4033    4035    40320
  threshold floor(3N/4)     3023    3024    3024    3026    30240
  quorum met                no      yes     yes     yes     yes
  ```
]

If the quorum is met but no choice reaches the threshold, the deployment
stays `Started` and the next interval is tallied afresh; votes do not carry
over between intervals. Since the threshold exceeds half of $N$ whenever
$N >= 3$, at most one choice can reach it, so the choice order matters only
in principle.

#note[
  dcrd's informational vote-count queries (the `getvoteinfo` RPC) count a
  vote with an invalid choice index as an abstention and include it in the
  total. The consensus tally ignores such votes entirely. Figures from the
  RPC are therefore not always the inputs of @alg:voting-threshold.
]

#pitfall[
  Several details in @alg:voting-threshold are easy to get wrong:
  - The expire time is tested _before_ the tally. If $"MTP"(W)$ is at or past
    the expire time, the deployment fails even if the votes of the interval
    ending at $W$ reached the threshold.
  - A deployment can fail without ever starting: the expire check in the
    `Defined` state comes before the version checks.
  - The upgrade conditions (stake version and block version) are checked only
    in the `Defined` state. Once `Started`, a deployment keeps being tallied
    whatever later happens to the versions, and a later deployment version
    does not stop an earlier, undecided one; but votes of the later version
    no longer count for it, because the version comparison is exact.
  - `required_stake_version(W)` is the stake version required for the block
    _after_ $W$; it is computed from the stake version interval that ends at
    or before $W$. When an RCI boundary and an SVI boundary coincide, the
    interval ending exactly at $W$ is used.
  - `LockedIn` becomes `Active` unconditionally after exactly one interval:
    no expire check, no tally.
  - The state machine depends only on the ancestors of the block. Two blocks
    at the same height on different branches can have different states.
]

#note[
  Median time is non-decreasing along a chain, because each block's timestamp
  must exceed the median time of its parent (#chref("blocks")). Consequently, for a
  deployment whose expire time is not before its start time (true of every
  deployment dcrd defines), the early return for $"MTP"(W) < "StartTime"$
  in `state_at` never discards a state other than `Defined`. The early return
  is nevertheless part of the algorithm. dcrd evaluates the recursion iteratively from
  the oldest uncomputed interval and caches the result for each interval-end
  block; the cache is an optimization only.
]

#vector[Threshold states on a simulated regression-network chain][
  ```
  network     regnet: SVH 144, SVI 112, RCI 320, quorum 160, threshold 3/4
  blocks      block version 12, header stake version as required;
              blocks at heights >= 144 carry 5 votes each, vote version 12,
              vote bits 0x0005 (approve parent; maxtreasuryspend "yes")
  required stake version     0 for heights 1..255, 12 from 256

  maxtreasuryspend (v12)     Defined   heights    1 ..  463
                             Started   heights  464 ..  783   (judged at W = 463)
                             LockedIn  heights  784 .. 1103   (choice "yes")
                             Active    heights 1104 ..
  blake3pow (v11)            Defined   heights    1 ..  463
                             Started   heights  464 ..        (no further change:
                                       votes of version 12 do not count for v11)
  ```
  Produced by running dcrd's `nextThresholdState` over a chain of block index
  nodes. The first interval that can be `Started` begins at
  $"SVH" + "RCI" = 464$.
]

== Agenda Activation <sec:voting-activation>

Agenda-dependent rules consult a single predicate: whether the agenda is
active for the block being validated. It is normally the threshold state of
the agenda's deployment, but dcrd also supports forced outcomes for test
networks, default outcomes for agendas that a network does not define, and
hard-coded historical activation points.

#rule("Agenda activity for a block", src: ("internal/blockchain/agendas.go · isAgendaActive, isAgendaActivePositional, isTreasuryAgendaActive", "internal/blockchain/agendas.go · makeAgendas", "internal/blockchain/thresholdstate.go · agendaState"))[
  An agenda $a$ is *active for* block $B$ if and only if the first applicable
  case below says so:
  + If $B$ is the genesis block, $a$ is not active.
  + If $a$ is `treasury` and $B$ has height 1, $a$ is not active.
  + If $a$ has a *forced state* on the network (@tab:voting-forced), $a$ is
    active if and only if that state is `Active`.
  + If $a$ has a *historical anchor* on the network (@tab:voting-anchors) with
    height $h_A$ and hash $H_A$: if $B.h - 1 < h_A$, $a$ is not active; if the
    ancestor of $B$ at height $h_A$ has hash $H_A$, $a$ is active; otherwise
    continue with case 5.
  + $a$ is active if and only if the threshold state of its deployment for $B$
    (@rule:voting-threshold) is `Active`.
] <rule:voting-active>

The choice ID of the winning choice does not enter the predicate: every
agenda defined so far has a single passing choice.

#figure(
  caption: [Forced states. A forced state replaces the threshold state for
    every block except the genesis block.],
  table(
    columns: (1fr, 4.2cm, 2.8cm),
    table.header([Source], [Applies to], [Forced state]),
    [#raw("ForcedChoiceID") set to a passing choice], [the deployment's agenda
      (not allowed on the main network)], [`Active`],
    [#raw("ForcedChoiceID") set to the `no` choice], [the deployment's agenda
      (not allowed on the main network)], [`Failed`],
    [agenda required by the software but with no deployment on the network],
      [main network], [`Defined`],
    [agenda required by the software but with no deployment on the network],
      [all other networks], [`Active` (empty choice)],
  ),
) <tab:voting-forced>

The agendas required by the software are the thirteen agendas of
@tab:voting-consumers other than `lnsupport`. In the current parameters the
default case arises twice: `maxblocksize` has no deployment on the main
network (so it is never active there) and none on testnet3 (so it is active
there, without effect because testnet3 defines a single block size).
Forced `yes` choices are used for every deployment on simnet and for
`sdiffalgorithm` and `lnfeatures` on testnet3. Under case 2, the `treasury`
agenda on simnet is active from height 2, every other forced agenda from
height 1.

#figure(
  caption: [Historical activation anchors. The anchor is the parent of the
    first block for which the agenda is active, so the activation height is
    the anchor height plus one. Hashes are in display form.],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Agenda], [Anchor], [Active from], [Anchor block hash]),
    table.cell(colspan: 4)[_mainnet_],
    [`sdiffalgorithm`], [149247], [149248], [#hex("0000000000000139582d056bc20bb352f4e9b248acbb202724f46000e59c9f75")],
    [`lnsupport`], [149247], [149248], [#hex("0000000000000139582d056bc20bb352f4e9b248acbb202724f46000e59c9f75")],
    [`lnfeatures`], [189567], [189568], [#hex("000000000000005ca2ebe4ef0649128e1cd16d063f80c884cbd865d3af2300ae")],
    [`fixlnseqlocks`], [342783], [342784], [#hex("000000000000000017c053b63c7ae9bb8e73ee1c13ef3da493042a7a05d7401c")],
    [`headercommitments`], [431487], [431488], [#hex("0000000000000000225b8f795704d4ebc484fad4ab09eec615fb44b4a95c3c26")],
    [`treasury`], [552447], [552448], [#hex("000000000000000012d3e57c450f632a9877a28534dbffbf85d41a78aadb9acb")],
    [`reverttreasurypolicy`], [657279], [657280], [#hex("00000000000000000669da8bbb90dad39a2fd889cbdda00bf259776af822fcaa")],
    [`explicitverupgrades`], [657279], [657280], [#hex("00000000000000000669da8bbb90dad39a2fd889cbdda00bf259776af822fcaa")],
    [`autorevocations`], [657279], [657280], [#hex("00000000000000000669da8bbb90dad39a2fd889cbdda00bf259776af822fcaa")],
    [`changesubsidysplit`], [657279], [657280], [#hex("00000000000000000669da8bbb90dad39a2fd889cbdda00bf259776af822fcaa")],
    [`blake3pow`], [794367], [794368], [#hex("0000000000000000c293d8c67409d05e960447ea25cdaf770e864d995c764ef0")],
    [`changesubsidysplitr2`], [794367], [794368], [#hex("0000000000000000c293d8c67409d05e960447ea25cdaf770e864d995c764ef0")],
    [`maxtreasuryspend`], [1052415], [1052416], [#hex("bc1b84dcfd532a01fbd42470d0668fcdbc7e6e4e9108218f55025d9e565dfaea")],
    table.cell(colspan: 4)[_testnet3_],
    [`fixlnseqlocks`], [136847], [136848], [#hex("0000000004232de037b11ee39641910ae0fd0becb968f76f20a40cb7fa64f475")],
    [`headercommitments`], [323327], [323328], [#hex("0000002438f7146f7dbfea248b4c94c4c35a8c714442a589110f4c7513a6b26a")],
    [`treasury`], [560207], [560208], [#hex("0000004f5b6cefb4b5c0ae9dd7a92a431c2de697d22aed9215fe595ac8c1ec23")],
    [`reverttreasurypolicy`], [867647], [867648], [#hex("0000000036af134886ea61aecea318c1f18f349d3acbf2a8c40ced62854b057b")],
    [`explicitverupgrades`], [867647], [867648], [#hex("0000000036af134886ea61aecea318c1f18f349d3acbf2a8c40ced62854b057b")],
    [`autorevocations`], [867647], [867648], [#hex("0000000036af134886ea61aecea318c1f18f349d3acbf2a8c40ced62854b057b")],
    [`changesubsidysplit`], [877727], [877728], [#hex("000000000000e9528cd8a67898b2c02c854c825a3d09c0d83296f051d8c2adac")],
    [`blake3pow`], [1170047], [1170048], [#hex("000000b396bfeaa6ae6fa9e3cee441d7215191630bdaa9b979a872985caed727")],
    [`changesubsidysplitr2`], [1170047], [1170048], [#hex("000000b396bfeaa6ae6fa9e3cee441d7215191630bdaa9b979a872985caed727")],
    [`maxtreasuryspend`], [1805087], [1805088], [#hex("f3e25c6c40baaed62b27ad4f8c0ed6be89bc6890b415089e33acf7783ded248d")],
  ),
) <tab:voting-anchors>

Every anchor height is the last block of a rule change interval
($4095 + 8064 k$ on the main network, $767 + 5040 k$ on testnet3), as an
`Active` state must begin at an interval boundary. On the chain that contains
the anchor block, case 4 of @rule:voting-active gives exactly the result of
the vote tally; the anchors record facts of the chain rather than changing
any outcome, and let a node decide activation without the vote data of old
blocks. Off that chain they differ in one respect: a block whose parent is
below the anchor height is treated as not active even on a branch where the
tally would say otherwise. Such a branch would have to fork from the main
chain below the anchor height and lock the agenda in earlier than the main
chain did. For anchors older than dcrd's fork-rejection checkpoint (two
weeks of blocks before the hard-coded assumed-valid block, #chref("blocks"))
such a fork is rejected anyway; for newer anchors, such as that of
`maxtreasuryspend` at the pinned commit, case 4 is what decides. An
implementation #MUST apply case 4 as stated to agree with dcrd on every
branch.

=== Which block's state each rule consults <sec:voting-consumers>

Every agenda-dependent rule in dcrd asks whether the agenda is active for a
specific block, always passing that block's parent to the query function,
whose result is defined for the block _after_ the node passed. In the terms
of this document, @tab:voting-consumers states the block $B$ for which each
rule evaluates @rule:voting-active.

#figure(
  caption: [Consumers of each agenda. $B$ is the block being validated.],
  table(
    columns: (auto, 1fr, 3.4cm),
    table.header([Agenda], [Effect (specified in)], [Active for]),
    [`maxblocksize`], [Maximum block size becomes the second entry of
      #param("MaximumBlockSizes") if the network defines two (simnet,
      regnet); otherwise no effect (#chref("blocks"))], [$B$],
    [`sdiffalgorithm`], [Stake difficulty algorithm of #dcp(1) for $B$'s
      `SBits` (#chref("difficulty"))], [$B$],
    [`lnsupport`], [None; a non-binding poll], [–],
    [`lnfeatures`], [`OP_SHA256` and `OP_CHECKSEQUENCEVERIFY` script flags;
      sequence-lock enforcement for both trees; lock-time finality judged
      against the median time of $B$'s parent instead of $B$'s timestamp
      (#chref("script"), #chref("transactions"), #chref("blocks"))], [$B$],
    [`fixlnseqlocks`], [None in current dcrd: the corrected sequence-lock view
      of #dcp(4) is applied to every block (#chref("transactions"))], [–],
    [`headercommitments`], [Combined merkle root and commitment root in the
      header (#chref("blocks"), #chref("filters"))], [$B$],
    [`treasury`], [Treasury transactions, opcodes, treasurybase and
      treasury-spend checks (#chref("treasury"))], [$B$; and $B$'s parent
      when disconnecting the parent's regular tree on disapproval],
    [`reverttreasurypolicy`], [Expenditure limit of #dcp(7) for the treasury
      spends in a treasury vote interval block $B$ (#chref("treasury"))], [$B$],
    [`explicitverupgrades`], [Maximum transaction and script versions
      (@sec:voting-dcp8, #chref("transactions"))], [$B$],
    [`autorevocations`], [Automatic revocations of #dcp(9)
      (#chref("staking"))], [$B$],
    [`changesubsidysplit`], [Subsidy split of #dcp(10) unless
      `changesubsidysplitr2` is also active (#chref("subsidy"))], [$B$],
    [`blake3pow`], [Proof-of-work hash and ASERT difficulty for $B$; the ASERT
      anchor is the last block for which the agenda is not active, or block 1
      where the agenda is forced active (#chref("difficulty"))], [$B$],
    [`changesubsidysplitr2`], [Subsidy split of #dcp(12)
      (#chref("subsidy"))], [$B$],
    [`maxtreasuryspend`], [Expenditure limit of #dcp(13), taking precedence over
      #dcp(7) (#chref("treasury"))], [$B$],
  ),
) <tab:voting-consumers>

#pitfall[
  The rule for a block is selected by the agenda's activity _for that
  block_, which by construction depends only on its ancestors. An
  implementation that evaluates the state "at" the block (including the
  block's own votes) or "at the tip" will activate rules one block, or one
  interval, early or late. The one rule that looks at a different block is
  the treasury check applied when a block disapproves its parent: the
  parent's regular tree is unwound under the treasury activity _for the
  parent_.
]

== Explicit Version Upgrades (DCP-0008) <sec:voting-dcp8>

Before #dcp(8) @dcp0008, transactions of any version up to 65535 and
regular-transaction output scripts of any script version up to 65535 were
valid; unknown versions were treated like the newest known transaction
version, and scripts of unknown version were considered valid without being
executed. That permits soft forks, where old nodes accept data whose meaning
they do not know, and it makes version numbers useless as an indication of
which rules apply. Once the `explicitverupgrades` agenda is active for a
block:

- every transaction in the block, in either tree and of every type, #MUST
  have a version of at most 3 (`ErrTxVersionTooHigh`);
- every output of every regular (non-stake) transaction #MUST have script
  version 0 (`ErrScriptVersionTooHigh`).

Stake transactions are exempt from the second rule only because their output
script versions are already fixed individually by the rules of
#chref("staking") and #chref("treasury"). The per-transaction statement of
both rules is in #chref("transactions"). Transaction version 0 is also below the limit and remains valid. Versions
1, 2 and 3 are the original version, the version that enables relative lock times
(#dcp(3)) and the version used by treasury transactions (#dcp(6)).

The effect is that any future change that needs a new transaction version or
script version is necessarily a hard fork gated by a vote: the new deployment
raises the maximum for blocks for which it is active. A transaction or
script with a given version is then guaranteed to follow the rules defined
for that version, so wallets, hardware signers and other software can rely on
version numbers without tracking vote outcomes.

#note[
  The reference code in #dcp(8) reports a too-high script version with the
  transaction-version error kind; dcrd uses a separate error kind. The error
  kind is not consensus-relevant.
]

== Deployments <sec:voting-deployments>

The tables in this section were generated by a Go program that iterates over
the #param("Deployments") of dcrd's `chaincfg` package for each network, so
they reproduce the parameters exactly. On every network every deployment has
the three choices `abstain` (index 0, bits `0x0000`, `IsAbstain`), `no`
(index 1, `IsNo`) and `yes` (index 2); the tables give the bits of `no` and
`yes`. Times are Unix seconds, with the UTC date for orientation.

#let deptable(caption, ..rows) = figure(
  caption: caption,
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto),
    align: (right, left, left, left, left, left, left),
    table.header([Ver.], [Agenda ID / DCP], [Mask], [Choices], [Start time], [Expire time], [Forced]),
    ..rows
  ),
)

#deptable(
  [Main-network deployments],
  // generated from chaincfg (mainnet)
  [4], [`sdiffalgorithm` \ #dcp(1)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1493164800 \ #text(size: 0.85em, fill: palette.muted)[2017-04-26]], [1524700800 \ #text(size: 0.85em, fill: palette.muted)[2018-04-26]], [--],
  [4], [`lnsupport` \ --], [`0x0018`], [`no` `0x0008` \ `yes` `0x0010`], [1493164800 \ #text(size: 0.85em, fill: palette.muted)[2017-04-26]], [1508976000 \ #text(size: 0.85em, fill: palette.muted)[2017-10-26]], [--],
  [5], [`lnfeatures` \ #dcp(2), #dcp(3)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1505260800 \ #text(size: 0.85em, fill: palette.muted)[2017-09-13]], [1536796800 \ #text(size: 0.85em, fill: palette.muted)[2018-09-13]], [--],
  [6], [`fixlnseqlocks` \ #dcp(4)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1548633600 \ #text(size: 0.85em, fill: palette.muted)[2019-01-28]], [1580169600 \ #text(size: 0.85em, fill: palette.muted)[2020-01-28]], [--],
  [7], [`headercommitments` \ #dcp(5)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1567641600 \ #text(size: 0.85em, fill: palette.muted)[2019-09-05]], [1599264000 \ #text(size: 0.85em, fill: palette.muted)[2020-09-05]], [--],
  [8], [`treasury` \ #dcp(6)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1596240000 \ #text(size: 0.85em, fill: palette.muted)[2020-08-01]], [1627776000 \ #text(size: 0.85em, fill: palette.muted)[2021-08-01]], [--],
  [9], [`reverttreasurypolicy` \ #dcp(7)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [9], [`explicitverupgrades` \ #dcp(8)], [`0x0018`], [`no` `0x0008` \ `yes` `0x0010`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [9], [`autorevocations` \ #dcp(9)], [`0x0060`], [`no` `0x0020` \ `yes` `0x0040`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [9], [`changesubsidysplit` \ #dcp(10)], [`0x0180`], [`no` `0x0080` \ `yes` `0x0100`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [10], [`blake3pow` \ #dcp(11)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1682294400 \ #text(size: 0.85em, fill: palette.muted)[2023-04-24]], [1745452800 \ #text(size: 0.85em, fill: palette.muted)[2025-04-24]], [--],
  [10], [`changesubsidysplitr2` \ #dcp(12)], [`0x0060`], [`no` `0x0020` \ `yes` `0x0040`], [1682294400 \ #text(size: 0.85em, fill: palette.muted)[2023-04-24]], [1745452800 \ #text(size: 0.85em, fill: palette.muted)[2025-04-24]], [--],
  [11], [`maxtreasuryspend` \ #dcp(13)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1762992000 \ #text(size: 0.85em, fill: palette.muted)[2025-11-13]], [1826064000 \ #text(size: 0.85em, fill: palette.muted)[2027-11-13]], [--],
) <tab:voting-dep-mainnet>

The main network has no `maxblocksize` deployment (the vote on it took place
only on an earlier, since-replaced test network), so by @tab:voting-forced
that agenda is never active on the main network.

#deptable(
  [Testnet3 deployments],
  // generated from chaincfg (testnet3)
  [5], [`sdiffalgorithm` \ #dcp(1)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1493164800 \ #text(size: 0.85em, fill: palette.muted)[2017-04-26]], [1524700800 \ #text(size: 0.85em, fill: palette.muted)[2018-04-26]], [`yes`],
  [6], [`lnfeatures` \ #dcp(2), #dcp(3)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1505260800 \ #text(size: 0.85em, fill: palette.muted)[2017-09-13]], [1536796800 \ #text(size: 0.85em, fill: palette.muted)[2018-09-13]], [`yes`],
  [7], [`fixlnseqlocks` \ #dcp(4)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1548633600 \ #text(size: 0.85em, fill: palette.muted)[2019-01-28]], [1580169600 \ #text(size: 0.85em, fill: palette.muted)[2020-01-28]], [--],
  [8], [`headercommitments` \ #dcp(5)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1567641600 \ #text(size: 0.85em, fill: palette.muted)[2019-09-05]], [1599264000 \ #text(size: 0.85em, fill: palette.muted)[2020-09-05]], [--],
  [9], [`treasury` \ #dcp(6)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1596240000 \ #text(size: 0.85em, fill: palette.muted)[2020-08-01]], [1627776000 \ #text(size: 0.85em, fill: palette.muted)[2021-08-01]], [--],
  [10], [`reverttreasurypolicy` \ #dcp(7)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [10], [`explicitverupgrades` \ #dcp(8)], [`0x0018`], [`no` `0x0008` \ `yes` `0x0010`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [10], [`autorevocations` \ #dcp(9)], [`0x0060`], [`no` `0x0020` \ `yes` `0x0040`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [10], [`changesubsidysplit` \ #dcp(10)], [`0x0180`], [`no` `0x0080` \ `yes` `0x0100`], [1631750400 \ #text(size: 0.85em, fill: palette.muted)[2021-09-16]], [1694822400 \ #text(size: 0.85em, fill: palette.muted)[2023-09-16]], [--],
  [11], [`blake3pow` \ #dcp(11)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1682294400 \ #text(size: 0.85em, fill: palette.muted)[2023-04-24]], [1745452800 \ #text(size: 0.85em, fill: palette.muted)[2025-04-24]], [--],
  [11], [`changesubsidysplitr2` \ #dcp(12)], [`0x0060`], [`no` `0x0020` \ `yes` `0x0040`], [1682294400 \ #text(size: 0.85em, fill: palette.muted)[2023-04-24]], [1745452800 \ #text(size: 0.85em, fill: palette.muted)[2025-04-24]], [--],
  [12], [`maxtreasuryspend` \ #dcp(13)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [1762992000 \ #text(size: 0.85em, fill: palette.muted)[2025-11-13]], [1826064000 \ #text(size: 0.85em, fill: palette.muted)[2027-11-13]], [--],
) <tab:voting-dep-testnet>

Testnet3 has no `maxblocksize` deployment either; there the default is
`Active`, which has no effect because testnet3 defines a single maximum block
size. The forced choices on `sdiffalgorithm` and `lnfeatures` make those two
agendas active from height 1, and the start and expire times listed for them
are ignored.

#figure(
  caption: [Simnet and regnet deployments. Both networks define the same
    thirteen deployments with start time 0 and expire time
    9223372036854775807 ($2^63 - 1$, never reached); they differ only in the
    forced choice.],
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    align: (right, left, left, left, left, left),
    table.header([Ver.], [Agenda ID / DCP], [Mask], [Choices], [simnet forced], [regnet forced]),
    // generated from chaincfg (simnet and regnet rows are identical apart
    // from the forced choice)
    [4], [`maxblocksize` \ --], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [5], [`sdiffalgorithm` \ #dcp(1)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [6], [`lnfeatures` \ #dcp(2), #dcp(3)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [7], [`fixlnseqlocks` \ #dcp(4)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [8], [`headercommitments` \ #dcp(5)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [9], [`treasury` \ #dcp(6)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [10], [`reverttreasurypolicy` \ #dcp(7)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [10], [`explicitverupgrades` \ #dcp(8)], [`0x0018`], [`no` `0x0008` \ `yes` `0x0010`], [`yes`], [--],
    [10], [`autorevocations` \ #dcp(9)], [`0x0060`], [`no` `0x0020` \ `yes` `0x0040`], [`yes`], [--],
    [10], [`changesubsidysplit` \ #dcp(10)], [`0x0180`], [`no` `0x0080` \ `yes` `0x0100`], [`yes`], [--],
    [11], [`blake3pow` \ #dcp(11)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
    [11], [`changesubsidysplitr2` \ #dcp(12)], [`0x0060`], [`no` `0x0020` \ `yes` `0x0040`], [`yes`], [--],
    [12], [`maxtreasuryspend` \ #dcp(13)], [`0x0006`], [`no` `0x0002` \ `yes` `0x0004`], [`yes`], [--],
  ),
) <tab:voting-dep-simreg>

On simnet every agenda is active from height 1 (treasury from height 2).
On regnet every agenda is subject to an ordinary vote that can start as soon
as the upgrade conditions hold, at the earliest for the interval beginning at
height $"SVH" + "RCI" = 464$, as in the simulated trace of
@sec:voting-majority.

== Main-Network History <sec:voting-history>

@tab:voting-history records every main-network vote. The heights are those of
the first block of the interval in the given state, as published in the
"Voting Results" sections of the DCPs; the activation heights agree with the
historical anchors of @tab:voting-anchors (anchor plus one), and each of the
three heights is the first block of a rule change interval
($4096 + 8064 k$), which was checked with @alg:voting-want-height.

#figure(
  caption: [Main-network vote history. Sources: D = "Voting Results" section
    of the DCP listed; A = historical anchor in dcrd (`agendas.go`); W =
    consensus vote archive of the Decred documentation @dcrdocs; S = derived
    from the state machine (see text). Every listed vote passed. Percentages
    are as published in W and are shares of all votes including abstentions.],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto, 1fr),
    align: (left, right, right, right, right, right, right, right, left),
    table.header([Agenda], [Ver.], [Started], [Locked in], [Active], [Yes %],
      [No %], [Abst. %], [Sources]),
    [`sdiffalgorithm`], [4], [133120], [141184], [149248], [85.94], [1.81], [12.23], [D #dcp(1), A, W],
    [`lnsupport`], [4], [133120], [141184], [149248], [76.34], [1.07], [22.58], [S, A, W],
    [`lnfeatures`], [5], [173440], [181504], [189568], [61.98], [0.30], [37.70], [D #dcp(2), #dcp(3), A, W],
    [`fixlnseqlocks`], [6], [326656], [334720], [342784], [54.46], [0.00], [45.52], [D #dcp(4), A, W],
    [`headercommitments`], [7], [415360], [423424], [431488], [61.21], [0.03], [38.74], [D #dcp(5), A, W],
    [`treasury`], [8], [536320], [544384], [552448], [83.18], [0.08], [16.72], [D #dcp(6), A, W],
    [`reverttreasurypolicy`], [9], [641152], [649216], [657280], [58.66], [0.03], [41.30], [D #dcp(7), A, W],
    [`explicitverupgrades`], [9], [641152], [649216], [657280], [58.28], [0.03], [41.68], [D #dcp(8), A, W],
    [`autorevocations`], [9], [641152], [649216], [657280], [58.27], [0.03], [41.69], [D #dcp(9), A, W],
    [`changesubsidysplit`], [9], [641152], [649216], [657280], [60.14], [0.15], [39.79], [D #dcp(10), A, W],
    [`blake3pow`], [10], [778240], [786304], [794368], [64.13], [0.34], [35.52], [D #dcp(11), A, W],
    [`changesubsidysplitr2`], [10], [778240], [786304], [794368], [62.95], [0.45], [36.59], [D #dcp(12), A, W],
    [`maxtreasuryspend`], [11], [1036288], [1044352], [1052416], table.cell(colspan: 3, align: center)[unconfirmed], [D #dcp(13), A],
    [`maxblocksize`], table.cell(colspan: 7)[no main-network deployment; never voted on the main network], [chaincfg],
  ),
) <tab:voting-history>

Every main-network vote that has been held passed, each in the first
interval in which it was `Started` (the locked-in height is always one
interval after the started height). No main-network vote has failed or
expired.

/ `lnsupport`: No DCP exists for this agenda, which asked stakeholders
  whether development of Lightning Network support should begin and has no
  consensus effect. Its activation height 149248 is given by the historical
  anchor. Its start and lock-in heights are derived: `Active` at 149248
  requires `LockedIn` for the interval starting at 141184 and `Started` for
  the interval starting at 133120; and it could not have started earlier
  than `sdiffalgorithm`, whose #dcp(1) gives 133120, because both share the
  deployment version (hence the same version conditions) and the start time.
/ `maxtreasuryspend`: The approval percentages are not stated in any of the
  sources used for this document.
/ Percentages: The consensus majority test uses only non-abstaining votes.
  Computed that way the published figures give, for example, 97.9 % "yes"
  for `sdiffalgorithm` and 100.0 % for `fixlnseqlocks`. For vote versions 4,
  5 and 6 the archive's "Voting End" column gives the first block of the
  lock-in interval (141184, 181504, 334720) where its entries for later
  versions give the last block of the voting interval (one less); the DCP
  heights are used here.

#note[
  #dcp(5) labels its expire time 1599264000 as "Jan 5th, 2020"; the value
  corresponds to 2020-09-05, which is also the date in dcrd's parameters.
  Only the numeric value matters.
]

The testnet3 activation heights of the voted agendas are given by
@tab:voting-anchors. On testnet3, `changesubsidysplit` activated two
intervals (10080 blocks) after the three other deployment-version-10
agendas.

== Deriving Agenda Status in an Implementation <sec:voting-deriving>

An implementation #MUST derive the state of every agenda from the block chain
by the rules above, not from a table of activation heights, except to the
extent that @rule:voting-active itself uses the historical anchors. The
inputs are, for each block: the header version, the header stake version,
the header timestamp (for median times), the parent link, and the vote
version and vote bits of each vote in the block. Only the last of these
requires the block data rather than the header, so:

- A node that has only headers can determine the proof-of-work majorities,
  but neither the stake version requirement (it depends on the vote
  versions) nor the vote tallies. It can resolve
  agenda status from forced states and from the historical anchors (whose
  anchor hashes it can match against its header chain), and otherwise must
  wait for the block data. When activation cannot yet be determined, dcrd's
  early ("positional") checks accept merkle roots that are valid under
  _either_ outcome of `headercommitments`, and check the difficulty bits
  with a heuristic described in #chref("difficulty")\; the exact outcome is
  enforced once the full context is available.
- The state is constant across a rule change interval and depends only on
  the interval-end blocks of the ancestry, so it can be computed once per
  interval-end block and deployment and cached by block hash. The same holds
  for the stake version requirement per stake version interval.
- Mempool acceptance and block template construction evaluate agenda status
  for the block that would extend the current tip. That is policy, but it
  must use the same predicate so that templates are valid.

When a new release adds a deployment version, blocks that an older release
rejected may be valid under the new rules, since a change can relax a rule as
well as tighten it. dcrd records the newest deployment version it has seen in
its database and, on upgrade, clears the failed-validation mark of every
block whose median time is at or after the start time of the first new
deployment version, so that such blocks are considered again. This is an
implementation matter, but any implementation that persists validation
failures needs an equivalent.

On networks with forced deployments (simnet for every agenda, testnet3 for
`sdiffalgorithm` and `lnfeatures`) and for agendas without a deployment, no
tally is ever performed and the outcome is fixed for every block except the
genesis block (and, for `treasury`, block 1). These cases are part of the
consensus rules of those networks: a node that ignored a forced state would
reject their chains from block 1.
