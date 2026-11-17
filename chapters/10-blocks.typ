#import "../template.typ": *

= Blocks and Chain Selection <ch:blocks>

A Decred block is accepted in stages. Its header is checked first, on its
own and against the headers before it; then its transaction data is checked
against the header that commits to it; and finally the block is _connected_:
every transaction is checked against the set of unspent outputs that exists
at the end of the parent block, and that set is updated. Among all the
branches of blocks a node knows about, the one with the most cumulative
proof of work whose blocks all pass every stage is the _main chain_.

This chapter specifies those stages and the selection of the main chain. Two
features distinguish Decred from its Bitcoin ancestry and run through the
whole chapter. First, a block carries two transaction trees, the _regular
tree_ and the _stake tree_, and they are processed separately. Second, the
votes in a block decide whether the regular tree of the _previous_ block
takes effect at all (@sec:blocks-approval). That second rule makes the
order in which a node updates its unspent-output set when connecting and
disconnecting blocks part of consensus, so it is given in full in
@alg:blocks-connect-utxo and @alg:blocks-disconnect-utxo.

Many block rules belong to other chapters and are only referenced here. The
ticket, vote and revocation rules, and the meaning of the stake-related
header fields, are in #chref("staking")\; proof of work, the difficulty bits
and the ticket price in #chref("difficulty")\; the coinbase and the subsidy
in #chref("subsidy")\; the treasury transactions in #chref("treasury")\;
header and stake versions and the agenda mechanism in #chref("voting")\; and
per-transaction validation in #chref("transactions"). The serialization of
blocks and headers is in #chref("encoding").

== Overview <sec:blocks-overview>

=== Terminology <sec:blocks-terms>

/ Block: A header followed by the regular tree and the stake tree, each an
  ordered list of transactions (#chref("encoding")). The *block hash* is the
  BLAKE-256 hash of the serialized header.
/ Parent: The block whose hash is in the `PrevBlock` field. Every block but
  the genesis block has exactly one parent; a block's *height* is its
  parent's height plus one.
/ Block index: The set of all headers a node has accepted, which forms a
  tree rooted at the genesis block. A *branch* is a path from the genesis
  block to some block; a *chain tip* is a block with no known children.
/ Main chain: The branch currently selected by the rules of
  @sec:blocks-selection. Its last block is the *best block* or *tip*.
/ Side chain: Any branch that is not the main chain.
/ UTXO set: The set of unspent transaction outputs as of the end of a
  given block of a given branch (#chref("transactions")). The UTXO set
  _as of block B_ includes the effects of every block from the genesis block
  to B inclusive, subject to the disapproval rule of
  @sec:blocks-approval.
/ Agenda active for a block: Rules that were changed by a stakeholder vote
  apply from a certain block on. Whether agenda $A$ is active for block $B$
  is a function of $B$'s ancestors only, computed from $B$'s parent as
  defined in #chref("voting"). No agenda is ever active for the genesis
  block. In this chapter "active" always means active _for the block being
  validated_ unless the text says otherwise.
/ Stake validation height: The parameter #param("StakeValidationHeight")
  (4096 on the main network). Blocks at or above this height must contain
  votes (#chref("staking")).

=== Validation stages <sec:blocks-stages>

dcrd divides block validation into the stages in @tab:blocks-stages,
distinguished by how much context each one needs. The division matters to an
implementation for three reasons: headers are accepted, and their proof of
work verified, before any transaction data is downloaded; a failure can only
be attributed to a block hash once the header is known to commit to the data
that was checked; and the expensive checks need the full data of every
ancestor, which a node that downloads blocks out of order does not always
have.

#figure(
  caption: [Block validation stages],
  table(
    columns: (auto, 1fr, auto),
    table.header([Stage], [Context needed and purpose], [Section]),
    [Header sanity], [None. Proof of work, timestamp not too far in the
      future, stake header fields consistent with the claimed height.],
      [@sec:blocks-hdr-sanity],
    [Header positional], [The headers of all ancestors. Timestamp after the
      median time past, height, difficulty (provisionally), checkpoints,
      block version.], [@sec:blocks-hdr-positional],
    [Data preconditions], [Ancestor headers. Block size within the wire
      limit and the header commits to the transaction data.],
      [@sec:blocks-preconditions],
    [Block sanity], [None. Transaction count, size field, per-transaction
      sanity, duplicates.], [@sec:blocks-body-sanity],
    [Block positional], [Ancestor headers. Transaction expiry.],
      [@sec:blocks-body-positional],
    [Header contextual], [The full data of all ancestors (needed to tally
      votes). Exact proof-of-work algorithm and difficulty, ticket price,
      stake version, pool size, final state.], [@sec:blocks-hdr-context],
    [Block contextual], [Full ancestor data. Coinbase and treasurybase
      placement, tree composition, vote counts and approval, signature
      operations, consensus block size, lock times, vote and revocation
      eligibility.], [@sec:blocks-body-context],
    [Connection], [The UTXO set as of the parent. Inputs, fees, subsidies,
      scripts, relative lock times, treasury spends, header commitment.],
      [@sec:blocks-connect],
  ),
) <tab:blocks-stages>

A block is *valid* if and only if it passes every stage and its parent is
valid; the genesis block is valid by definition. The order of the stages,
and of the checks within them, determines only which error a node reports,
except where this chapter states that one check depends on another or that
state changes between checks.

#rule("Validity is inherited", src: ("internal/blockchain/blockindex.go · MarkBlockFailedValidation", "internal/blockchain/process.go · maybeAcceptBlockHeader"))[
  A block whose parent is invalid is invalid. A node #MUSTNOT accept into
  its main chain any block that has an invalid ancestor, regardless of the
  cumulative work of the branch.
] <rule:blocks-inherit>

=== Agendas that affect block validation <sec:blocks-agendas>

@tab:blocks-agendas lists the agendas whose state changes a rule in this
chapter. The main-network activation heights are given for orientation
only: they are one more than the activation anchors recorded in
#chref("voting"), and an implementation determines activation from the
chain, not from this table.

#figure(
  caption: [Agendas referenced in this chapter],
  table(
    columns: (auto, auto, 1fr, auto),
    table.header([Agenda], [DCP], [Effect on block validation], [Main net]),
    [`maxblocksize`], [none], [Selects the second entry of
      #param("MaximumBlockSizes") (@alg:blocks-max-size).], [never],
    [`sdiffalgorithm`], [#dcp(1)], [Ticket price algorithm
      (@rule:blocks-diff-context).], [149248],
    [`lnfeatures`], [#dcp(2), #dcp(3)], [Absolute lock times against the
      parent's median time past (@rule:blocks-finalized); relative lock
      times (@rule:blocks-seqlocks); new script flags.], [189568],
    [`fixlnseqlocks`], [#dcp(4)], [Historical. Corrected the sequence lock
      calculation; the reference implementation no longer consults it and
      applies the corrected calculation to every block
      (#chref("transactions")).], [342784],
    [`headercommitments`], [#dcp(5)], [Combined Merkle root and commitment
      root (@rule:blocks-merkle-roots, @rule:blocks-commitment-root).],
      [431488],
    [`treasury`], [#dcp(6)], [Coinbase version and outputs, treasurybase,
      treasury adds and spends (@rule:blocks-treasurybase-first,
      @rule:blocks-coinbase-amount, @rule:blocks-stake-amounts).], [552448],
    [`reverttreasurypolicy`], [#dcp(7)], [Treasury expenditure limit
      (#chref("treasury")).], [657280],
    [`explicitverupgrades`], [#dcp(8)], [Maximum transaction and script
      versions (@rule:blocks-tx-context).], [657280],
    [`autorevocations`], [#dcp(9)], [Mandatory revocations
      (@rule:blocks-redeemers); revocation scripts not executed
      (@rule:blocks-scripts).], [657280],
    [`changesubsidysplit`], [#dcp(10)], [Subsidy split variant
      (@rule:blocks-coinbase-amount, @rule:blocks-stake-amounts).],
      [657280],
    [`blake3pow`], [#dcp(11)], [Proof-of-work hash and difficulty algorithm
      (@rule:blocks-pow-context, @rule:blocks-diff-context).], [794368],
    [`changesubsidysplitr2`], [#dcp(12)], [Subsidy split variant, taking
      precedence over `changesubsidysplit`.], [794368],
    [`maxtreasuryspend`], [#dcp(13)], [Treasury expenditure limit
      (#chref("treasury")).], [1052416],
  ),
) <tab:blocks-agendas>

== Header Rules <sec:blocks-header>

The serialized header is 180 bytes (#const("MaxBlockHeaderPayload")\; layout
in #chref("encoding")). @tab:blocks-header-fields lists where each field is
validated.

#figure(
  caption: [Where each header field is validated],
  table(
    columns: (auto, 1fr),
    table.header([Field], [Validated by]),
    [`Version`], [Old versions rejected once superseded by a majority:
      #chref("voting") (positional stage).],
    [`PrevBlock`], [Must identify a known header that is not known to be
      invalid: @rule:blocks-parent-known.],
    [`MerkleRoot`], [@rule:blocks-merkle-roots.],
    [`StakeRoot`], [Stake tree Merkle root before the `headercommitments`
      agenda, header commitment root after it: @rule:blocks-merkle-roots,
      @rule:blocks-commitment-root.],
    [`VoteBits`], [Fixed to #hex("0x0001") before stake validation height
      (#chref("staking")); otherwise bit 0 must agree with the votes:
      @rule:blocks-approval-congruent.],
    [`FinalState`, `PoolSize`], [Must match the ticket lottery state of the
      parent: #chref("staking") (contextual stage).],
    [`Voters`, `FreshStake`, `Revocations`], [Bounds in the sanity stage and
      counts in the block stages: #chref("staking").],
    [`Bits`], [Proof of work and difficulty: #chref("difficulty")
      (sanity, positional and contextual stages).],
    [`SBits`], [Ticket price: #chref("difficulty") (contextual stage);
      ticket purchases must pay it: #chref("staking").],
    [`Height`], [@rule:blocks-height.],
    [`Size`], [@rule:blocks-size-field.],
    [`Timestamp`], [@rule:blocks-time-precision, @rule:blocks-time-future,
      @rule:blocks-time-mtp, @rule:blocks-testnet-spacing.],
    [`Nonce`, `ExtraData`], [No constraint other than through the proof of
      work hash, which covers them.],
    [`StakeVersion`], [#chref("voting") (contextual stage).],
  ),
) <tab:blocks-header-fields>

=== Header sanity checks <sec:blocks-hdr-sanity>

These checks need nothing but the header itself (and the local clock, for
@rule:blocks-time-future). They are performed before a header is added to
the block index.

#rule("Proof of work, context-free form", src: "internal/blockchain/validate.go · checkProofOfWorkSanity")[
  The target encoded by `Bits` #MUST be within the range allowed by the
  network's proof-of-work limit, and the header #MUST satisfy that target
  under at least one of the two proof-of-work hash functions (BLAKE-256 or
  BLAKE3). Both functions are accepted here because whether the `blake3pow`
  agenda (#dcp(11)) is active cannot be determined without ancestor data;
  @rule:blocks-pow-context later requires the correct one. The range check,
  the hash functions and the target comparison are specified in
  #chref("difficulty").
] <rule:blocks-pow-sanity>

#rule("Timestamp precision", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  The header timestamp #MUST be a whole number of seconds. Since the
  serialized field is an unsigned 32-bit count of seconds, every decoded
  header satisfies this rule; it constrains only implementations that carry
  timestamps internally at a finer resolution.
] <rule:blocks-time-precision>

#rule("Timestamp not too far in the future", src: "internal/blockchain/validate.go · checkBlockHeaderSanity, MaxTimeOffsetSeconds")[
  Let $T_"adj"$ be the node's network-adjusted time in whole seconds
  (@sec:blocks-adjusted-time) at the moment the header is checked. A header
  whose timestamp is strictly greater than
  $T_"adj" + #const("MaxTimeOffsetSeconds")$, where
  #const("MaxTimeOffsetSeconds") $= 7200$ (two hours), #MUST be rejected.
  A timestamp exactly equal to $T_"adj" + 7200$ is accepted.
] <rule:blocks-time-future>

This is the only rule in the protocol that depends on the local clock. It is
evaluated once, when the header is first offered; a header rejected under it
is not recorded as invalid (@sec:blocks-invalid) and is accepted if offered
again once the clock has caught up. Two honest nodes whose clocks differ can
therefore disagree for a while about a block near the bound, but the
disagreement resolves itself as time passes; it cannot cause a permanent
split.

#rule("Stake header fields in the sanity stage", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  The header #MUST satisfy the context-free bounds on `Voters`,
  `Revocations`, `VoteBits`, `FinalState` and `FreshStake` specified in
  #chref("staking"): before stake validation height no votes or
  revocations, `VoteBits` equal to #hex("0x0001") and an all-zero
  `FinalState`; from stake validation height at least a majority of
  #param("TicketsPerBlock") votes; never more than #param("TicketsPerBlock")
  votes or more than #param("MaxFreshStakePerBlock") ticket purchases. These
  checks use the height claimed in the header, which
  @rule:blocks-height later ties to the actual position.
] <rule:blocks-hdr-stake-sanity>

=== Network-adjusted time <sec:blocks-adjusted-time>

The network-adjusted time used by @rule:blocks-time-future is the local
clock corrected by the median of the clock offsets reported by peers. It is
local policy, not consensus: an implementation may use any reasonable clock.
For interoperability with dcrd it is specified here as dcrd computes it.
The samples are the timestamps in the `version` messages of peers that
complete the handshake (#chref("p2p")).

#algorithm("Network-adjusted time (dcrd, non-consensus)", src: "internal/blockchain/mediantime.go · AddTimeSample, AdjustedTime")[
  ```python
  MAX_ENTRIES = 200            # maxMedianTimeEntries
  MAX_OFFSET = 70 * 60         # maxAllowedOffsetSecs: 4200 seconds

  known_ids = set()
  offsets = []                 # int64 seconds, in arrival order
  offset_secs = 0

  def add_time_sample(source_id, remote_unix_seconds):
      global offset_secs
      if source_id in known_ids:          # one sample per source
          return
      known_ids.add(source_id)
      now = unix_now_seconds()            # local clock, truncated to seconds
      offsets.append(remote_unix_seconds - now)
      if len(offsets) > MAX_ENTRIES:
          offsets.pop(0)                  # drop the oldest sample
      n = len(offsets)
      if n < 5 or n % 2 == 0:             # only odd counts of at least 5
          return
      median = sorted(offsets)[n // 2]
      offset_secs = median if abs(median) < MAX_OFFSET else 0

  def adjusted_time():
      return unix_now_seconds() + offset_secs
  ```
] <alg:blocks-adjusted-time>

#note[
  The update condition reproduces a quirk inherited from Bitcoin Core: once
  200 samples have been collected the count stays even, so the offset never
  changes again for the life of the process.
]

=== Header positional checks <sec:blocks-hdr-positional>

Positional checks need the headers of all ancestors, which a node always
has because it accepts a header only if its parent header is already known.
They do not need any ancestor's transaction data.

#rule("Parent known and not known invalid", src: ("internal/blockchain/process.go · maybeAcceptBlockHeader", "internal/blockchain/process.go · checkKnownInvalidBlock"))[
  The header's `PrevBlock` #MUST identify a header already in the block
  index; otherwise the header is not accepted (it is an _orphan_, error
  `ErrMissingParent`). If the parent is known to be invalid, or known to
  have an invalid ancestor, the header #MUST be rejected
  (`ErrInvalidAncestorBlock`).
] <rule:blocks-parent-known>

dcrd keeps no pool of orphan headers or orphan blocks. Headers must be
supplied in order, which the synchronization protocol of #chref("p2p")
ensures by requesting headers before blocks.

#rule("Height", src: "internal/blockchain/validate.go · checkBlockHeaderPositional")[
  The `Height` field #MUST equal the height of the parent plus one
  (`ErrBadBlockHeight`).
] <rule:blocks-height>

#rule("Timestamp after the median time past", src: "internal/blockchain/validate.go · checkBlockHeaderPositional")[
  Let $M$ be the median time past of the parent block, computed by
  @alg:blocks-mtp with the parent as argument. The header timestamp #MUST
  be strictly greater than $M$ (`ErrTimeTooOld`). A timestamp equal to $M$
  is rejected.
] <rule:blocks-time-mtp>

#rule("Minimum block spacing at maximum difficulty (testnet3 only)", src: ("internal/blockchain/validate.go · checkBlockHeaderPositional, testNet3MaxDiffActivationHeight", "internal/blockchain/chain.go · New"))[
  On the version 3 test network only, let $h$ be the height of the block.
  If $h >= 962928$ and the `Bits` field, compared as an unsigned 32-bit
  integer, is less than or equal to #hex("0x1d03ffff") (the compact encoding
  of the testnet proof-of-work limit shifted right by 6 bits, that is, a
  difficulty of 64), the timestamp #MUST be greater than or equal to the
  parent's timestamp plus 60 seconds (`ErrTimeTooOld`). This rule does not
  exist on any other network. The difficulty rules that accompany it are in
  #chref("difficulty").
] <rule:blocks-testnet-spacing>

#rule("Difficulty, positional form", src: "internal/blockchain/validate.go · checkDifficultyPositional")[
  The `Bits` field #MUST equal a value permitted by the difficulty rules of
  #chref("difficulty") for this position. Because the `blake3pow` agenda
  state cannot always be determined from headers, this check accepts the
  value required by either difficulty algorithm in the circumstances
  described there; @rule:blocks-diff-context later requires the value of the
  algorithm that is actually in force.
] <rule:blocks-diff-positional>

#rule("Block version", src: ("internal/blockchain/validate.go · isOldBlockVersionByMajority", "internal/blockchain/validate.go · isDCP0005Violation"))[
  A header whose `Version` has been superseded by a sufficient majority of
  recent blocks #MUST be rejected (`ErrBlockVersionTooOld`), with the
  historical exceptions listed in #chref("voting"), where the rule is
  specified.
] <rule:blocks-version>

#rule("Fork rejection checkpoint", src: ("internal/blockchain/validate.go · checkBlockHeaderPositional", "internal/blockchain/process.go · maybeSetForkRejectionCheckpoint", "internal/blockchain/chain.go · New"))[
  On a network whose #param("AssumeValid") parameter is not the zero hash,
  once the header identified by #param("AssumeValid") is in the block index,
  let $A$ be that header, let
  $E = floor(1209600 "s" \/ #param("TargetTimePerBlock"))$ be the expected
  number of blocks in two weeks (4032 on the main network), and let $C$ be
  the ancestor of $A$ at height $max(0, A."height" - E)$. A header that is
  not already in the block index and whose height is strictly less than
  $C."height"$ #MUST be rejected (`ErrForkTooOld`). The rule uses the
  #param("AssumeValid") value from the network parameters, never a value
  supplied by the operator, and is not in effect until $A$ is known.
] <rule:blocks-fork-checkpoint>

Every header of the branch leading to $A$ is necessarily in the index
before $A$ itself, so the rule rejects only headers of competing branches
that fork more than about two weeks of blocks before the assumed-valid
block. The outcome depends on which headers a node already has: the rule is
applied only to new headers below $C."height"$, so the headers of a
competing branch that a node accepted before $A$ became known stay in the
index, and that branch can still be extended by headers at heights of
$C."height"$ and above. For a node that learns the main-chain headers first, as a node
synchronizing from the genesis block does, a branch that forks before $C$
can never become the main chain, however much work it has. The rule is
thus a checkpoint derived from the network parameters rather than a
property of the blocks themselves; an implementation that omits it agrees
with dcrd on every chain except such a deep fork. dcrd's operator option `--allowoldforks` disables the rule as a
recovery mechanism; a node with the rule disabled can follow a chain that
other nodes refuse. On the simulation and regression networks
#param("AssumeValid") is zero and the rule never applies.

#rule("Maximum-difficulty checkpoint (testnet3 only)", src: "internal/blockchain/validate.go · checkBlockHeaderPositional, block962928Hash")[
  On the version 3 test network, a header at height 962928 #MUST have the
  block hash (display form)
  #hex("0000004fd1b267fd39111d456ff557137824538e6f6776168600e56002e23b93")
  (`ErrBadMaxDiffCheckpoint`).
] <rule:blocks-testnet-checkpoint>

#note[
  Earlier versions of dcrd carried a list of manual checkpoints in the
  network parameters. The list is no longer consulted; the two rules above
  are the only checkpoints that remain.
]

=== Median time past <sec:blocks-mtp>

The *median time past* (MTP) of a block $B$ is the median of the timestamps
of $B$ and up to ten of its ancestors. It is a time that, unlike the
timestamp of a single block, no individual miner can move far, and it is
used both by @rule:blocks-time-mtp and, once the `lnfeatures` agenda is
active, as the reference time for transaction lock times
(@rule:blocks-finalized and #chref("transactions")).

#algorithm("Median time past", src: ("internal/blockchain/blockindex.go · CalcPastMedianTime", "internal/blockchain/validate.go · medianTimeBlocks"))[
  ```python
  MEDIAN_TIME_BLOCKS = 11

  def median_time_past(node):
      # node: the block whose MTP is wanted, e.g. the parent of a new block.
      timestamps = []
      n = node
      while len(timestamps) < MEDIAN_TIME_BLOCKS and n is not None:
          timestamps.append(n.timestamp)   # node itself first, then ancestors
          n = n.parent
      timestamps.sort()                    # ascending
      return timestamps[len(timestamps) // 2]
  ```
] <alg:blocks-mtp>

Fewer than eleven timestamps are available only when the argument is at
height 9 or below, that is, when validating blocks 1 to 10. With an even number $n$ of timestamps the algorithm
returns the element at index $n\/2$ of the sorted list, the _upper_ of the
two middle values, and does not average them. The genesis block's own
timestamp is included when it is reached. Timestamps are not required to
increase from block to block; they are sorted, so the order of the
ancestors does not matter.

#pitfall[
  The MTP that bounds a new block's timestamp is that of the _parent_,
  covering the parent and its ten predecessors, not of the new block. A
  correct implementation computes `median_time_past(parent)`.
]

#vector[Median time past][
  Timestamps are listed from the oldest block to the block passed as
  argument (the last entry). Produced with dcrd's `CalcPastMedianTime`.
  ```
  [1454954400]                                         -> 1454954400
  [1000, 900]                                          -> 1000
  [100, 300, 200, 400]                                 -> 300
  [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110]       -> 60
  [5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110]    -> 60  (5 is ignored)
  [110, 100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 1000000]
                                                       -> 60  (110 is ignored)
  [1000, 1000, 1000, 999, 1, 1, 1]                     -> 999
  ```
]

=== Header contextual checks <sec:blocks-hdr-context>

The remaining header checks depend on which agendas are active and on the
ticket lottery, both of which are derived from the votes and tickets in
ancestor blocks. They therefore need the full data of every ancestor and
run only when the block is otherwise ready for full validation
(@sec:blocks-processing).

#rule("Proof of work, contextual form", src: "internal/blockchain/validate.go · checkProofOfWorkContext")[
  The header #MUST satisfy its target under the proof-of-work hash function
  in force for the block: BLAKE-256 if the `blake3pow` agenda (#dcp(11)) is
  not active, BLAKE3 if it is (#chref("difficulty")).
] <rule:blocks-pow-context>

#rule("Difficulty and ticket price, exact", src: "internal/blockchain/validate.go · checkBlockHeaderContext")[
  `Bits` #MUST equal the required difficulty and `SBits` #MUST equal the
  required ticket price, both computed from the parent as specified in
  #chref("difficulty") (`ErrUnexpectedDifficulty`).
] <rule:blocks-diff-context>

#rule("Stake version", src: "internal/blockchain/validate.go · checkBlockHeaderContext")[
  Under the conditions given in #chref("voting"), `StakeVersion` #MUST
  equal the expected stake version (`ErrBadStakeVersion`).
] <rule:blocks-stake-version>

#rule("Ticket pool commitments", src: "internal/blockchain/validate.go · checkBlockHeaderContext")[
  `PoolSize` #MUST equal the number of live tickets and `FinalState`
  #MUST equal the final state of the ticket lottery, both as of the parent
  block (`ErrPoolSize`, `ErrInvalidFinalState`); see #chref("staking").
] <rule:blocks-pool-commitments>

== Block Body Rules <sec:blocks-body>

=== Data commitment preconditions <sec:blocks-preconditions>

When the transaction data of a block arrives, the node first establishes
that the data is the data the header commits to. Until that is established,
a failure of any later check could be the fault of whoever relayed a
corrupted copy rather than of the block itself, so it must not be held
against the block hash (@sec:blocks-invalid).

#rule("Wire size limit", src: ("internal/blockchain/validate.go · checkBlockSizeSanity", "wire/msgblock.go · MaxBlockPayload"))[
  The serialized size of the block #MUSTNOT exceed
  #const("MaxBlockPayload") $= 1310720$ bytes (`ErrBlockTooBig`). This is a
  context-free bound that applies on every network, independent of the
  consensus limit of @rule:blocks-max-size, which is never larger.
] <rule:blocks-wire-size>

#rule("Merkle roots", src: ("internal/blockchain/validate.go · checkMerkleRoots", "internal/blockchain/validate.go · checkMerkleRootsContext", "blockchain/standalone/merkle.go · CalcTxTreeMerkleRoot, CalcCombinedTxTreeMerkleRoot"))[
  Let $R$ be the Merkle root of the regular tree and $S$ the Merkle root of
  the stake tree, each computed with the Merkle tree construction of
  #chref("crypto") over the _full_ transaction hashes of #chref("encoding")
  (which cover both prefix and witness), with the root of an empty tree
  defined as 32 zero bytes.
  - If the `headercommitments` agenda (#dcp(5)) is *not* active for the
    block, the header #MUST have `MerkleRoot` $= R$ and `StakeRoot` $= S$.
  - If it *is* active, the header #MUST have
    `MerkleRoot` $= "BLAKE-256"(R || S)$, the root of the two-leaf Merkle
    tree whose leaves are $R$ and $S$. `StakeRoot` is then the header
    commitment root of @rule:blocks-commitment-root.
  A mismatch is `ErrBadMerkleRoot`.
] <rule:blocks-merkle-roots>

Whether `headercommitments` is active is in general a contextual question,
yet the Merkle check must come before all other data checks. dcrd resolves
the circularity as follows, and an implementation that does not process
blocks out of order may simply evaluate the agenda directly.

- When the agenda state is known from the headers alone (on the main and
  test networks its activation is a recorded historical fact; on other
  networks it may be forced by the parameters), the exact form is checked
  immediately, and a pass definitively proves that the header commits to
  the data.
- Otherwise the data is provisionally accepted if it matches _either_ form,
  and the exact form is enforced in the contextual stage. Until then the
  commitment is not considered proven.

#history[
  On the main network the `headercommitments` agenda became active at
  block 431488 (its parent, block 431487, is the recorded anchor; see
  #chref("voting")). Every earlier block uses separate roots. On the test
  network it became active at block 323328.
]

#vector[Combined Merkle root (#dcp(5))][
  Roots in display form. Produced with dcrd's `CalcMerkleRoot` over the
  two leaves; they agree with the vectors published in #dcp(5).
  ```
  R = 0000000000000000000000000000000000000000000000000000000000000000
  S = 0000000000000000000000000000000000000000000000000000000000000000
  -> 988c02a849815a2c70d97fd613a333d766bcb250cd263663c58d4f954240996d

  R = c867d085c96604812854399bf6df63d35d857484fedfd147759ed94c3cdeca35
  S = 0000000000000000000000000000000000000000000000000000000000000000
  -> 1ac7b08e89cf9a09aa37cbc6da5ef565387d5ab7e8a405a6bf75a31efb1a6987

  R = a7bb523ac8ee4cfb39f8ccc9a02281825f7e5d88d6874d5e08724f6bb0ac5083
  S = 826c95263cc3c7de75b0503796c96a0072f8e4da5adef8b95eee27654008a77b
  -> f6b7bd7ac6f1d61c6e48ae1e53302ccc84da2f3b7802a09244c2657a203aa9af
  ```
]

=== Block sanity checks <sec:blocks-body-sanity>

#rule("At least one regular transaction", src: "internal/blockchain/validate.go · checkBlockDataSanity")[
  The regular tree #MUST contain at least one transaction
  (`ErrNoTransactions`). (@rule:blocks-coinbase-first further requires the
  first to be the coinbase.) The stake tree may be empty except where
  #chref("staking") or #chref("treasury") requires transactions in it.
] <rule:blocks-nonempty>

#rule("Header size field", src: "internal/blockchain/validate.go · checkBlockDataSanity")[
  The header's `Size` field #MUST equal the serialized size of the whole
  block in bytes, header included, as defined in #chref("encoding")
  (`ErrWrongBlockSize`).
] <rule:blocks-size-field>

#rule("Transaction sanity", src: ("internal/blockchain/validate.go · checkBlockDataSanity", "blockchain/standalone/tx.go · CheckTransactionSanity"))[
  Every transaction in both trees #MUST pass the context-free transaction
  sanity checks of #chref("transactions"), with the maximum transaction size
  #param("MaxTxSize") (393216 bytes on the main network).
] <rule:blocks-tx-sanity>

#rule("Ticket purchases", src: ("internal/blockchain/validate.go · checkProofOfStake", "internal/blockchain/validate.go · checkBlockDataSanity"))[
  Every ticket purchase in the stake tree #MUST pay at least the ticket
  price `SBits` claimed by the header and at least
  #param("MinimumStakeDiff"), and the header's `FreshStake` #MUST equal the
  number of ticket purchases in the stake tree (`ErrNotEnoughStake`,
  `ErrStakeBelowMinimum`, `ErrFreshStakeMismatch`); see #chref("staking").
] <rule:blocks-tickets-sanity>

#rule("No duplicate transactions", src: "internal/blockchain/validate.go · checkBlockDataSanity")[
  Two transactions in the block, counting both trees together, #MUSTNOT
  have the same transaction hash (`ErrDuplicateTx`). The comparison uses the
  transaction hash that excludes witness data (the _prefix hash_ of
  #chref("encoding")), not the full hash used for the Merkle roots.
] <rule:blocks-no-dup-tx>

=== Block positional checks <sec:blocks-body-positional>

#rule("No expired transactions", src: ("internal/blockchain/validate.go · checkBlockDataPositional", "internal/blockchain/validate.go · IsExpired"))[
  Let $h$ be the height of the block. A transaction in either tree #MUSTNOT
  be expired at height $h$ as defined in #chref("transactions"): a transaction
  with nonzero `Expiry` $x$ is expired at $h$ when $h >= x$
  (`ErrExpiredTx`).
] <rule:blocks-expiry>

=== Block contextual checks <sec:blocks-body-context>

The rules in this section need the agenda states for the block and, for
some, the ticket lottery state of the parent.

#rule("Coinbase is the first regular transaction", src: "internal/blockchain/validate.go · checkBlockContext")[
  The first transaction of the regular tree #MUST be a coinbase as defined
  in #chref("transactions") (with the version requirement that applies when
  the `treasury` agenda is active) (`ErrFirstTxNotCoinbase`), and any other
  transaction of the regular tree #MUSTNOT be a coinbase
  (`ErrMultipleCoinbases`).
] <rule:blocks-coinbase-first>

#rule("Coinbase height commitment", src: "internal/blockchain/validate.go · checkCoinbaseUniqueHeight")[
  For blocks at height 2 and above, the coinbase #MUST encode the block
  height in the output and format specified in #chref("subsidy")
  (`ErrFirstTxNotCoinbase`, `ErrCoinbaseHeight`). Blocks 0 and 1 are exempt.
] <rule:blocks-coinbase-height>

#rule("Treasurybase placement", src: ("internal/blockchain/validate.go · checkBlockContext", "internal/blockchain/validate.go · checkTreasurybaseUniqueHeight"))[
  If the `treasury` agenda (#dcp(6)) is active, the stake tree #MUST be
  non-empty and its first transaction #MUST be a treasurybase
  (`ErrFirstTxNotTreasurybase`), any other stake transaction #MUSTNOT
  be a treasurybase (`ErrMultipleTreasurybases`), and for blocks at height 2 and
  above the treasurybase #MUST commit to the block height as specified in
  #chref("treasury"). The agenda is never active for the blocks at heights
  0 and 1 (#chref("voting")), so the placement requirement never applies to
  them.
] <rule:blocks-treasurybase-first>

#rule("Transaction context checks", src: ("internal/blockchain/validate.go · checkBlockContext", "internal/blockchain/validate.go · checkTransactionContext"))[
  Every transaction in both trees #MUST pass the agenda-dependent
  transaction checks of #chref("transactions") (maximum transaction and
  script versions, null-input rules for each transaction type, stake
  opcodes in regular outputs), evaluated with the agendas active for the
  block.
] <rule:blocks-tx-context>

#rule("Tree composition", src: "internal/blockchain/validate.go · checkBlockContext")[
  With transaction types determined as in #chref("transactions"):
  - every transaction in the regular tree #MUST be of the regular type
    (`ErrStakeTxInRegularTree`);
  - a transaction in the stake tree #MUSTNOT be of the regular type
    (`ErrRegTxInStakeTree`);
  - every transaction in the stake tree #MUST be a ticket purchase, a vote,
    a revocation, or, when the `treasury` agenda is active, a treasury add,
    treasury spend or treasurybase (`ErrNonstandardStakeTx`).
] <rule:blocks-tree-composition>

Transaction types are determined independently of every agenda
(#chref("transactions")): a version 3 transaction of treasury-add,
treasury-spend or treasurybase form is a stake transaction even when the
`treasury` agenda is not active. Before activation such a transaction is
therefore rejected from the regular tree by the first item and from the
stake tree by the third (`ErrNonstandardStakeTx`). Once the agenda is active
the third item cannot be violated by any transaction that passes the second,
and exists to protect against future transaction types.

#rule("Votes and revocations in the block", src: "internal/blockchain/validate.go · checkBlockContext")[
  The header's `Voters` and `Revocations` fields #MUST equal the numbers
  of votes and revocations in the stake tree; from stake validation height
  every vote #MUST vote on the parent block (hash and height); before
  stake validation height the stake tree #MUST contain only ticket
  purchases and, when the `treasury` agenda is active, treasury adds and
  the treasurybase; and the block #MUSTNOT contain more than 255
  revocations. These rules (`ErrVotesMismatch`, `ErrVotesOnWrongBlock`,
  `ErrInvalidEarlyStakeTx`, `ErrTooManyRevocations`,
  `ErrRevocationsMismatch`) are specified in #chref("staking").
] <rule:blocks-vote-counts>

#rule("Treasury transaction limits", src: "internal/blockchain/validate.go · checkBlockContext")[
  When the `treasury` agenda is active the block #MUSTNOT contain more than
  #const("MaxTAddsPerBlock") $= 20$ treasury adds, and treasury spends
  #MUST satisfy the voting-interval placement and expiry rules of
  #chref("treasury") (`ErrTooManyTAdds`, `ErrNotTVI`,
  `ErrInvalidTVoteWindow`).
] <rule:blocks-treasury-limits>

#rule("Approval of the parent", src: "internal/blockchain/validate.go · checkBlockContext, headerApprovesParent")[
  If the block's height is at least stake validation height, let $Y$ be the
  number of votes in its stake tree whose vote bits (#chref("staking")) have
  bit 0 set and $N$ the number of the remaining votes. Bit 0 of the
  header's `VoteBits` field #MUST be set if $Y > N$ and #MUST be clear
  otherwise (`ErrIncongruentVotebit`). Below stake validation height
  `VoteBits` is fixed at #hex("0x0001") by @rule:blocks-hdr-stake-sanity.
] <rule:blocks-approval-congruent>

The meaning of that bit is the subject of @sec:blocks-approval.

#rule("Signature operations, fast count", src: ("internal/blockchain/validate.go · checkBlockContext", "internal/blockchain/validate.go · countSigOps"))[
  The sum over all transactions in the regular tree followed by the stake
  tree of the _fast_ signature operation count of @sec:blocks-sigops
  #MUSTNOT exceed #const("MaxSigOpsPerBlock") $= 5000$ (`ErrTooManySigOps`).
] <rule:blocks-sigops-fast>

#rule("Consensus block size", src: ("internal/blockchain/validate.go · checkBlockContext", "internal/blockchain/chain.go · maxBlockSize"))[
  The block's serialized size (equal to the header `Size` field by
  @rule:blocks-size-field) #MUSTNOT exceed the maximum block size of
  @sec:blocks-size for the block (`ErrBlockTooBig`).
] <rule:blocks-max-size>

#rule("All transactions final", src: ("internal/blockchain/validate.go · checkBlockContext", "internal/blockchain/validate.go · IsFinalizedTransaction"))[
  Let $h$ be the block height and let $t$ be the header timestamp if the
  `lnfeatures` agenda is not active, or the median time past of the
  _parent_ (@alg:blocks-mtp) if it is. Every transaction in both trees
  #MUST be final at height $h$ and time $t$ as defined in
  #chref("transactions") (`ErrUnfinalizedTx`).
] <rule:blocks-finalized>

#history[
  The switch from the block's own timestamp to the parent's median time
  past for absolute lock times is part of the `lnfeatures` agenda
  (#chref("voting")), which became active on the main network at
  block 189568. Relative lock times, which the same agenda introduced, are
  checked during connection (@rule:blocks-seqlocks).
]

#rule("Vote and revocation eligibility", src: ("internal/blockchain/validate.go · checkBlockContext", "internal/blockchain/validate.go · checkTicketRedeemers"))[
  From stake validation height, every vote #MUST redeem a ticket selected
  by the lottery of the parent, every revocation #MUST redeem a ticket
  eligible for revocation, and when the `autorevocations` agenda
  (#dcp(9)) is active the block #MUST revoke every ticket that becomes
  missed or expired in it. These rules are specified in #chref("staking").
] <rule:blocks-redeemers>

=== Signature operation limits <sec:blocks-sigops>

A *signature operation* is an execution of a signature-checking opcode,
counted statically from scripts as specified in #chref("script"). Two
counting methods exist:

/ Fast count: For one transaction, the sum of the static counts of the
  signature scripts of its inputs and of the public key scripts of its
  outputs. The signature script of a coinbase's input and of a vote's first
  input (the stakebase) are not counted, and a treasurybase counts zero in
  total when the `treasury` agenda is active.
/ Precise P2SH count: For each input of a transaction that spends a
  pay-to-script-hash output, the precise count of the redeem script pushed
  by the signature script (#chref("script")). Coinbases, the stakebase input
  of votes, and, when the `treasury` agenda is active, treasurybases and
  treasury spends contribute nothing.

The limit #const("MaxSigOpsPerBlock") $= 1000000 \/ 200 = 5000$ is the same
on every network. It was derived from a one-megabyte block size and was not
changed when the block size was. It is enforced three times, with different
scopes:

#figure(
  caption: [The three signature operation limits],
  table(
    columns: (auto, 1fr, auto),
    table.header([Stage], [Quantity that must not exceed 5000], [Rule]),
    [Contextual], [Fast count, summed over the regular tree and then the
      stake tree.], [@rule:blocks-sigops-fast],
    [Connection, stake tree], [Fast count plus precise P2SH count, summed
      over the stake tree only.], [@rule:blocks-sigops-tree],
    [Connection, regular tree], [Fast count plus precise P2SH count, summed
      over the regular tree only.], [@rule:blocks-sigops-tree],
  ),
) <tab:blocks-sigops>

All three accumulations use unsigned 32-bit arithmetic, and an addition that
overflows is itself a violation (`ErrTooManySigOps`); in practice the limit
is reached long before an overflow is possible. The limit is checked after
each transaction is added, so the error is raised at the first transaction
that crosses it, but the outcome is the same as comparing the final sum.

=== Block size limits <sec:blocks-size>

Three size limits apply to a block:

+ the wire limit #const("MaxBlockPayload") $= 1310720$ bytes
  (@rule:blocks-wire-size), applied before anything else;
+ the requirement that the header `Size` field equal the actual size
  (@rule:blocks-size-field);
+ the consensus maximum (@rule:blocks-max-size), selected per block by
  @alg:blocks-max-size from the network parameter
  #param("MaximumBlockSizes").

#algorithm("Maximum block size for a block", src: ("internal/blockchain/chain.go · maxBlockSize", "internal/blockchain/agendas.go · isMaxBlockSizeAgendaActive"))[
  ```python
  def max_block_size(block):
      sizes = params.MaximumBlockSizes          # list of one or two sizes
      if agenda_active("maxblocksize", block) and len(sizes) > 1:
          return sizes[1]
      return sizes[0]
  ```
] <alg:blocks-max-size>

#figure(
  caption: [Maximum block sizes by network],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [#param("MaximumBlockSizes")], [Effective maximum]),
    [Main], [393216], [393216 bytes for every block. No `maxblocksize`
      deployment exists, so the agenda is never active, and there is only
      one size.],
    [Test (v3)], [1310720], [1310720 bytes for every block. The agenda is
      considered active by default (#chref("voting")) but there is only one
      size.],
    [Simulation], [1000000, 1310720], [The deployment forces the choice
      "yes", so 1310720 from block 1 on.],
    [Regression], [1000000, 1310720], [1000000 until the `maxblocksize`
      agenda is voted in, 1310720 after.],
  ),
) <tab:blocks-max-sizes>

#history[
  The `maxblocksize` vote was held only on the version 2 test network,
  which has been retired. The main network's limit of 393216 bytes
  (384 KiB) has not changed since launch.
]

== Header Commitments <sec:blocks-commitments>

#dcp(5) repurposed the header's `StakeRoot` field. Once the
`headercommitments` agenda is active, the stake tree's Merkle root is
folded into `MerkleRoot` (@rule:blocks-merkle-roots) and `StakeRoot`
instead holds a *commitment root*: the root of a Merkle tree whose leaves
are hashes of data about the block that light clients need to verify. The
scheme is versioned so that leaves can be added by later agendas; version 1
is the only version defined.

#figure(
  caption: [Version 1 header commitment],
  table(
    columns: (auto, auto, 1fr),
    table.header([Leaf index], [Name], [Value]),
    [0], [Filter hash], [The BLAKE-256 hash of the serialized version 2
      block filter of the block (#chref("filters")), or 32 zero bytes if the
      serialized filter is empty.],
  ),
) <tab:blocks-commitment-v1>

The commitment root is the Merkle root (#chref("crypto")) of the list of
leaves. A Merkle tree with a single leaf has that leaf as its root, so the
version 1 commitment root is simply the filter hash.

#rule("Header commitment root", src: ("internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/headercmt.go · CalcCommitmentRootV1"))[
  If the `headercommitments` agenda is active for the block, the header's
  `StakeRoot` #MUST equal the version 1 commitment root, that is, the
  filter hash of @tab:blocks-commitment-v1 for the block
  (`ErrBadCommitmentRoot`). The filter is built from the block and the
  UTXO set as it stands immediately after the block's own transactions have
  been applied (step 10 of @alg:blocks-check-connect), so that it can
  include the scripts of outputs spent by the block, among them outputs
  created earlier in the same block and, in the historical blocks of
  @rule:blocks-sbss, the regular-tree output spent by a stake transaction of
  the same block. The exact selection of scripts is specified in
  #chref("filters"). If a script that the filter needs is unavailable, the
  block is invalid (`ErrMissingTxOut`).
] <rule:blocks-commitment-root>

Inclusion proofs for individual commitments, which let a light client check
a filter against a header, are specified in #chref("filters"). Note that the
commitment root can only be checked by a node that has the UTXO set, so it
is checked during connection and not in the earlier stages. dcrd builds the
filter for every block, before it tests the agenda; once both trees have
connected the construction cannot fail, so this does not add a rule.

== Stakeholder Approval of the Previous Regular Tree <sec:blocks-approval>

=== Mechanism <sec:blocks-approval-mechanism>

Each vote in block $N$ is cast by a ticket selected by the lottery, and bit
0 of the vote's vote bits says whether that ticket holder approves the
_regular tree of block_ $N - 1$, the block being voted on. The miner of
block $N$ summarizes the votes in bit 0 of the header's `VoteBits`, and
@rule:blocks-approval-congruent forces the summary to be the honest
majority: approval requires strictly more approving than disapproving votes.
With five tickets per block and at least three votes required, a block
whose votes split two to two, or which receives three votes of which two
disapprove, disapproves its parent's regular tree.

If block $N$ disapproves, the regular tree of block $N - 1$ is treated, from
block $N$ onward on that branch, as if it had never been mined: none of its
transactions take effect. The stake tree of block $N - 1$ is never affected;
the votes, tickets, revocations and treasury transactions in it stand. Block
$N - 1$ itself remains part of the chain, and its header, proof of work and
stake tree remain valid. Disapproval is not invalidity: it is a normal,
valid outcome, and both block $N - 1$ and block $N$ are valid blocks.

#rationale[
  The Decred design documentation @dcrdocs describes disapproval as a
  "soft" penalty on the miner of the previous block: the miner loses the
  block's subsidy and fees, but the proof of work that secures the chain is
  not discarded, and a miner who wants to keep the previous block's reward
  needs a majority of approving votes in the next block, which the miner
  does not control. Because the regular tree of a block may be disapproved
  later, stake transactions may never spend outputs of the regular tree of
  their own block (@rule:blocks-stake-same-block), and the stake tree, which
  carries the votes that let the chain advance, is never disapproved.
]

#rule("Effect of disapproval", src: ("internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/utxoviewpoint.go · disconnectDisapprovedBlock, connectBlock"))[
  Let block $N$, at height 2 or above, have bit 0 of its header `VoteBits`
  clear. Then before any transaction of block $N$ is checked or applied,
  every effect of the regular tree of block $N - 1$ on the UTXO set #MUST
  be undone: every output it created is removed, and every output it spent
  is restored to the unspent state with exactly the attributes it had
  before (amount, script, script version, height, transaction index,
  coinbase and expiry flags, transaction type). The transactions of block
  $N$, in both trees, are then checked and applied against the resulting
  set. The undo is performed by @alg:blocks-undo-regular.
] <rule:blocks-disapproval>

Since the stake validation height is at least 2 on every network and
`VoteBits` is fixed to #hex("0x0001") below it, the height condition only
makes explicit that block 1 can never disapprove the genesis block.

=== Consequences <sec:blocks-approval-consequences>

The rule has the following consequences, all of which follow from the order
of operations in @alg:blocks-connect-utxo.

- *The coinbase of block $N - 1$ is lost.* Its outputs are removed; the
  proof-of-work subsidy and all the transaction fees it collected, including
  fees of the stake tree (@sec:blocks-fees), cease to exist. Before the
  `treasury` agenda the treasury's share of the subsidy was paid by an
  output of that same coinbase (#chref("subsidy")) and is lost with it.
  After the agenda, the treasury's share is paid by the treasurybase in the
  stake tree and is unaffected.
- *The stake tree of block $N - 1$ is untouched.* Votes keep their rewards,
  tickets purchased in it remain tickets, revocations remain, treasury adds
  and spends and the treasurybase stand. The ticket lottery state, which
  depends only on stake trees, is the same whether or not $N - 1$ is
  approved.
- *The transactions of the disapproved tree are not invalid.* Their inputs
  are unspent again, so the same transactions may be included in block $N$
  or any later block, where they are validated afresh at their new height
  (they may since have expired, or a conflicting transaction may have spent
  the same inputs). The coinbase of $N - 1$ cannot be re-included, because
  a block may contain only its own coinbase.
- *No transaction of block $N$ may spend an output of the regular tree of
  $N - 1$ when $N$ disapproves it,* in either tree: the output no longer
  exists (`ErrMissingTxOut`). When $N$ approves, both trees of $N$ may spend
  such outputs, subject to the usual maturity rules.
- *The approval of $N - 1$ is decided by block $N$ alone.* Different
  children of $N - 1$ on different branches may decide differently, and a
  reorganization that replaces $N$ can reverse the decision
  (@sec:blocks-reorg).
- *The tentative state between blocks.* After block $N - 1$ is connected
  and before block $N$ arrives, the UTXO set of a node includes the regular
  tree of $N - 1$, since a node cannot know how $N$ will vote. Wallets and
  memory pools must treat these outputs as unconfirmed by stakeholders.
- *Restoring requires the spend data of the parent.* To undo a regular tree
  a node needs the full details of every output that tree spent, so it
  #MUST retain, for at least the tip of each branch it may extend, the
  outputs spent by that block (dcrd keeps a _spend journal_ per block).

=== UTXO-set operations <sec:blocks-utxo-ops>

The following algorithms define exactly how the UTXO set changes when a
block is connected to, or disconnected from, the end of a branch. They
operate on a UTXO set _view_ that maps an outpoint (transaction hash, output
index, tree) to an entry. `spend` removes an entry from the unspent set
after recording it in the block's spend record; `add_outputs` is defined in
@alg:blocks-add-outputs. The tree of an outpoint is the stake tree when the
creating transaction's type is a stake type and the regular tree otherwise,
which by @rule:blocks-tree-composition coincides with the tree the
transaction was mined in.

#algorithm("Adding the outputs of a transaction", src: ("internal/blockchain/utxoviewpoint.go · addTxOuts", "txscript/script.go · IsUnspendable"))[
  ```python
  def add_outputs(view, tx, height, tx_index, treasury_active, only_index=None):
      tree = REGULAR if tx_type(tx) == REGULAR else STAKE
      for i, out in enumerate(tx.outputs):
          if only_index is not None and i != only_index:
              continue                 # used by the SBSS exception only
          if tx_type(tx) == TREASURY_ADD and i == 0:
              continue                 # the treasury add output is not a utxo
          if is_unspendable(out.value, out.script):
              continue                 # e.g. zero value or OP_RETURN (script chapter)
          view[(tx.hash, i, tree)] = Entry(
              amount=out.value, script=out.script, script_version=out.version,
              height=height, tx_index=tx_index, tx_type=tx_type(tx),
              is_coinbase=is_coinbase(tx, treasury_active),
              has_expiry=(tx.expiry != 0))
          # An existing entry for the outpoint is overwritten (no BIP 30 rule).
  ```
] <alg:blocks-add-outputs>

#algorithm("Connecting a block to the UTXO set", src: ("internal/blockchain/utxoviewpoint.go · connectBlock, connectStakeTransaction, connectRegularTransaction", "internal/blockchain/validate.go · checkConnectBlock"))[
  ```python
  def connect_block_utxos(view, block, parent):
      # Precondition: view is the UTXO set as of `parent`, which includes the
      # effects of BOTH trees of `parent`.
      h = block.height
      trsy = agenda_active("treasury", block)            # for this block
      parent_trsy = agenda_active("treasury", parent)    # for the parent!

      # 1. Undo the parent's regular tree if this block disapproves it.
      if h > 1 and block.header.vote_bits & 0x0001 == 0:
          undo_regular_tree(view, parent, spend_record(parent), parent_trsy)

      # 2. Historical exception (main and test networks only, see table).
      sbss = SBSS_VIOLATIONS.get(h)                      # display-form tx hash
      if sbss is not None:
          for idx, tx in enumerate(block.regular_txs):
              if tx.hash == sbss:
                  add_outputs(view, tx, h, idx, trsy, only_index=0)
                  break

      # 3. The stake tree, in order.  Inputs may only reference outputs that
      #    existed before this block (rule "Stake transactions do not spend
      #    outputs of their own block").
      for idx, tx in enumerate(block.stake_txs):
          if trsy and idx == 0:
              continue                 # treasurybase: no inputs, no utxos
          if trsy and is_treasury_spend(tx):
              add_outputs(view, tx, h, idx, trsy)       # no inputs to spend
              continue
          for i, txin in enumerate(tx.inputs):
              if is_vote(tx) and i == 0:
                  continue             # stakebase has no previous output
              spend(view, txin.prev_out)
          add_outputs(view, tx, h, idx, trsy)

      # 4. The regular tree, in order.  A transaction may spend outputs of
      #    transactions earlier in the regular tree of this block.
      for idx, tx in enumerate(block.regular_txs):
          if idx > 0:                  # the coinbase (index 0) has no inputs
              for txin in tx.inputs:
                  spend(view, txin.prev_out)
          add_outputs(view, tx, h, idx, trsy)

      # The spend record of `block` lists the entries spent in step 3 then
      # step 4, in transaction order and input order.  Step 1 is not recorded.
  ```
] <alg:blocks-connect-utxo>

#algorithm("Undoing a regular tree", src: ("internal/blockchain/utxoviewpoint.go · disconnectTransactions", "internal/blockchain/utxoviewpoint.go · disconnectDisapprovedBlock"))[
  ```python
  def undo_regular_tree(view, blk, record, trsy):
      # record: the spend record of `blk`; its regular-tree part is its last
      # count_regular_spends(blk) entries.  trsy: treasury agenda state for blk.
      j = len(record) - 1
      for idx in reversed(range(len(blk.regular_txs))):
          tx = blk.regular_txs[idx]
          for i, out in enumerate(tx.outputs):
              if not is_unspendable(out.value, out.script):
                  view.remove((tx.hash, i, REGULAR))
          if idx == 0:
              continue                 # coinbase: nothing to restore
          for txin in reversed(tx.inputs):
              view[txin.prev_out] = record[j].as_entry()   # restore as unspent
              j -= 1
  ```
] <alg:blocks-undo-regular>

#algorithm("Disconnecting a block from the UTXO set", src: ("internal/blockchain/utxoviewpoint.go · disconnectBlock, removeSBSSViolations", "internal/blockchain/chain.go · reorganizeChainInternal"))[
  ```python
  def disconnect_block_utxos(view, block, parent):
      # Precondition: view is the UTXO set as of `block`.
      # Postcondition: view is the UTXO set as of `parent`.
      h = block.height
      trsy = agenda_active("treasury", block)
      parent_trsy = agenda_active("treasury", parent)
      record = spend_record(block)

      # 1. Undo the regular tree of `block` (reverse order).
      undo_regular_tree(view, block, record, trsy)

      # 2. Undo the stake tree of `block` (reverse order).  Its spends are the
      #    first count_stake_spends(block) entries of the record.
      j = count_stake_spends(block) - 1
      for idx in reversed(range(len(block.stake_txs))):
          tx = block.stake_txs[idx]
          for i, out in enumerate(tx.outputs):
              if not is_unspendable(out.value, out.script):
                  view.remove((tx.hash, i, STAKE))
          if (trsy and idx == 0) or (trsy and is_treasury_spend(tx)):
              continue                 # no inputs
          for i in reversed(range(len(tx.inputs))):
              if is_vote(tx) and i == 0:
                  continue
              view[tx.inputs[i].prev_out] = record[j].as_entry()
              j -= 1

      # 3. Historical exception: remove the re-added output again.
      sbss = SBSS_VIOLATIONS.get(h)
      if sbss is not None and any(tx.hash == sbss for tx in block.regular_txs):
          view.remove((sbss, 0, REGULAR))

      # 4. Redo the parent's regular tree if `block` had disapproved it.
      if block.header.vote_bits & 0x0001 == 0:
          for idx, tx in enumerate(parent.regular_txs):
              if idx > 0:
                  for txin in tx.inputs:
                      spend(view, txin.prev_out)   # not recorded again
              add_outputs(view, tx, parent.height, idx, parent_trsy)
  ```
] <alg:blocks-disconnect-utxo>

#pitfall[
  Every step that involves the parent's transactions uses the agenda states
  _of the parent_: in particular whether the `treasury` agenda is active
  for the parent determines how the parent's coinbase is recognized
  (#chref("transactions")). Using the state of the child is wrong at the
  activation boundary. dcrd itself carried this error until shortly before
  the commit this document describes.
]

#note[
  The tree in which a spent output lives is taken from the outpoint in the
  spending input, and the spend record stores the output's attributes so
  that it can be restored without the creating transaction. Outputs created
  and spent within one regular tree appear in the view only transiently but
  are recorded like any other spend.
]

#figure(
  caption: [Example of disapproval. Block 101 contains, in its regular tree,
    the coinbase $C_101$ and a transaction $T$ that spends output $U$
    (created in block 50) and creates output $T:0$; its stake tree contains
    a ticket purchase $P$. The table shows the state of each output.],
  table(
    columns: (auto, auto, auto, auto),
    table.header([Output], [After 101], [After 102, disapproving],
      [After 102, approving]),
    [$U$], [spent], [unspent], [spent],
    [$T:0$], [unspent], [does not exist], [unspent],
    [$C_101$ outputs], [unspent (immature)], [do not exist],
      [unspent (immature)],
    [$P$ outputs], [unspent], [unspent], [unspent],
  ),
) <tab:blocks-approval-example>

A transaction of block 102, in either tree, that spends $T:0$ is valid only
if block 102 approves block 101. If it disapproves, $T$ itself may be
included again in the regular tree of block 102 or of a later block.


== Connecting a Block <sec:blocks-connect>

=== Order of operations <sec:blocks-connect-order>

Connection checks a block against the UTXO set as of its parent and, if it
passes, produces the UTXO set as of the block. The checks are interleaved
with the updates of @alg:blocks-connect-utxo, and since later checks see the
effects of earlier updates, the order matters. @alg:blocks-check-connect
gives it.

#algorithm("Checking and connecting a block", src: ("internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/validate.go · checkTransactionsAndConnect"))[
  ```python
  def check_connect_block(node, block, parent, view):
      # view: UTXO set as of `parent`.  node: index entry for `block`.
      h, voters = node.height, block.header.voters
      trsy = agenda_active("treasury", block)

      # 1. Treasury payment of this block (amount and form).
      if trsy:
          check_treasurybase(block.stake_txs[0], h, voters)     # treasury chapter
      else:
          check_coinbase_pays_treasury(block.regular_txs[0], h, voters)  # subsidy
      # (both are no-ops for h <= 1)

      # 2. Disapproval of the parent (rule "Effect of disapproval").
      if h > 1 and block.header.vote_bits & 0x0001 == 0:
          undo_regular_tree(view, parent, spend_record(parent),
                            agenda_active("treasury", parent))

      # 3. Historical same-block stake spends (step 2 of the UTXO algorithm).
      add_sbss_violation_output(view, block)

      # 4. Stake tree: inputs, fees, vote subsidies; applies the tree.
      variant = subsidy_split_variant(block)                     # subsidy chapter
      stake_fees = check_and_connect_tree(view, node, block, STAKE, 0, variant)

      # 5. Treasury spends: window, uniqueness, votes, expenditure limit.
      if trsy:
          treasury_spend_checks(block)                           # treasury chapter

      # 6. Relative lock times of the stake tree.
      ln = agenda_active("lnfeatures", block)
      if ln:
          mtp = median_time_past(node.parent)
          for tx in block.stake_txs:
              require_sequence_locks(tx, h, mtp, view)           # transactions ch.

      # 7. Scripts of the stake tree.
      validate_scripts(block.stake_txs, view)

      # 8. Regular tree: inputs, fees, coinbase amount; applies the tree.
      check_and_connect_tree(view, node, block, REGULAR, stake_fees, variant)

      # 9. Relative lock times of the regular tree (coinbase excluded).
      if ln:
          for tx in block.regular_txs[1:]:
              require_sequence_locks(tx, h, mtp, view)

      # 10. Header commitment (rule "Header commitment root").
      if agenda_active("headercommitments", block):
          f = build_v2_filter(block, view)                       # filters chapter
          require(block.header.stake_root == filter_hash(f))

      # 11. Scripts of the regular tree.
      validate_scripts(block.regular_txs, view)

      # 12. Block one pays the initial ledger.
      if h == 1:
          check_block_one_ledger(block.regular_txs[0])           # subsidy chapter
  ```
] <alg:blocks-check-connect>

The scripts of a tree are validated against the view after that tree has
been applied. Script execution reads only the script and version of each
spent output, which a spent entry retains, so this gives the same result as
validating before applying. Steps 7 and 11 may equally be run in parallel
with, or after, the other steps.

#algorithm("Checking and applying one tree", src: ("internal/blockchain/validate.go · checkTransactionsAndConnect", "internal/blockchain/validate.go · checkStakeBaseAmounts, getStakeBaseAmounts"))[
  ```python
  MAX_SIGOPS = 5000

  def check_and_connect_tree(view, node, block, tree, carried_fees, variant):
      h, voters = node.height, block.header.voters
      trsy = agenda_active("treasury", block)
      txs = block.stake_txs if tree == STAKE else block.regular_txs
      total_fees: int64 = carried_fees
      sigops: uint32 = 0
      for idx, tx in enumerate(txs):
          is_cb = tree == REGULAR and idx == 0
          is_vote = tree == STAKE and is_vote_tx(tx)
          n = checked_add_u32(fast_sigops(tx, is_cb, is_vote, trsy),
                              p2sh_sigops(tx, is_cb, is_vote, view, trsy))
          sigops = checked_add_u32(sigops, n)      # overflow: "ErrTooManySigOps"
          if sigops > MAX_SIGOPS:
              reject("ErrTooManySigOps")
          fee = check_transaction_inputs(tx, h, view, block)   # transactions ch.
          total_fees = checked_add_i64(total_fees, fee)        # "ErrBadFees"
          connect_tx(view, tx, h, idx, tree)                   # UTXO algorithm
      if tree == REGULAR:
          check_coinbase_amount(txs[0], h, voters, total_fees, trsy, variant)
          # rule "Coinbase amount"
      else:
          check_stake_amounts(txs, h, voters, trsy, variant, view)
          # rule "Vote subsidies and treasurybase amount"
      return total_fees
  ```
] <alg:blocks-check-tree>

#rule("Signature operations, per tree", src: ("internal/blockchain/validate.go · checkTransactionsAndConnect", "internal/blockchain/validate.go · CountTotalSigOps"))[
  For each tree separately, the sum over its transactions of the fast count
  plus the precise P2SH count (@sec:blocks-sigops) #MUSTNOT exceed 5000
  (`ErrTooManySigOps`). The precise count of an input requires the output
  it spends to exist in the view; if it does not, the block is invalid
  (`ErrMissingTxOut`).
] <rule:blocks-sigops-tree>

#rule("Transaction inputs", src: ("internal/blockchain/validate.go · checkTransactionsAndConnect", "internal/blockchain/validate.go · CheckTransactionInputs"))[
  Every transaction #MUST pass the input checks of #chref("transactions")
  (and, for stake and treasury transactions, those of #chref("staking") and
  #chref("treasury")) against the view as it stands immediately before the
  transaction is applied, at the height of the block, with the fraud-proof
  witness fields checked and with the agendas active for the block. The
  view at that point reflects the steps of @alg:blocks-check-connect that
  precede it, including every earlier transaction of the same tree.
] <rule:blocks-tx-inputs>

=== Spending within a block <sec:blocks-in-block>

The per-transaction availability rule (an input must reference an existing,
unspent output) is in #chref("transactions"). Combined with the order of
@alg:blocks-connect-utxo it yields these block-level rules:

#rule("Stake transactions do not spend outputs of their own block", src: ("internal/blockchain/validate.go · CheckTransactionInputs", "internal/blockchain/utxoviewpoint.go · fetchInputUtxos"))[
  An input of a transaction in the stake tree #MUSTNOT reference an output
  created by any transaction of the same block, in either tree
  (`ErrMissingTxOut`), except for the historical outputs of
  @tab:blocks-sbss.
] <rule:blocks-stake-same-block>

#rule("Regular transactions spend only earlier outputs of their own block", src: ("internal/blockchain/utxoviewpoint.go · addRegularInputUtxos", "internal/blockchain/validate.go · CheckTransactionInputs"))[
  An input of the transaction at index $i$ of the regular tree #MAY
  reference an output of the transaction at index $j$ of the same regular
  tree only if $j < i$. A reference to the same or a later transaction of the
  block refers to an output that does not exist yet (`ErrMissingTxOut`).
] <rule:blocks-regular-same-block>

#rule("Each output is spent at most once per block", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  Because both trees are applied to one view in sequence, an output spent by
  one transaction of the block is no longer available to any later
  transaction of the block, in either tree. In particular an output spent in
  the stake tree cannot also be spent in the regular tree
  (`ErrMissingTxOut`).
] <rule:blocks-single-spend>

#figure(
  caption: [Historical same-block stake spends (SBSS). Output 0 of the
    listed regular-tree transaction, created in the block at the listed
    height, is spent by a stake transaction of the same block. Hashes in
    display form.],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Height], [Transaction hash]),
    [Main], [1106817], [#hex("0875ecdc5f12c8aa6ee0d54331fd5b5e786639882a3adb09882de5e3b939613b")],
    [Main], [1106831], [#hex("714e71358937cd33480fd2900853d43ea3440ca67b38bacdfeaeb0c37c80ee27")],
    [Main], [1106837], [#hex("aeba09a4efa334e3c13e68f27f40bd37cda7643c263f88d69f38a33c2cdacd18")],
    [Main], [1106854], [#hex("17228266d9d6dd7084aa2e479319aca6d755c2a9d2dbb3cf28c8151470c7a439")],
    [Main], [1106860], [#hex("20d6d3ed1b609f03969474dca1f452c25e035766457dfd58061f9b9270fc4e6d")],
    [Main], [1107195], [#hex("5d2e1898fe0c631cb795b1906fb3cf8d9772f1826be8dea64dd3ab85ac0ab2d3")],
    [Test (v3)], [1980161], [#hex("451b6eed1a777bc5bbb5c1dbe10a9e444cbeb7d863adb75fc6b7a676b3dcbb58")],
  ),
) <tab:blocks-sbss>

#rule("Historical same-block stake spends", src: ("internal/blockchain/validate.go · sbssViolations, isSBSSViolation", "internal/blockchain/utxoviewpoint.go · addSBSSViolations"))[
  When connecting a block at a height listed in @tab:blocks-sbss for the
  network, if the block's regular tree contains the listed transaction
  $T$, output 0 of $T$ #MUST be added to the view before the stake tree is
  processed, and a stake transaction of the block #MAY spend it; the
  same-height restriction of @rule:blocks-stake-same-block does not apply to
  that output. When the regular tree is then applied, all outputs of $T$,
  output 0 included, are added as unspent, overwriting the spent entry.
  After the block, output 0 of $T$ is therefore unspent, unless a
  transaction later than $T$ in the same regular tree spends it.
  Disconnecting the block removes it again (@alg:blocks-disconnect-utxo,
  step 3).
] <rule:blocks-sbss>

#pitfall[
  The way dcrd implements this exception leaves two further block shapes
  that its input checks do not reject. They apply only to a block at a
  height listed in @tab:blocks-sbss that contains $T$. First, output 0 of
  $T$ is in the view before _either_ tree is processed, so the input checks
  pass a regular transaction that precedes $T$ in the regular tree and
  spends it (with input witness height $h$ and index that of $T$), contrary
  to @rule:blocks-regular-same-block. Second, the exemption from
  @rule:blocks-stake-same-block is keyed on the hash of $T$, not on the
  output index, so the input checks pass a stake transaction that spends
  any output of $T$ present in the view when the stake tree is processed,
  which, besides output 0, is every output of $T$ that a transaction later
  than $T$ in the regular tree spends. Neither shape is accepted, however:
  while connecting a block to the main chain, after validating it and
  applying its transactions to the view and before committing the result,
  dcrd runs a consistency assertion over the view
  #src("internal/blockchain/utxoviewpoint.go", "assertBlockUtxoView"), which
  excuses only a stake transaction spending output 0 of $T$, and the node
  aborts on either shape. Their validity is therefore undefined, not
  accepted. Neither occurs in the seven historical blocks, and an
  implementation should treat output 0 of $T$ spent by a stake transaction
  as the only exception.
]

#history[
  These seven blocks were accepted by earlier versions of dcrd because of a
  defect, since corrected, that allowed a stake transaction to spend an
  output of the regular tree of its own block. The rule was then made
  explicit, and the existing violations had to be special-cased so that the
  historical chain still validates. The resulting effect on the UTXO set,
  including the anomaly that the spent output remains unspent, is the one
  current dcrd produces, and an implementation must reproduce it to agree
  with dcrd about later blocks.
]

=== Fees and subsidy amounts <sec:blocks-fees>

The *fee* of a transaction is the sum of its input values less the sum of
its output values, as computed by the input checks of #chref("transactions")\;
it is never negative, and is zero for a coinbase. For a vote the stakebase
input counts at its declared value, and for a treasurybase and a treasury
spend the single input counts at its declared value.

The fees of the stake tree are carried into the regular tree's accumulation
(step 8 of @alg:blocks-check-connect), so the coinbase may claim the fees of
both trees. Both accumulations are signed 64-bit additions in which an
overflow is a violation (`ErrBadFees`).

#rule("Coinbase amount", src: "internal/blockchain/validate.go · checkTransactionsAndConnect")[
  Let $F$ be the total fees of the stake tree and the regular tree of the
  block, as an `int64`. If the block's height $h$ is at least stake
  validation height, replace $F$ by
  $floor(F dot "Voters" \/ #param("TicketsPerBlock"))$, computed as `int64`
  multiplication followed by division (both operands are non-negative), with
  `Voters` the header field. Let the expected coinbase total be
  - $E = "BlockSubsidy"(1)$ if $h = 1$;
  - $E = "WorkSubsidy"(h, "Voters") + F$ if $h > 1$ and the `treasury`
    agenda is active;
  - $E = "WorkSubsidy"(h, "Voters") + "TreasurySubsidy"(h, "Voters") + F$
    otherwise,
  with the subsidy functions, and the variant of the work subsidy selected
  by the `changesubsidysplit` and `changesubsidysplitr2` agendas, as
  specified in #chref("subsidy"). Then for $h > 0$ the value declared by the
  coinbase's input #MUST equal $E - F$ (`ErrBadCoinbaseAmountIn`), and the
  sum of the coinbase's output values #MUSTNOT exceed $E$
  (`ErrBadCoinbaseValue`).
] <rule:blocks-coinbase-amount>

#rationale[
  The design documentation @dcrdocs gives the reason for this linear
  reduction, which applies to the subsidy (#chref("subsidy")) as well as to
  the fees: it discourages a miner from manipulating which votes are
  included, for instance by omitting votes that disapprove the miner's own
  previous block.
]

#note[
  Worked example: stake tree fees 30000 and regular tree fees 70001 atoms in
  a block above stake validation height with four votes give
  $F = 100001$ and $floor(100001 dot 4 \/ 5) = floor(400004 \/ 5) = 80000$.
  The coinbase may then pay at most $"WorkSubsidy"(h, 4) + 80000$ atoms,
  plus $"TreasurySubsidy"(h, 4)$ before the `treasury` agenda.
]

#rule("Vote subsidies and treasurybase amount", src: ("internal/blockchain/validate.go · checkTransactionsAndConnect", "internal/blockchain/validate.go · checkStakeBaseAmounts, getStakeBaseAmounts"))[
  When the stake tree is checked:
  + If $h > 1$ and the `treasury` agenda is active, the stake tree #MUST be
    non-empty and the value declared by the treasurybase's input #MUST equal
    $"TreasurySubsidy"(h, "Voters")$ (`ErrNoStakeTx`,
    `ErrBadTreasurybaseAmountIn`).
  + If the stake tree is empty, the block #MUST be below stake validation
    height (`ErrNoStakeTx`).
  + For every vote, the sum of its output values less the amount of the
    ticket output it spends #MUSTNOT exceed
    $"VoteSubsidy"(h - 1)$ (`ErrSSGenSubsidy`).
  + The sum of that quantity over all votes #MUSTNOT exceed
    $"VoteSubsidy"(h - 1) dot "Voters"$ if $h$ is at least stake validation
    height, or 0 otherwise (`ErrBadStakebaseValue`).
  The vote subsidy is that of the block voted on, height $h - 1$, in the
  variant selected by the subsidy split agendas (#chref("subsidy")). The
  exact form of each vote is checked by #chref("staking").
] <rule:blocks-stake-amounts>

=== Script validation <sec:blocks-scripts>

#rule("Script validation", src: ("internal/blockchain/scriptval.go · checkBlockScripts", "internal/blockchain/validate.go · consensusScriptVerifyFlags"))[
  For every input of every transaction in both trees, the signature script
  of the input and the public key script of the output it spends #MUST
  execute successfully under the script rules of #chref("script"), with the
  script version of the spent output and the verification flags that
  #chref("transactions") specifies for the block (`ErrScriptValidation`,
  `ErrScriptMalformed`). The following inputs are exempt:
  - any input whose previous outpoint index is #hex("0xffffffff"): the
    input of a coinbase, the stakebase of a vote, the input of a
    treasurybase and the input of a treasury spend (whose authorization is
    checked by #chref("treasury"));
  - every input of a revocation of transaction version 2 or higher when the
    `autorevocations` agenda is active, whose outputs are fixed by
    consensus (#chref("staking")).
] <rule:blocks-scripts>

An input with index #hex("0xffffffff") that is not one of the listed kinds
cannot occur in a valid block: the transaction context checks reject a null
outpoint in other transaction types, and no transaction has
$2^32$ outputs, so the input check fails for any other such reference.

=== Lock times <sec:blocks-locktimes>

#rule("Relative lock times", src: ("internal/blockchain/validate.go · checkConnectBlock", "internal/blockchain/validate.go · SequenceLockActive"))[
  If the `lnfeatures` agenda is active, every transaction of both trees that
  is subject to sequence locks (#chref("transactions") exempts the coinbase,
  votes and the treasurybase) #MUST have its sequence locks satisfied at the block's height and at the median time
  past of the parent, as specified in #chref("transactions")
  (`ErrUnfinalizedTx`).
] <rule:blocks-seqlocks>

=== The genesis block and block one <sec:blocks-genesis>

The genesis block of each network is fixed by the network parameters
(#chref("parameters")). It is not validated, and in particular its header
fields need not satisfy the rules of this chapter: the main network's
genesis header, for instance, has `Size` $= 0$ although the block
serializes to 300 bytes, and `VoteBits` $= 0$. The transactions of the
genesis block are not added to the UTXO set, so its outputs can never be
spent. Every agenda is inactive for the genesis block.

Block 1 is special in the following ways:

- its coinbase pays the initial token distribution, the _block one
  ledger_ of #chref("subsidy"), and its expected coinbase total is
  $"BlockSubsidy"(1)$ (@rule:blocks-coinbase-amount);
- it is exempt from the coinbase height commitment and from the treasury
  payment checks (step 1 of @alg:blocks-check-connect; #chref("subsidy"),
  #chref("treasury"));
- the `treasury` agenda is never active for it, on any network and even
  where the agenda's result is forced, so it has no treasurybase and no
  treasury spends (#chref("voting"));
- it cannot disapprove the genesis block (@rule:blocks-disapproval).

Since nothing is spendable at height 1, block 1 can in practice contain only
its coinbase.

=== Rules that do not exist <sec:blocks-nonrules>

Two checks that an implementer familiar with Bitcoin might expect are not
part of Decred's consensus rules:

- *No check against overwriting unspent outputs.* dcrd contains the
  equivalent of Bitcoin's BIP 30 check but has it permanently disabled
  (`checkForDuplicateHashes` is false). The coinbase height commitment
  makes coinbase hashes unique, and any other transaction whose hash
  repeated an earlier one would have to spend the same, already spent,
  inputs. An implementation #MUSTNOT reject a block for creating an output
  that already exists in the UTXO set; @alg:blocks-add-outputs overwrites
  it.
- *No limit on the number of transactions* other than the size limits.

== Chain Selection <sec:blocks-selection>

=== The block index <sec:blocks-index>

A node keeps every header it has accepted in its block index, together
with a per-block status. The status values used by dcrd are listed in
@tab:blocks-status; they are local state, but an implementation needs
equivalent information to apply the rules of this section.

#figure(
  caption: [Block status (dcrd)],
  table(
    columns: (auto, 1fr),
    table.header([Status], [Meaning]),
    [Data stored], [The full block has been received and stored.],
    [Fully linked], [The block and all of its ancestors have their data;
      the block can be validated.],
    [Validated], [The block has passed connection (or was accepted under
      assume-valid, @sec:blocks-assumevalid). Implies all ancestors are
      valid.],
    [Validation failed], [The block itself violates a consensus rule.],
    [Invalid ancestor], [Some ancestor failed validation.],
  ),
) <tab:blocks-status>

=== Cumulative work <sec:blocks-work>

Each header contributes a *work* value that depends only on its `Bits`
field, $"work"(b) = floor(2^256 \/ ("target"(b) + 1))$, specified in
#chref("difficulty"). The *cumulative work* of a block is the sum of the
work of the block and all its ancestors, the genesis block included,
computed as an unsigned 256-bit integer. Work does not depend on the actual
hash value, on the proof-of-work hash function, or on anything in the stake
system.

=== The best chain <sec:blocks-best>

#rule("Best chain", src: ("internal/blockchain/blockindex.go · FindBestChainCandidate, betterCandidate", "internal/blockchain/chain.go · reorganizeChain"))[
  Among the blocks whose own data and whose ancestors' data are all
  available and none of which is known to be invalid, a node #MUST make the
  tip of its main chain a block with the greatest cumulative work that
  passes full validation together with all its ancestors. If the block with
  the greatest work fails validation while the node attempts to make it the
  tip, it and its descendants are marked invalid and the node repeats the
  selection.
] <rule:blocks-best-chain>

Cumulative work is the only consensus criterion. Ties between blocks of
equal cumulative work are broken by local policy, which affects which of two
valid branches a node follows until one of them gains more work, but never
which blocks are valid. dcrd prefers one candidate over another by the
first of these criteria that distinguishes them:

+ greater cumulative work;
+ having the block data available (always true for candidates);
+ the block that became fully linked first, that is, whose data and all of
  whose ancestors' data were first all present (a counter assigned in
  memory, so a miner gains no advantage by announcing a header early);
+ the smaller block hash, read as a little-endian 256-bit integer.

Consequently a node does not switch to a competing branch of equal work: the
branch it already follows was linked first.

#algorithm("Candidate ordering (dcrd)", src: "internal/blockchain/blockindex.go · betterCandidate, compareHashesAsUint256LE")[
  ```python
  def better_candidate(a, b):          # True if a is preferred over b
      if a.cumulative_work != b.cumulative_work:
          return a.cumulative_work > b.cumulative_work
      if a.have_data != b.have_data:
          return a.have_data
      if a.linked_order != b.linked_order:
          return a.linked_order < b.linked_order   # 0 for blocks loaded from disk
      return int.from_bytes(a.hash, "little") < int.from_bytes(b.hash, "little")
  ```
] <alg:blocks-candidate>

The stake system enters chain selection only through validity: from stake
validation height every block needs at least three votes from tickets chosen
by the lottery of its parent, so a branch whose blocks the ticket holders do
not vote on cannot be extended, regardless of hash power.

=== Processing headers and blocks <sec:blocks-processing>

dcrd processes headers and blocks as described below. The flow is not
itself consensus, but it determines when each stage of
@tab:blocks-stages runs and when a failure condemns a block hash, and an
implementation that departs from it must preserve those properties.

#algorithm("Accepting a header", src: ("internal/blockchain/process.go · ProcessBlockHeader, maybeAcceptBlockHeader"))[
  ```python
  def accept_header(header):
      node = index.lookup(header.hash())
      if node is not None:
          if node.validate_failed: reject("ErrKnownInvalidBlock")
          if node.invalid_ancestor: reject("ErrInvalidAncestorBlock")
          return node                                  # already known
      header_sanity(header)                            # section: header sanity
      parent = index.lookup(header.prev_block)
      if parent is None:
          reject("ErrMissingParent")                   # no orphan headers
      if parent.validate_failed or parent.invalid_ancestor:
          reject("ErrInvalidAncestorBlock")
      header_positional(header, parent)                # section: positional
      node = index.add(header, parent)   # cumulative work = parent's + work(bits)
      maybe_set_fork_rejection_checkpoint()            # rule "Fork rejection checkpoint"
      return node
  ```
] <alg:blocks-accept-header>

A header that fails any of these checks is simply not added; nothing is
recorded about its hash.

#algorithm("Processing a block", src: "internal/blockchain/process.go · ProcessBlock, maybeAcceptBlockData, maybeAcceptBlocks")[
  ```python
  def process_block(block):
      if index.has_block_data(block.hash()): reject("ErrDuplicateBlock")
      node = accept_header(block.header)      # no-op lookup if already known
      proven = data_preconditions(block, node.parent)    # size, Merkle roots
      try:
          block_sanity(block)                            # section: block sanity
          fast = bulk_import or assume_valid_ancestor(node)  # assume-valid
          if fast: node.validated = True
          block_positional(block, node.parent, fast)     # expiry (skipped if fast)
      except RuleError:
          if proven: mark_failed(node)                   # see invalid marking
          raise
      store(block); node.data_stored = True
      linked = link_descendants(node)   # node and stored descendants whose
                                        # ancestors now all have data
      for n in linked:                  # in order, parents before children
          try:
              block_context(n, fast)    # header + block contextual stages;
                                        # `fast` is that of `block`, even for
                                        # descendants (see note in assume-valid)
          except RuleError as e:
              if e.kind != "ErrBadMerkleRoot": mark_failed(n)
              break                     # the rest are checked only if a later
                                        # reorganization tries to connect them
      reorganize_to(best_candidate())   # chain selection, connects blocks
  ```
] <alg:blocks-process>

Blocks whose ancestors lack data are stored and linked later, when the
missing data arrives. Full validation (connection) happens only when a block
becomes part of the main chain, inside the reorganization of
@alg:blocks-reorg; a block on a side chain that never has the most work is
checked through the contextual stage but never connected, and is neither
known valid nor known invalid.

The contextual stage of a block on a side chain needs the agenda states,
difficulty, ticket price and ticket lottery state as of its side-chain
parent, but not the UTXO set. A node must therefore be able to compute
the ticket lottery state for any block in its index whose ancestors have
data, which dcrd does by undoing and replaying the stake effects of blocks
from the main-chain tip to the fork point and along the side chain
(#chref("staking")).

#note[
  Block templates offered to miners are checked by the same stages, without
  the proof-of-work check, against the current tip or the tip's parent (the
  latter when the tip lacks enough votes to be extended). This is mining
  policy (#chref("policy")).
]

=== Reorganization <sec:blocks-reorg>

A *reorganization* moves the tip of the main chain from the current tip to a
target block. Let $F$ be the last common ancestor of the two (the *fork
point*). The blocks of the current main chain after $F$ are disconnected,
newest first, and the blocks from $F$ to the target are connected, oldest
first. The common case, extending the main chain by one block, is the
special case in which $F$ is the current tip.

#algorithm("Reorganizing to a target", src: ("internal/blockchain/chain.go · reorganizeChain, reorganizeChainInternal", "internal/blockchain/chain.go · connectBlock, disconnectBlock"))[
  ```python
  def reorganize_to(target):
      while target is not None and tip != target:
          try:
              reorganize_internal(target)
          except RuleError:
              new_target = best_candidate()     # failed blocks are now excluded
              if new_target == target:
                  break                         # unrecoverable, give up
              target = new_target

  def reorganize_internal(target):
      fork = last_common_ancestor(tip, target)
      while tip != fork:                        # disconnect, newest first
          disconnect_block_utxos(view, tip.block, tip.parent.block)
          stake_state.disconnect(tip)           # ticket pool back to the parent
          tip = tip.parent
      for n in path(fork, target):              # connect, oldest first
          if n.validated:                       # previously validated block
              connect_block_utxos(view, n.block, n.parent.block)
          else:
              try:
                  block_context(n)              # if not already done
                  check_connect_block(n, n.block, n.parent.block, view)
              except RuleError as e:
                  if not (in_context_stage(e) and e.kind == "ErrBadMerkleRoot"):
                      mark_failed(n)
                  raise                         # tip stays at n.parent
              n.validated = True
          stake_state.connect(n)                # ticket pool as of n
          tip = n
  ```
] <alg:blocks-reorg>

The state that a reorganization rolls back and rolls forward is:

- *the UTXO set*, by @alg:blocks-disconnect-utxo and
  @alg:blocks-connect-utxo, which also reverse or reapply the disapproval of
  parents. Disconnecting a block that disapproved its parent reinstates the
  parent's regular tree; connecting the blocks of the new branch may
  disapprove a different set of parents. Disconnecting a block needs that
  block's spend record;
- *the ticket lottery state* (live, missed, expired and revoked tickets,
  pool size, winners and final state), which is a function of the branch
  and is updated block by block as specified in #chref("staking")\;
- *agenda states, difficulty and ticket price*, which are functions of the
  branch and need no explicit rollback;
- *the treasury balance and the set of treasury spends already mined*,
  which are functions of the branch (#chref("treasury")).

A reorganization that fails part way leaves the tip at the last block that
connected successfully, and the selection is repeated, which in general
moves the tip again (possibly back to the original branch). The resulting
tip satisfies @rule:blocks-best-chain.

=== Invalid blocks <sec:blocks-invalid>

#rule("Recording invalidity", src: ("internal/blockchain/blockindex.go · MarkBlockFailedValidation", "internal/blockchain/process.go · ProcessBlock, maybeAcceptBlocks", "internal/blockchain/chain.go · reorganizeChainInternal"))[
  When a block violates a consensus rule, the block is marked as having
  failed validation and every descendant of it known to the node is marked
  as having an invalid ancestor; such blocks are never again candidates for
  the main chain (@rule:blocks-inherit). A failure #MUSTNOT be recorded
  against the block hash when it may be due to a corrupted copy of the
  block data rather than to the block itself, namely:
  - a failure of the data preconditions (@sec:blocks-preconditions), or of
    any earlier deserialization of the block message;
  - a failure of the block sanity or positional stage while the header's
    commitment to the data has only been provisionally established
    (@sec:blocks-preconditions);
  - a Merkle root mismatch detected in the contextual stage.
  A header that fails the header stages is not added to the block index, so
  nothing is recorded for it either.
] <rule:blocks-mark-invalid>

#rationale[
  The block hash covers only the header. Two messages with the same hash can
  carry different transaction data, one valid and one not; the
  `fullblocktests` suite checks that a node rejects a block made too large by
  a non-canonical length prefix and then accepts the correctly encoded block
  with the same hash.
]

=== Manual invalidation and reconsideration <sec:blocks-manual>

dcrd lets the operator mark a block invalid (`invalidateblock`) and undo
such marks (`reconsiderblock`). Both are local operations outside
consensus. Invalidating a block on the main chain reorganizes to its
parent, marks it and its descendants invalid, and then selects the best
remaining candidate; the genesis block cannot be invalidated.
Reconsidering a block clears the failure marks of the block and its
ancestors and the invalid-ancestor marks of those descendants that do not
descend from another failed block, so that they are validated again under
the current rules, and then repeats chain selection. A related RPC forces a
reorganization between two children of the same parent that have the
required data and are not known invalid.

=== Assume-valid and other optimizations <sec:blocks-assumevalid>

dcrd skips some checks for blocks deep in the history of the chain. These
are optimizations: they never cause a node to accept an invalid chain
_provided_ the block identified by the assume-valid hash is in fact valid,
which the developers verify before each release. An independent
implementation may omit them and validate everything.

#rule("Assume-valid ancestors", src: ("internal/blockchain/process.go · isAssumeValidAncestor, maybeUpdateAssumeValid", "internal/blockchain/validate.go · checkConnectBlock"))[
  Let $V$ be the header identified by the assume-valid hash (by default
  #param("AssumeValid")\; the operator may change or disable it), $H$ the
  header with the greatest cumulative work not known to be invalid, and $E$
  the expected number of blocks in two weeks (@rule:blocks-fork-checkpoint).
  A block $B$ is an *assume-valid ancestor* if $V$ is in the index,
  $H."height" >= E$, $B$ is an ancestor of (or equal to) $H$, and $B$ is an
  ancestor of (or equal to) $V'$, where $V'$ is $V$ if
  $V."height" <= H."height" - E$ and otherwise the ancestor of $V$ at height
  $H."height" - E$. An implementation #MAY omit the checks of
  @tab:blocks-fastadd for an assume-valid ancestor, and #MUSTNOT omit them
  for any other block.
] <rule:blocks-assumevalid>

For an assume-valid ancestor dcrd performs all header checks (including
proof of work and positional difficulty), the data preconditions, block
sanity, and the contextual checks _except_ those listed in
@tab:blocks-fastadd, and then connects it to the UTXO set by
@alg:blocks-connect-utxo without @alg:blocks-check-connect. The Merkle roots
still bind every transaction to the header chain, and the header chain to
$V$, so any alteration of the data would change $V$.

#figure(
  caption: [Checks skipped for assume-valid ancestors],
  table(
    columns: (auto, 1fr),
    table.header([Stage], [Skipped checks]),
    [Block positional], [Transaction expiry (@rule:blocks-expiry).],
    [Header contextual], [Exact difficulty and ticket price, stake version,
      pool size and final state (@rule:blocks-diff-context,
      @rule:blocks-stake-version, @rule:blocks-pool-commitments). The
      proof-of-work check under the correct hash function is still
      performed.],
    [Block contextual], [Finality (@rule:blocks-finalized), vote and
      revocation eligibility (@rule:blocks-redeemers), treasury spend
      placement (part of @rule:blocks-treasury-limits).],
    [Connection], [All of @alg:blocks-check-connect: inputs, fees,
      subsidies, scripts, relative lock times, treasury spends, header
      commitment, block one ledger, per-tree signature operations.],
  ),
) <tab:blocks-fastadd>

#note[
  In dcrd the decision to apply the reduced contextual checks is made once,
  for the block being processed, and is then applied to every stored
  descendant that becomes fully linked by that block's arrival
  (@alg:blocks-process). A successful contextual stage is cached, and the
  cached result is used instead of repeating the stage when the block is
  connected. Consequently, a block that is not itself an assume-valid
  ancestor, but whose data was stored before the data of an assume-valid
  ancestor that completes its linkage, passes the contextual stage without
  the header and block contextual checks listed in @tab:blocks-fastadd, and
  those checks are not applied to it later unless the cached result has
  been evicted from the bounded cache. Unlike the
  assume-valid ancestor itself, such a descendant is not marked validated,
  so @alg:blocks-check-connect, scripts included, still runs when it is
  connected. In a test with dcrd's own harness, a block one above the
  assume-valid block whose header committed to a wrong `PoolSize` became the
  tip when its data was delivered first, and was rejected with
  `ErrPoolSize` when delivered after its parent. The behavior depends on
  message arrival order and is not part of the protocol: by
  @rule:blocks-assumevalid every block that is not an assume-valid ancestor
  is subject to all checks.
]

Independently of the above, @alg:blocks-check-connect skips script
validation (steps 7 and 11) for a block that is an assume-valid ancestor at
the time it is connected. dcrd also has a bulk-import mode, used when
importing a trusted block file, with the same effect for every block.

#note[
  The *minimum known chain work* parameter #param("MinKnownChainWork") is
  not a validity rule. dcrd uses it, together with the age of the tip's
  timestamp (more than 24 hours behind adjusted time) and whether the main
  chain has reached $H$, only to decide whether it considers itself
  synchronized, which affects relay, mining and logging, not which blocks
  are valid.
]

=== Local time and consensus <sec:blocks-local-time>

The local clock enters validation only through
@rule:blocks-time-future, at the moment a header is first accepted. Every
other time comparison in this chapter is between timestamps recorded in
headers (@rule:blocks-time-mtp, @rule:blocks-testnet-spacing,
@rule:blocks-finalized, @rule:blocks-seqlocks). Once a block is more than
two hours in the past by every honest clock, whether it is valid is fully
determined by the chain.

== Constants and Error Kinds <sec:blocks-constants>

#figure(
  caption: [Constants used in this chapter],
  table(
    columns: (auto, auto, 1fr),
    table.header([Name], [Value], [Use]),
    [#const("MaxTimeOffsetSeconds")], [7200], [@rule:blocks-time-future],
    [`medianTimeBlocks`], [11], [@alg:blocks-mtp],
    [#const("MaxSigOpsPerBlock")], [5000], [@sec:blocks-sigops],
    [#const("MaxBlockPayload")], [1310720], [@rule:blocks-wire-size],
    [#const("MaxBlockHeaderPayload")], [180], [Header size],
    [#const("MaxTAddsPerBlock")], [20], [@rule:blocks-treasury-limits],
    [`maxRevocationsPerBlock`], [255], [@rule:blocks-vote-counts],
    [`testNet3MaxDiffActivationHeight`], [962928],
      [@rule:blocks-testnet-spacing, @rule:blocks-testnet-checkpoint],
    [`minTestNetDiffBits` (testnet3)], [#hex("0x1d03ffff")],
      [@rule:blocks-testnet-spacing],
    [`maxAllowedOffsetSecs`], [4200], [@alg:blocks-adjusted-time (policy)],
    [`maxMedianTimeEntries`], [200], [@alg:blocks-adjusted-time (policy)],
    [Approval bit (`BlockValid`)], [#hex("0x0001")], [@sec:blocks-approval],
  ),
) <tab:blocks-constants>

#figure(
  caption: [Network parameters used in this chapter (main network values)],
  table(
    columns: (auto, 1fr, auto),
    table.header([Parameter], [Main network], [Use]),
    [#param("MaximumBlockSizes")], [393216], [@alg:blocks-max-size],
    [#param("MaxTxSize")], [393216], [@rule:blocks-tx-sanity],
    [#param("StakeValidationHeight")], [4096], [Throughout],
    [#param("TicketsPerBlock")], [5], [@rule:blocks-coinbase-amount],
    [#param("TargetTimePerBlock")], [300 s], [Two-week block count (4032)],
    [#param("AssumeValid")], [#hex("458d6a8e11c916d4149ca8bc5c7aaaaf16cc61971b0c20764c07edf85df44eb6")],
      [@rule:blocks-fork-checkpoint, @rule:blocks-assumevalid],
    [#param("MinKnownChainWork")], [#hex("0x243868232c14b8224643b6")],
      [@sec:blocks-assumevalid (non-consensus)],
  ),
) <tab:blocks-params>

#vector[Derived values][
  Produced from dcrd's network parameters.
  ```
  expected blocks in two weeks: main 4032, testnet3 10080,
                                simnet 1209600, regnet 1209600
  testnet3: PowLimitBits 1e00ffff, compact(PowLimit >> 6) = 1d03ffff
  main network genesis:
    hash 298e5cc3d985bfe7f81dc135f360abe089edd4396b86d2de66b0cef42b21d980
    header Size 0, serialized size 300, VoteBits 0000, StakeRoot all zero
  Merkle root of an empty tree: 32 zero bytes
  ```
]

@tab:blocks-errors maps the error kinds of dcrd that arise in the stages of
this chapter to the rules that produce them. Error kinds raised only by
rules owned by other chapters are listed with that chapter.

#figure(
  caption: [Error kinds and rules],
  table(
    columns: (1.25fr, 1fr),
    table.header([Error kind], [Rule]),
    [`ErrMissingParent`], [@rule:blocks-parent-known],
    [`ErrInvalidAncestorBlock`, `ErrKnownInvalidBlock`],
      [@rule:blocks-parent-known, @rule:blocks-mark-invalid],
    [`ErrDuplicateBlock`], [@alg:blocks-process (not a validity rule)],
    [`ErrInvalidTime`], [@rule:blocks-time-precision],
    [`ErrTimeTooNew`], [@rule:blocks-time-future],
    [`ErrTimeTooOld`], [@rule:blocks-time-mtp, @rule:blocks-testnet-spacing],
    [`ErrBadBlockHeight`], [@rule:blocks-height],
    [`ErrForkTooOld`], [@rule:blocks-fork-checkpoint],
    [`ErrBadMaxDiffCheckpoint`], [@rule:blocks-testnet-checkpoint],
    [`ErrBlockVersionTooOld`], [@rule:blocks-version (#chref("voting"))],
    [`ErrHighHash`, `ErrUnexpectedDifficulty`],
      [@rule:blocks-pow-sanity, @rule:blocks-diff-positional,
      @rule:blocks-pow-context, @rule:blocks-diff-context
      (#chref("difficulty"))],
    [`ErrBadStakeVersion`], [@rule:blocks-stake-version (#chref("voting"))],
    [`ErrPoolSize`, `ErrInvalidFinalState`],
      [@rule:blocks-pool-commitments (#chref("staking"))],
    [`ErrBlockTooBig`], [@rule:blocks-wire-size, @rule:blocks-max-size],
    [`ErrWrongBlockSize`], [@rule:blocks-size-field],
    [`ErrBadMerkleRoot`], [@rule:blocks-merkle-roots],
    [`ErrBadCommitmentRoot`], [@rule:blocks-commitment-root],
    [`ErrNoTransactions`], [@rule:blocks-nonempty],
    [`ErrDuplicateTx`], [@rule:blocks-no-dup-tx],
    [`ErrExpiredTx`], [@rule:blocks-expiry],
    [`ErrFirstTxNotCoinbase`, `ErrMultipleCoinbases`, `ErrCoinbaseHeight`],
      [@rule:blocks-coinbase-first, @rule:blocks-coinbase-height],
    [`ErrFirstTxNotTreasurybase`, `ErrMultipleTreasurybases`],
      [@rule:blocks-treasurybase-first],
    [`ErrStakeTxInRegularTree`, `ErrRegTxInStakeTree`,
      `ErrNonstandardStakeTx`], [@rule:blocks-tree-composition],
    [`ErrIncongruentVotebit`], [@rule:blocks-approval-congruent],
    [`ErrTooManySigOps`], [@rule:blocks-sigops-fast, @rule:blocks-sigops-tree],
    [`ErrUnfinalizedTx`], [@rule:blocks-finalized, @rule:blocks-seqlocks],
    [`ErrMissingTxOut`], [@rule:blocks-sigops-tree, @rule:blocks-tx-inputs,
      @rule:blocks-stake-same-block, @rule:blocks-regular-same-block,
      @rule:blocks-single-spend, @rule:blocks-commitment-root, and
      #chref("transactions")],
    [`ErrBadFees`], [@alg:blocks-check-tree],
    [`ErrBadCoinbaseAmountIn`, `ErrBadCoinbaseValue`],
      [@rule:blocks-coinbase-amount],
    [`ErrNoStakeTx`, `ErrBadTreasurybaseAmountIn`, `ErrSSGenSubsidy`,
      `ErrBadStakebaseValue`], [@rule:blocks-stake-amounts],
    [`ErrScriptValidation`, `ErrScriptMalformed`], [@rule:blocks-scripts],
    [`ErrNotEnoughStake`, `ErrStakeBelowMinimum`, `ErrFreshStakeMismatch`,
      `ErrNotEnoughVotes`, `ErrTooManyVotes`, `ErrTooManySStxs`,
      `ErrInvalidEarlyStakeTx`, `ErrInvalidEarlyVoteBits`,
      `ErrInvalidEarlyFinalState`, `ErrVotesMismatch`,
      `ErrVotesOnWrongBlock`, `ErrRevocationsMismatch`,
      `ErrTooManyRevocations`, `ErrTicketUnavailable`, `ErrInvalidSSRtx`,
      `ErrNoMissedTicketRevocation`, `ErrNoExpiredTicketRevocation`],
      [@rule:blocks-hdr-stake-sanity, @rule:blocks-tickets-sanity,
      @rule:blocks-vote-counts, @rule:blocks-redeemers
      (#chref("staking"))],
    [`ErrTooManyTAdds`, `ErrNotTVI`, `ErrInvalidTVoteWindow`,
      `ErrNoTreasury`, `ErrTreasurybaseTxNotOpReturn`,
      `ErrTreasurybaseHeight`, treasury spend errors],
      [@rule:blocks-treasurybase-first, @rule:blocks-treasury-limits,
      @alg:blocks-check-connect (#chref("treasury"), #chref("subsidy"))],
    [`ErrBlockOneTx`, `ErrBlockOneInputs`, `ErrBlockOneOutputs`],
      [@sec:blocks-genesis (#chref("subsidy"))],
  ),
) <tab:blocks-errors>
