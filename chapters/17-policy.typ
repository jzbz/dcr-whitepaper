#import "../template.typ": *

= Relay Policy and Mining <ch:policy>

This chapter describes the _local policy_ of the reference node: which
unconfirmed transactions it accepts into its memory pool and relays to peers,
how it maintains that pool as the chain changes, how it assembles candidate
blocks (block templates) for miners, how it hands work to mining hardware,
and how it estimates fees.

#note[
  *Nothing in this chapter is a consensus rule.* Every value and procedure
  described here may differ between nodes without affecting which blocks are
  valid, and none of it appears in a rule box. A node that deviates from it
  remains in consensus, but it may find that its transactions are not relayed
  by reference nodes, that it relays transactions other nodes discard, or
  that the blocks it produces collect fewer votes, fewer fees or less
  propagation than those of other miners. The values are nevertheless given
  exactly, with their dcrd names, so that an implementation can match dcrd's
  behaviour where interoperability matters. The consensus rules that the
  policy builds on (transaction validity, block validity, stake rules) are
  specified in #chref("transactions"), #chref("blocks") and #chref("staking"),
  and are only summarized here.
]

Throughout, the _tip_ is the current best-chain tip, the _next block_ is the
block that would extend it, and $"next" = "tip height" + 1$. Where a check
uses "the median time" it means the past median time of the tip as defined in
#chref("blocks"). Amounts are in atoms and fee rates in atoms per 1000 bytes
(written atoms/kB; Decred's kilobyte is 1000 bytes). Default values are those
of the main network unless stated otherwise.

== Pools and Transaction Classes <sec:policy-pools>

The memory pool ("mempool") of the reference node consists of several
separate structures:

/ Main pool: Fully validated transactions that may be mined in the next
  block. Only this pool feeds block templates.
/ Stage pool: Ticket purchases that are otherwise acceptable but spend an
  output of a transaction that is itself still unconfirmed. Consensus does
  not allow a ticket to spend an output created in the regular tree of the
  same block (the stake tree is connected first, and a regular tree only
  becomes spendable by stake transactions once the next block's votes
  approve it, see #chref("blocks")), so such tickets cannot be mined in the
  next block and are parked (@sec:policy-tickets).
/ Orphan pool: Transactions that reference at least one output that is
  neither in the UTXO set nor created by a pool transaction
  (@sec:policy-orphans).
/ Vote tracker: An index of recently accepted votes keyed by the block they
  vote on. It is deliberately not kept in sync with the main pool: entries
  survive the removal of the vote from the pool until they age out
  (@sec:policy-votes).
/ Treasury-spend set: The treasury spends currently in the main pool,
  counted against a limit (@sec:policy-tspend).

The pool has *no overall size limit*, no fee-based eviction, and no limit on
chains of unconfirmed transactions. Transactions leave the pool only when
mined, when they conflict with a mined transaction, when they expire, when a
transaction they depend on fails to re-enter the pool after a
reorganization, when a staged ticket fails re-validation, or through the
stake-specific pruning rules of @sec:policy-maintenance. Except when a
transaction is mined, a removal takes the transaction's dependents with it.

Transactions are classified by type as in #chref("staking") and
#chref("treasury"). The class determines which policy checks apply and how
the block template orders the transaction (@tab:policy-classes).

#figure(
  caption: [Policy treatment by transaction class. "Pool double spend"
    refers to the check of @sec:policy-doublespend; "Priority" is the stake
    priority used when ordering block template candidates
    (@sec:policy-ordering).],
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    table.header([Class], [Min. relay fee], [Dust check], [Sequence locks], [Pool double spend], [Priority]),
    [Regular], [yes], [yes], [yes], [all inputs], [0],
    [Ticket purchase], [yes], [no], [yes], [all inputs], [1],
    [Vote], [no], [no], [no], [per-ticket rules instead], [3],
    [Revocation], [no], [no], [yes], [one revocation per ticket instead], [0 (automatic: 2)],
    [Treasury add], [yes], [no], [yes], [all inputs], [0],
    [Treasury spend], [yes], [no], [no], [none (single treasury input)], [0],
    [Coinbase, treasurybase], table.cell(colspan: 5)[Never accepted as standalone transactions.],
  ),
) <tab:policy-classes>

=== Entry Points <sec:policy-entry>

A transaction reaches the acceptance procedure of @sec:policy-accept through
one of four paths, which differ in three flags: whether an orphan result is
stored in the orphan pool, whether the high-fee limit of
@sec:policy-highfee is enforced, and whether a transaction already present in
the orphan pool counts as a duplicate.

#figure(
  caption: [Acceptance entry points],
  table(
    columns: (21%, 15%, 14%, 10%, 1fr),
    table.header([Path], [Orphans kept], [High-fee limit], [Orphan dup.], [Notes]),
    [`tx` message from a peer], [if `MaxOrphanTxs` $> 0$], [not enforced], [rejected],
      [Orphans are tagged with the peer's identifier. Ignored entirely when the
      node runs with `--blocksonly`. A hash rejected once is ignored until a
      block received from a peer is added to the main chain
      (@sec:policy-maintenance).],
    [`sendrawtransaction` RPC], [no (rejected with `ErrOrphan`)], [enforced unless `allowhighfees` is true], [rejected],
      [The flag defaults to false.],
    [Orphan reprocessing], [n/a], [not enforced], [allowed],
      [Run when a parent becomes available (@sec:policy-orphans).],
    [Block disconnect / disapproval], [no (silently dropped)], [not enforced], [rejected],
      [Re-adds transactions of blocks leaving the chain
      (@sec:policy-maintenance). Marks the transactions as "not new".],
  ),
) <tab:policy-entry>

The agenda-dependent behaviour of the acceptance checks is selected from the
state of the agendas for the block after the tip. The flag for explicit
version upgrades (#dcp(8), `explicitverupgrades`) is *always* applied by
policy, regardless of the agenda's state; the flags for the decentralized
treasury (#dcp(6), `treasury`), automatic ticket revocations (#dcp(9),
`autorevocations`) and the two subsidy-split changes (#dcp(10)
`changesubsidysplit`, #dcp(12) `changesubsidysplitr2`) are applied when the
respective agenda is active. In consequence the pool never accepts a
transaction with version greater than 3, and never accepts a regular
transaction with an output script version other than 0.

== Mempool Acceptance <sec:policy-accept>

@alg:policy-accept and @alg:policy-accept2 give the complete acceptance
procedure in the order dcrd applies it (the second continues the first, with
the same variables in scope). The order is significant only for which error is reported, except
where noted: the orphan determination happens after all context-free policy
checks and before any check that needs the spent outputs, so an orphan has
passed every check up to that point and nothing after it.

#algorithm("Mempool acceptance (policy), part 1: checks before the inputs are known", src: "internal/mempool/mempool.go · maybeAcceptTransaction")[
  ```python
  def maybe_accept(tx, is_new, allow_high_fees, reject_dup_orphans):
      if tx in main_pool or tx in stage_pool:            fail(ErrDuplicate)
      if reject_dup_orphans and tx in orphans:           fail(ErrDuplicate)
      check_transaction(tx, flags)         # consensus sanity (transactions chapter)
      t = determine_tx_type(tx)            # also sets the tree: regular or stake
      if treasury_active and t == TREASURYBASE:          fail(ErrTreasurybase)
      if is_coinbase(tx, treasury_active):               fail(ErrCoinbase)
      next = tip_height + 1
      if tx.expiry != 0 and next >= tx.expiry:           fail(ErrExpired)
      is_vote = t == VOTE
      is_tspend = treasury_active and t == TSPEND
      if (is_vote or is_tspend) and next < StakeValidationHeight:
          fail(ErrInvalid)
      if is_vote:
          check_vote_height(tx)            # ErrOldVote, ErrFutureVote
          check_vote_block(tx)             # ErrVoteBlockUnknown, ErrVoteBlockHeight
      if t == REVOCATION and next < StakeValidationHeight + 1:
          fail(ErrInvalid)
      if not AcceptNonStd:
          check_transaction_standard(tx, t, next, median_time)
                                           # ErrNonStandard, ErrDustOutput
      if t == TICKET and tx.out[0].value < next_stake_difficulty:
          fail(ErrInsufficientFee)
      if non_mix_tx_spends_pair_request(tx):             fail(ErrMixpoolDoubleSpend)
      if spends_misbehaving_mix_output(tx):              fail(ErrMixingMisbehavior)
      if not is_vote and t != REVOCATION:
          check_pool_double_spend(tx)      # ErrMempoolDoubleSpend
      elif is_vote:
          check_vote_double_spend(tx)      # ErrAlreadyVoted, ErrTooManyVotes
      else:
          check_duplicate_revocation(tx)   # ErrDuplicateRevocation
      view = fetch_input_utxos(tx)         # chain + main, stage, transient pools
      for i in range(len(tx.out)):
          if view.has_unspent(outpoint(tx, i)):          fail(ErrAlreadyExists)
      missing = [inp.prev for k, inp in enumerate(tx.inputs)
                 if not ((k == 0 and is_vote) or is_tspend)
                 and not view.has_unspent(inp.prev)]
      if missing:
          return missing                   # orphan: the caller decides
      return accept_with_inputs(tx, t, view, is_new, allow_high_fees)
  ```
] <alg:policy-accept>

#algorithm("Mempool acceptance (policy), part 2: checks that use the spent outputs", src: "internal/mempool/mempool.go · maybeAcceptTransaction")[
  ```python
  def accept_with_inputs(tx, t, view, is_new, allow_high_fees):
      rewrite_fraud_proofs(tx, view)
      if not is_vote and not is_tspend:
          if not sequence_lock_active(tx, view, next, median_time):
              fail(ErrSeqLockUnmet)
      fee = check_transaction_inputs(tx, next, view, prev_header=tip_header)
      if not AcceptNonStd:
          check_inputs_standard(tx, t, view)                 # ErrNonStandard
      if count_total_sigops(tx, view) > MaxSigOpsPerTx:      fail(ErrNonStandard)
      size = serialize_size(tx)            # full serialization: prefix + witness
      if fee < min_relay_fee(size) and t in (REGULAR, TICKET, TADD, TSPEND):
          fail(ErrInsufficientFee)         # TADD, TSPEND only with treasury active
      if not allow_high_fees and fee > min_relay_fee(size * 10000):
          fail(ErrFeeTooHigh)
      validate_scripts(tx, view, standard_verify_flags())
      if is_vote:
          check_vote_ticket(tx)            # ErrIneligibleTicketVote
      if is_tspend:
          check_tspend(tx)                 # ErrTSpendInvalidExpiry, ErrTooManyTSpends,
                                           # ErrInvalid, ErrTSpendMinedOnAncestor
      if t == TICKET and spends_main_pool_output(tx):
          stage_pool.add(tx)
          return []
      main_pool.add(tx)
      if not is_new and t == REGULAR:
          move every main-pool ticket that spends an output of tx to stage_pool
      if is_vote:
          vote_tracker.add(tx)
      if is_tspend:
          tspend_set.add(tx)
      return []
  ```
] <alg:policy-accept2>

Here `fail(kind)` means the transaction is rejected by policy with the given
error kind from @tab:policy-errors; consensus failures inside
`check_transaction`, `check_transaction_inputs` and `validate_scripts` are
reported with the consensus error kinds of #chref("transactions").

Two details of the input lookup matter. First, `fetch_input_utxos` loads the
spent outputs from the chain as of the tip, but *excludes the outputs created
by the tip's regular tree*, and makes the outputs that tree spent available
again, when the pool's own votes already show that tree to be disapproved
(@sec:policy-votes); outputs of transactions in the main,
stage or transient pools are then added, with height `UnminedHeight`
($"0x7fffffff"$) and block index `0xffffffff`. Second, the fraud-proof fields
of each input (`ValueIn`, `BlockHeight`, `BlockIndex`, which are part of the
witness and not of the transaction hash) are overwritten with the values from
the view whenever any of them differs, so that relayed copies carry correct
values (for an input that spends a pool output these are the placeholders
just given, not final values). Consensus input checks are then run with
fraud-proof checking enabled, against the tip's header as the previous
header.

Because a pool output carries the height `UnminedHeight`, the consensus
maturity checks see it as far from mature. Two consequences follow: a
transaction that spends an output of an unconfirmed transaction with a
nonzero `Expiry` is rejected outright (`ErrExpiryTxSpentEarly`), not held as
an orphan, and an unconfirmed output tagged `OP_SSTXCHANGE`, `OP_SSGEN`,
`OP_SSRTX` or, with the `treasury` agenda active, `OP_TGEN` cannot be spent
in the pool. The first matters to a wallet that
sets an expiry on the transaction funding a ticket.

=== Standard Transactions <sec:policy-standard>

When the node does not accept non-standard transactions (the default on the
main network, see @tab:policy-constants), every transaction must pass the
following checks before its inputs are fetched. `AcceptNonStd` is controlled
by the network parameter #param("AcceptNonStdTxs") (false on the main
network, true on the test, simulation and regression networks) and can be
overridden by `--acceptnonstd` or `--rejectnonstd`.

+ The transaction is serialized in the full format (prefix and witness).
+ The transaction is final with respect to height `next` and the median
  time, using the consensus finality function of #chref("transactions"):
  a lock time of 0 is final; otherwise the lock time is compared with `next`
  if it is below 500000000 and with the median time otherwise, and is final
  if strictly less; otherwise the transaction is final only if every input
  has sequence number `0xffffffff`.
+ The full serialized size is at most #const("MaxStandardTxSize") $= 100000$
  bytes.
+ Unless the transaction is a treasury spend, every input's signature script
  is at most 1650 bytes (`maxStandardSigScriptSize`, enough for a 15-of-15
  multisignature P2SH redemption with compressed keys) and is _push only_:
  every opcode is at most `OP_16` (0x60) and the script parses.
+ Every output has script version 0, and its script is of one of the
  standard types of #chref("script") (anything other than `nonstandard`).
  A bare multisignature output must have between 1 and 3
  (`maxStandardMultiSigKeys`) public keys inclusive and between 1 and the
  number of keys required signatures. A null-data output is `OP_RETURN`
  alone or `OP_RETURN` followed by a single canonical push of at most 256
  bytes (`MaxDataCarrierSizeV0`); a longer push makes the output
  non-standard.
+ For a *regular* transaction only: no output other than a null-data output
  is dust (@sec:policy-dust), and at most 4 outputs (`maxNullDataOutputs`) are
  null data. Stake transactions are exempt from both checks.

After the inputs are known, two further checks apply to each input other
than the first input of a vote and (with the treasury agenda active) the
input of a treasury spend:

+ The script of the spent output, interpreted with its script version, must
  be of a standard type. In particular any spent output with a script
  version other than 0 is non-standard.
+ If the spent output is a plain pay-to-script-hash output (type
  `scripthash`, not the stake-tagged variants), the precise signature
  operation count of the redeem script (#chref("script")) must not exceed
  15 (`maxStandardP2SHSigOps`).

#pitfall[
  With `AcceptNonStd` set, the finality check of item 2 is skipped as well,
  so a node with that setting (the default on the test network) admits
  transactions that are not yet final into its pool. The block template
  generator nevertheless excludes non-final transactions
  (@sec:policy-candidates).
]

#note[
  The source comment at the null-data check in `checkTransactionStandard`, and
  the error message it produces, say a regular transaction may carry only one
  null-data output, but the code compares the count with
  `maxNullDataOutputs` $= 4$ using "greater than", so up to four are standard.
]

=== Dust <sec:policy-dust>

An output is _dust_ if spending it would cost more than a third of its value
at the minimum relay fee rate $r$ (`MinRelayTxFee`). Because the spending
input does not yet exist, a typical pay-to-pubkey-hash input of 165 bytes is
assumed. For an output with value $v$ and serialized size $s$ (8 bytes of
value, 2 of script version, the varint script length and the script):

$ "dust" <==> "IsUnspendable"(v, "script") or floor((v dot 1000) / (3 dot (s + 165))) < r $ <eq:policy-dust>

with truncating `int64` division. `IsUnspendable` (#chref("script")) is true
for zero-valued outputs, scripts starting with `OP_RETURN`, scripts larger
than the maximum script size and scripts that fail to parse; all such
outputs are dust, which is why null-data outputs are exempted explicitly.

#vector[Dust thresholds at the default minimum relay fee (10000 atoms/kB)][
  ```
  output type   serialized size   smallest non-dust value
  P2PKH         36 bytes          6030 atoms
  P2SH          34 bytes          5970 atoms
  ```
]

=== Minimum Relay Fee <sec:policy-minfee>

The minimum fee for a transaction of $n$ serialized bytes (full
serialization) at relay fee rate $r$ atoms/kB is computed by
@alg:policy-minfee. The default rate is #const("DefaultMinRelayTxFee")
$= 10000$ atoms/kB (0.0001 DCR/kB), configurable with `--minrelaytxfee`
(given in DCR/kB).

#algorithm("Minimum relay fee (policy)", src: "internal/mempool/policy.go · calcMinRequiredTxRelayFee")[
  ```python
  MAX_AMOUNT = 21_000_000 * 100_000_000

  def min_relay_fee(n: int64, r: int64) -> int64:
      fee = tdiv(int64(n * r), 1000)      # int64 product; wraps on overflow
      if fee == 0 and r > 0:
          fee = r                          # tiny transactions pay the full rate
      if fee < 0 or fee > MAX_AMOUNT:
          fee = MAX_AMOUNT
      return fee
  ```
] <alg:policy-minfee>

A regular transaction, ticket purchase, treasury add or treasury spend is
rejected with `ErrInsufficientFee` if its fee (inputs minus outputs, as
computed by the consensus input checks) is *less than* `min_relay_fee(n, r)`;
paying exactly the minimum is acceptable. Votes and revocations are exempt:
votes must be feeless by construction, and revocations under #dcp(9) must
pay no fee. Coinbase and treasurybase transactions never enter the pool.

There is no other fee exemption. The reference node has no "free
transaction" or high-priority area in its blocks and no rate limiter for
low-fee transactions; the former `--blockminsize` and `--blockprioritysize`
options are accepted only to print a deprecation warning.

#vector[Minimum and maximum fees at r = 10000 atoms/kB][
  ```
  size (bytes)   minimum fee   maximum fee without allowhighfees
       1                10          100000
     250              2500        25000000
     999              9990        99900000
    1000             10000       100000000
    1500             15000       150000000
  100000           1000000     10000000000
  ```
]

=== High-Fee Limit <sec:policy-highfee>

To protect users from fat-finger mistakes, a transaction submitted through
`sendrawtransaction` without `allowhighfees` is rejected with `ErrFeeTooHigh`
if its fee exceeds `min_relay_fee(n * 10000, r)` (`maxRelayFeeMultiplier`
$= 10^4$), i.e. 1 DCR/kB at the default rate. Transactions received from
peers and orphans being reprocessed are not subject to this limit.

=== Signature Operations and Script Flags <sec:policy-sigops>

The total signature-operation count of a transaction, counted exactly as for
the consensus block limit (#chref("script"), including the redeem scripts of
P2SH inputs), must not exceed `MaxSigOpsPerTx` $= floor(5000 / 5) = 1000$,
one fifth of the consensus per-block limit #const("MaxSigOpsPerBlock")
$= 5000$, so that the transaction can always fit in a block next to the
coinbase. Violations are reported as `ErrNonStandard` even when
`AcceptNonStd` is set.

Scripts are verified with a stricter set of flags than consensus requires.
The standard flags are `BaseStandardVerifyFlags`:

- `ScriptDiscourageUpgradableNops`,
- `ScriptVerifyCleanStack`,
- `ScriptVerifyCheckLockTimeVerify`,
- `ScriptVerifyCheckSequenceVerify`,

plus `ScriptVerifySHA256` when the `lnfeatures` agenda is active and
`ScriptVerifyTreasury` when the `treasury` agenda is active, both evaluated
for the block after the tip. The meaning of each flag is specified in
#chref("script"). These flags are used whether or not `AcceptNonStd` is set,
and the block template generator verifies scripts with the same flags.

=== Expiry, Lock Time and Sequence Locks <sec:policy-locks>

All three are evaluated as if the transaction were to be mined in the next
block, with the tip's median time standing in for the block time:

- A transaction with a non-zero expiry is rejected with `ErrExpired` if
  $"next" >= "expiry"$.
- Finality is checked as part of standardness (@sec:policy-standard).
- Except for votes and treasury spends, which spend no ordinary outputs, the
  relative lock times of #chref("transactions") are computed from the
  input view and the transaction is rejected with `ErrSeqLockUnmet` unless
  $"next" > "MinHeight"$ and $"median time" > "MinTime"$.

Pool transactions that become expired as later blocks arrive are removed
(@sec:policy-maintenance).

=== Double Spends and Replacement <sec:policy-doublespend>

The pool is *first-seen*: there is no replace-by-fee or any other
replacement mechanism. For all classes other than votes and revocations, a
transaction is rejected with `ErrMempoolDoubleSpend` if any of its inputs
spends an outpoint already spent by a transaction in the main pool or the
stage pool. The treasury input of a treasury spend is not checked. Votes
and revocations skip this check entirely and are handled by their own rules (@sec:policy-votes,
@sec:policy-revocations), which in particular allow a vote and a revocation
spending the same ticket to coexist in the pool.

Two further conflict checks protect the StakeShuffle mixing protocol
(#chref("mixing")): a transaction that is not itself a completed mix but
spends an output named in a currently accepted pair request is rejected with
`ErrMixpoolDoubleSpend`, and a transaction spending an output that the mixing
code has flagged as belonging to a misbehaving participant is rejected with
`ErrMixingMisbehavior`.

A transaction is also rejected with `ErrAlreadyExists` if any of its own
outputs already exists unspent in the chain, which detects resubmission of a
confirmed transaction.

=== Orphans <sec:policy-orphans>

When @alg:policy-accept returns a non-empty list of missing outpoints, the
transaction is an orphan. On the peer path it is offered to the orphan pool;
on the RPC path it is rejected with `ErrOrphan`.

- If `MaxOrphanTxs` is 0, the peer path does not keep orphans either: the
  transaction is rejected with `ErrOrphan` as on the RPC path. The default
  is 100 (`--maxorphantx`; negative values are refused at startup).
- An orphan whose full serialized size exceeds `MaxOrphanTxSize` $= 100000$
  bytes (equal to `MaxStandardTxSize`) is rejected with
  `ErrOrphanPolicyViolation`.
- Before an orphan is stored, if the current time is after the next
  scheduled expiry scan, every orphan older than its expiry time is removed
  together with all orphans that spend its outputs (recursively), and the
  next scan is scheduled `orphanExpireScanInterval` $= 5$ minutes later. The
  first scan is scheduled 5 minutes after the pool is created. Scans happen
  only when an orphan is added, never on a timer.
- If the pool still holds `MaxOrphanTxs` or more orphans (that is, if adding
  one would exceed the limit), one arbitrary orphan is evicted (Go map
  iteration order), without its dependents.
- The orphan is stored with an expiry of `orphanTTL` $= 15$ minutes from now
  and tagged with the identifier of the peer that sent it. When that peer
  disconnects, all orphans with its tag are removed together with their
  dependents.

Whenever a transaction is accepted through the peer or RPC path, and for
every transaction of a newly connected block (and, on disconnect, of a
parent block whose regular tree becomes valid again), the orphans that
spend its outputs are reprocessed breadth-first. Transactions re-added from
disconnected blocks (@sec:policy-maintenance) and staged tickets moved to
the main pool do not trigger this. For each output of the
transaction, the orphans spending it are tried in turn, in unspecified
order; the first one that is accepted stops the scan for that output, is
removed from the orphan pool and is appended to the work list so that its
own dependents are tried; an orphan that fails with an error is removed
together with its dependents and also stops the scan for that output; one
that is still an orphan stays and the scan continues. Afterwards every orphan that
spends any outpoint also spent by one of the newly accepted transactions is
removed with its dependents, since it is now a definite double spend. Orphans
accepted this way are relayed after their parent, except on the disconnect
path, which does not relay them.

=== Error Kinds <sec:policy-errors>

#figure(
  caption: [Mempool policy error kinds (`internal/mempool/error.go`)],
  table(
    columns: (auto, 1fr),
    table.header([Kind], [Condition]),
    [`ErrDuplicate`], [Already in the main or stage pool (or orphan pool when duplicates of orphans are rejected).],
    [`ErrInvalid`], [Vote or treasury spend before #param("StakeValidationHeight")\; revocation before #param("StakeValidationHeight") $+ 1$; treasury spend failing its structure, Pi key or signature checks.],
    [`ErrCoinbase`, `ErrTreasurybase`], [Standalone coinbase or (treasury active) treasurybase.],
    [`ErrExpired`], [Expired as of the next block.],
    [`ErrNonStandard`], [Any standardness failure, including the per-transaction sigop limit.],
    [`ErrDustOutput`], [A non-null-data output of a regular transaction is dust.],
    [`ErrInsufficientFee`], [Fee below the minimum relay fee; or ticket price below the next stake difficulty.],
    [`ErrFeeTooHigh`], [Fee above the high-fee limit on the RPC path.],
    [`ErrMempoolDoubleSpend`], [Input already spent by a main- or stage-pool transaction.],
    [`ErrMixpoolDoubleSpend`, `ErrMixingMisbehavior`], [Mixing-protocol conflicts (@sec:policy-doublespend).],
    [`ErrAlreadyExists`], [An output of the transaction already exists unspent in the chain.],
    [`ErrOrphan`], [Missing inputs on a path that does not keep orphans.],
    [`ErrOrphanPolicyViolation`], [Orphan larger than `MaxOrphanTxSize`.],
    [`ErrSeqLockUnmet`], [Relative lock times not satisfied for the next block.],
    [`ErrOldVote`, `ErrFutureVote`], [Vote outside the accepted height window.],
    [`ErrVoteBlockUnknown`, `ErrVoteBlockHeight`], [Vote on an unknown block, or with a height that does not match that block.],
    [`ErrIneligibleTicketVote`], [Recent vote using a ticket that did not win for the block it votes on.],
    [`ErrAlreadyVoted`], [A vote spending the same ticket on the same block is already in the pool.],
    [`ErrTooManyVotes`], [Five votes spending the same ticket are already in the pool.],
    [`ErrDuplicateRevocation`], [A revocation of the same ticket is already in the pool.],
    [`ErrTSpendInvalidExpiry`], [Treasury spend expiry malformed or voting window too far in the future.],
    [`ErrTooManyTSpends`], [Seven treasury spends already in the pool.],
    [`ErrTSpendMinedOnAncestor`], [Treasury spend already mined in an ancestor of the tip.],
  ),
) <tab:policy-errors>

== Stake Transaction Policy <sec:policy-stake>

=== Tickets <sec:policy-tickets>

A ticket purchase is accepted only if its first output (the stake
submission, #chref("staking")) has a value of at least the stake difficulty
for the next block, #param("SBits") of that block as computed in
#chref("difficulty")\; otherwise it is rejected with `ErrInsufficientFee`.
Tickets pay the minimum relay fee like regular transactions. There is no
limit on the number of tickets in the pool.

A ticket that passes every check but spends an output of a transaction in
the main pool is placed in the stage pool instead of the main pool. A staged
ticket is relayed like any accepted transaction but is not a template
candidate. When a block containing the funding transaction is connected,
every staged ticket spending one of that transaction's outputs, and having
no remaining inputs in the main pool, is moved to the main pool without
being validated again (it is dropped only if looking up its inputs fails
with an error). Conversely, when a regular
transaction re-enters the main pool from a disconnected block, tickets in the
main pool that spend it are moved back to the stage pool.

Each time a block becomes the new tip, tickets are pruned from both the main
and the stage pool if

- their first output value is below the stake difficulty of the block after
  the new tip (so tickets priced for a window that has ended are dropped when
  the price rises), or
- they were accepted when the tip height was $h_a$ and
  $h_a + 288 < "new tip height"$ (`heightDiffToPruneTicket`).

Pruning from the main pool also removes, recursively, every pool transaction
that spends the pruned ticket.

=== Votes <sec:policy-votes>

Votes are the most time-critical transactions in Decred: a block at or
above #param("StakeValidationHeight") cannot be built without a majority of
the votes on its parent (#chref("blocks")). The pool therefore accepts votes
on any known block, including blocks on side chains, so that the miner can
choose among competing tips. Let $h_v$ and $H_v$ be the height and hash a
vote commits to (#chref("staking")), and $"next"$ as before.

- *Height window.* The vote is rejected with `ErrOldVote` if
  $h_v < "next" - "MaxVoteAge"$, unless the `--allowoldvotes` option is set
  (default off). `MaxVoteAge` is #param("CoinbaseMaturity") (256 on the main
  network, 16 on the simulation and regression networks) except on the test
  network, where it is 1440. The vote is rejected with `ErrFutureVote` if
  $h_v > "tip height" + 5$ (`maxFutureVoteAge`), regardless of
  `--allowoldvotes`.
- *Known block.* The block $H_v$ must be known to the node, on any chain
  (`ErrVoteBlockUnknown`), and its header height must equal $h_v$
  (`ErrVoteBlockHeight`).
- *Same ticket, same block.* If a vote spending the same ticket and voting
  on the same block $H_v$ is recorded in the vote tracker *and* is still in
  the main pool, the vote is rejected with `ErrAlreadyVoted`.
- *Same ticket, different blocks.* A ticket may be selected by the lottery
  of several competing blocks at the same height, so votes spending one
  ticket on different blocks are allowed, but the vote is rejected with
  `ErrTooManyVotes` if the main pool already contains 5
  (`maxVoteDoubleSpends`) votes spending the same ticket.
- *Winning ticket.* After script validation, if $h_v >= "next" -
  "MaxVoteAge"$, the ticket spent by the vote must be one of the winning
  tickets of block $H_v$ (#chref("staking")), else `ErrIneligibleTicketVote`.
  Older votes (admissible only with `--allowoldvotes`) skip this check to
  avoid an expensive lottery recomputation; consensus rejects them later if
  they are mined.

Votes skip the pool double-spend check, the sequence-lock check and the
minimum fee. An accepted vote is recorded in the vote tracker under $H_v$
(with $h_v$ and whether it approves the parent's regular tree, bit 0 of its
vote bits), unless a vote with the same ticket is already recorded for
$H_v$. Accepted votes also notify the background template generator
(@sec:policy-bg).

The pool uses the tracker to recognise a *known-disapproved* tip: with $n$
tracked votes on the tip, of which $y$ approve, the tip's regular tree is
considered known disapproved if $n > floor("TicketsPerBlock" / 2)$ and
$y <= n - y$. While that holds, new transactions cannot spend outputs of the
tip's regular tree, and may again spend the outputs that tree spent
(@sec:policy-accept); the template generator treats them likewise.

Votes and revocations in the main pool are pruned when a block becomes the
new tip if they were accepted at tip height $h_a$ with $h_a + 10 <
"new tip height"$ (`heightDiffToPruneVotes`). Tracker entries are deleted,
whether or not the votes are still in the pool, when the recorded height
$h_v$ of the voted block satisfies $h_v + 10 < "new tip height"$.

==== Vote Solicitation

Votes are produced by wallets in response to the node's `winningtickets`
notification (#chref("ecosystem")). The reference node sends it when a block
is accepted (on any chain) only if the node is synced (or unsynced mining is
allowed), the block height is at least $"StakeValidationHeight" - 1$, the
depth of the reorganization that the block would cause is less than 6
(`maxReorgDepthNotify`), the block does not spend outputs flagged as
belonging to misbehaving mixing participants, and, on the main network, the
block is not a pre-version-11 block at height 1035288 or above. Each block is
notified at most once.

=== Revocations <sec:policy-revocations>

A revocation is rejected with `ErrInvalid` if $"next" < "StakeValidationHeight" + 1$,
since no ticket can have been missed before then. Instead of the pool
double-spend check, it is rejected with `ErrDuplicateRevocation` if the main
pool already contains a revocation spending the same ticket. It is exempt
from the minimum fee. Its validity, including the version and fee rules of
#dcp(9), is checked by the consensus input checks against the tip.

Once the `autorevocations` agenda (#dcp(9)) is active, every block must
itself revoke all tickets that become missed or expired in it, using
revocations whose content depends on the previous block's header
(#chref("staking")). A revocation left in the pool after the block it was
built for is therefore useless, and with the agenda active *every*
revocation is removed from the pool each time a block becomes the new tip.
The template generator creates the required revocations itself
(@sec:policy-selection).

=== Treasury Spends and Adds <sec:policy-tspend>

Treasury adds (#chref("treasury")) are treated like regular transactions:
they pay the minimum relay fee and are subject to the pool double-spend
check. Treasury spends, with the treasury agenda active, are subject to the
following additional rules, applied after script validation:

+ Not before #param("StakeValidationHeight") (`ErrInvalid`, checked early).
+ The expiry must define a valid voting window: with
  $T$ = #param("TreasuryVoteInterval") and $M$ =
  #param("TreasuryVoteIntervalMultiplier"), the expiry $e$ must satisfy
  $e >= T M + 2$ and $e - 2 equiv 0 space (mod T)$, $e - 2 != 0$, giving a
  voting window starting at $s = e - T M - 2$ (#chref("treasury")); otherwise
  `ErrTSpendInvalidExpiry`.
+ The window must not start too far in the future: the spend is rejected
  with `ErrTSpendInvalidExpiry` if $s > "next"$ and $s - "next" >= 2 T M$
  (6912 blocks on the main network, where $T = 288$ and $M = 12$).
+ The pool may hold at most 7 treasury spends
  (`MempoolMaxConcurrentTSpends`, which equals the number of treasury-spend
  votes a vote can carry); an eighth is rejected with `ErrTooManyTSpends`.
+ The structure and signature are checked as in #chref("treasury"): the
  spend must be well formed, its public key must be one of the network's Pi
  keys, and the signature must verify; failures give `ErrInvalid`.
+ The spend must not already have been mined in an ancestor of the tip
  (`ErrTSpendMinedOnAncestor`).

Treasury spends skip standardness checks of their signature script, the
pool double-spend check of their (only) input and sequence locks, but pay
the minimum relay fee computed from their declared input value. They are
not considered by the fee estimator (@sec:policy-feeest). An accepted spend
is announced to RPC clients subscribed to treasury-spend notifications.

== Mempool Maintenance <sec:policy-maintenance>

The pool is updated whenever the best chain changes.

*Block connected.* For each transaction of the connected block, in order —
the regular tree without its coinbase, then the stake tree (without the
treasurybase when the treasury agenda is active) — the node:

+ removes the transaction from the main pool (without its dependents, which
  remain valid);
+ moves staged tickets that spend it and have no other main-pool inputs into
  the main pool (@sec:policy-tickets);
+ removes every main-pool transaction that spends an outpoint the block
  transaction spends, together with its dependents, and every stage-pool
  transaction that does so;
+ removes the transaction from the orphan pool;
+ reprocesses the orphans that spend it (@sec:policy-orphans) and relays any
  accepted.

The fee estimator records the block before these removals
(@sec:policy-feeest). If the new block disapproves its parent's regular tree
(vote bit 0 of its header clear), the parent's regular transactions other
than the coinbase are re-added as described below, since disapproval makes
it as if they had never been mined.

*Block disconnected.* If the disconnected block had disapproved its parent,
the parent's regular transactions (other than the coinbase) are valid again
and are treated as in steps 1–5 above, except that accepted orphans are not
relayed. Then the disconnected block's regular
transactions other than the coinbase, and afterwards its stake transactions
(other than the treasurybase when the treasury agenda is active), are
re-added.

*Re-adding.* A batch of transactions in block order is re-added by
processing it in *reverse* order, with the not-yet-processed earlier
transactions of the batch made available as a source of inputs (the
"transient" pool). Each goes through @alg:policy-accept marked not new. If it
fails for any reason other than being a duplicate, already existing, or
spending a missing or spent output, it is removed from the pool together with
its dependents; orphan results are discarded.

*After a block becomes the tip* (by extension or as the result of a
reorganization it caused when processed; a forced reorganization by the
template generator, @sec:policy-parent, does not trigger this), the node prunes stake transactions as in
@sec:policy-tickets, @sec:policy-votes and @sec:policy-revocations, removes
from the main pool (with dependents) and from the stage pool every
transaction for which $"tip height" + 1 >= "expiry" != 0$, and, when the
block was received from a peer (not when it was submitted locally through
`submitblock`, `getwork` or the CPU miner), clears its
filter of recently rejected transaction hashes (an approximate filter of up
to 62500 entries with a false-positive rate of $10^(-7)$, used to avoid
re-requesting and re-validating transactions that peers keep announcing).

== Block Template Construction <sec:policy-template>

A _block template_ is a complete block, valid in every respect except the
proof of work, that the node hands to miners. Templates are built by
`NewBlockTemplate` and maintained in the background by the generator of
@sec:policy-bg. The generator runs only when at least one mining address is
configured (`--miningaddr`); each template pays to one of them chosen
uniformly at random.

=== Choosing the Parent <sec:policy-parent>

Before #param("StakeValidationHeight") the template always extends the tip.
From then on a block must contain at least $floor("TicketsPerBlock" / 2) + 1$
votes (3 on every network) on its parent, so the parent is chosen by the
votes available:

+ Let the _tip generation_ be the set of all chain tips (blocks with no known
  children) at the tip's height, the tip included.
+ Keep the blocks with at least 3 votes recorded in the vote tracker and sort
  them by vote count, descending. If the first block has the same count as
  the current tip but is a different block, swap the current tip into the
  first position, so that the node does not reorganize between equally
  supported siblings.
+ If no block qualifies, build the replacement template of
  @sec:policy-toofew.
+ Otherwise walk the sorted list. Stop at the current tip. For any other
  block, ask the chain to _force a reorganization_ to it, which succeeds only
  if it is a sibling of the tip (same parent) whose data is available and
  that is not known to be invalid; on failure, try the next block. After a
  successful reorganization, if any vote recorded for the new tip is no
  longer in the pool, try the next block; otherwise use the new tip as
  parent.

The forced reorganization is the one place where the reference node
deliberately selects between equal-work siblings by policy; chain selection
proper is specified in #chref("blocks").

#pitfall[
  `NewBlockTemplate` reads the next-block state (winning tickets, expiring
  tickets, final state, pool size, stake difficulty, missed tickets, tip
  header, the median time used for the finality filter, agenda states, and
  the block passed to the
  ticket-exhaustion check) from the best-chain snapshot taken *before* any
  forced reorganization in this step, while the vote filter, the treasury
  budget, `Bits`, `StakeVersion` and `PrevBlock` use the new parent. The
  forced reorganization emits the usual reorganization events, on which the
  background generator clears its current template and afterwards handles
  the new tip as newly connected (@sec:policy-bg).
]

=== Candidate Collection <sec:policy-candidates>

Every main-pool transaction is examined; it becomes a candidate unless

- it is a coinbase;
- it is not final for height $"next"$ and the tip's median time;
- it is a vote whose committed block is not exactly (parent hash, $"next" - 1$);
- one of its inputs (other than the stakebase input of a vote and the input
  of a treasury spend) is neither unspent in the chain view (excluding the
  parent's regular tree when known disapproved) nor created by a
  transaction whose hash is in the main, stage or orphan pool.

For each candidate the node computes its _fee rate_ and _priority_:

$ "feePerKB" = ((f + F_a) dot 1000) / (s + S_a) $ <eq:policy-feerate>

as a floating-point number, where $f$ and $s$ are the transaction's fee and
full serialized size and $F_a$, $S_a$ the total fee and size of its
unconfirmed ancestors still in the pool (both zero when ancestor statistics
are unavailable). The _priority_ is the legacy Bitcoin coin-age priority,
used only as a tie-breaker:

$ "priority" = (sum_i v_i dot ("next" - h_i)) / (s - sum_i (58 + min(110, |"sigScript"_i|))) $

summed over inputs found in the view, where $v_i$ is the input value and $h_i$
the height of the spent output (age 0 when the output is unconfirmed), and
the priority is 0 if the denominator is not positive.

A candidate is pushed onto the priority queue immediately if it has no
parents in the pool, or if ancestor statistics are available for it (see
below). A candidate with pool parents but no statistics waits until all its
parents have been included in the template.

*Ancestor statistics.* When the node has a mining address, the pool tracks
for each transaction the total fee, size and signature operations of its
unconfirmed ancestors, allowing a low-fee parent to be mined because of a
high-fee child ("child pays for parent"). Tracking is abandoned for a
transaction (its statistics become unavailable) if it would have more than
25 (`ancestorTrackingLimit`) ancestors, if any of its ancestors has no
statistics itself, or if any ancestor already has 25 ancestors or 25 tracked
descendants. This limit affects only template
construction, not pool admission.

=== Ordering <sec:policy-ordering>

The queue pops the candidate that is greatest under the following order:

+ higher *stake priority* first: votes (3), then automatic revocations
  created by the generator (2), then ticket purchases (1), then everything
  else (0) — regular transactions, revocations from the pool, treasury adds
  and treasury spends;
+ within equal stake priority, higher `feePerKB`;
+ for equal `feePerKB`, higher `priority`.

Ties beyond that are broken by the heap's internal order, which is not
specified.

=== Selection <sec:policy-selection>

@alg:policy-select gives the selection loop. `BlockMaxSize` is the
`--blockmaxsize` option (default 375000 bytes, permitted range 1000 to
#param("MaximumBlockSizes")\[0\] $- 1000$, i.e. 392216 on the main network);
`TxMinFreeFee` equals the minimum relay fee rate. `mark_rejected(x)` removes
$x$ and all its pool descendants from consideration for this template.

#algorithm("Block template transaction selection (policy)", src: "internal/mining/mining.go · NewBlockTemplate")[
  ```python
  size = 180 + 9                   # header + maximum varint (blockHeaderOverhead)
  sigops = 0
  revocations_added = False
  while queue:
      x = queue.pop()
      if x in template: continue
      if AUTOREVOCATIONS and not revocations_added and x.type != VOTE:
          # all votes have been considered: revoke every winning ticket that
          # has no vote in the template and every ticket expiring in this block
          for ticket in unvoted_winners() + expiring_tickets():
              queue.push(auto_revocation(ticket))   # version 2, zero fee
          revocations_added = True
          queue.push(x); continue
      if x.type == TSPEND:
          if not is_tvi(next) or not inside_tspend_window(next, x.expiry): continue
          if not tspend_has_enough_votes(parent, x): continue
          if budget - x.value_in < 0: continue
          budget -= x.value_in       # budget = max treasury expenditure (TVI only)
      if x.type == TADD and n_tadds >= 20: continue          # MaxTAddsPerBlock
      if x.type == TICKET and n_tickets >= MaxFreshStakePerBlock: continue
      if x.type == TICKET and x.out[0].value < next_stake_difficulty: continue
      if x.type == REVOCATION and not (
              (AUTOREVOCATIONS and ticket_missed_or_expiring_this_block(x))
              or ticket_in_missed_set(x)):
          continue
      if is_rejected(x): continue
      anc = ancestors_not_in_template(x)
      rate = fee_per_kb(x, anc)
      if rate < x.fee_per_kb:          # some ancestors were already included
          x.fee_per_kb = rate
          if not anc: queue.push(x)    # re-queue with the corrected rate
          continue                     # else wait until all parents are included
      if uint32(size + x.size + total_size(anc)) overflows or \
              size + x.size + total_size(anc) >= BlockMaxSize:
          mark_rejected(x); continue
      if sigops + x.sigops + total_sigops(anc) > 5000:     # MaxSigOpsPerBlock
          mark_rejected(x); continue
      if x.type == VOTE and (ticket_already_voted_in_template(x)
                             or not ticket_is_winner(x)):
          continue
      if x.tree == REGULAR and x.fee_per_kb < TxMinFreeFee:
          mark_rejected(x); continue
      for y in anc + [x]:              # ancestors in topological order
          if not inputs_valid(y) or not scripts_valid(y, standard_flags):
              mark_rejected(y); continue outer loop
      for y in anc + [x]:
          add y to template; spend its inputs; size += y.size; sigops += y.sigops
          count tickets, votes, treasury adds
          queue.push(c) for each child c of y now without parents in the pool
  if AUTOREVOCATIONS and not revocations_added:
      add revocations as above and resume the loop
  ```
] <alg:policy-select>

Notes on @alg:policy-select:

- `inputs_valid` is the consensus input check of #chref("transactions")
  for height $"next"$ against the tip header, *without* the fraud-proof
  check (the fraud proofs are filled in afterwards).
- Automatic revocations are created only after all votes have been
  considered, so that tickets whose votes failed any check are revoked
  rather than left unvoted; their format is specified in #chref("staking").
  A pool revocation identical to an automatic one has the same hash and is
  skipped as already included.
- The treasury budget is the maximum treasury expenditure for a block
  extending the parent (#chref("treasury")), computed only when the next
  block is at or above #param("StakeValidationHeight") and on a treasury
  vote interval. Treasury spends compete for it in queue order.
- The size budget counts every selected transaction but not the coinbase or
  treasurybase, and the final header `Size` is the actual serialized size;
  the 1000-byte margin below the consensus limit absorbs the difference.

#pitfall[
  The template's fee-rate floor uses the exact floating-point rate of
  @eq:policy-feerate, whereas pool admission uses the truncated integer
  minimum of @alg:policy-minfee. A transaction can therefore be admitted but
  never selected on its own by the reference node (it can still be included
  as an ancestor of a child whose combined rate passes the floor, since the
  floor is applied only to the popped candidate): at a relay rate of 2550 atoms/kB a
  782-byte transaction needs a fee of 1994 atoms to enter the pool, but its
  rate of 1994000/782 ≈ 2549.87 atoms/kB is below the floor. At the default
  rate of 10000 atoms/kB the minimum fee is always exactly $10 n$ and the
  effect does not occur.
]

=== Assembling the Trees <sec:policy-assembly>

After selection, the two transaction trees are assembled from the selected
transactions in selection order. Every stake transaction placed in the stake
tree is first copied and has its inputs re-resolved against the chain UTXO
view (excluding the parent's regular tree when known disapproved), with its
fraud-proof fields set from that view; a stake transaction with an input not
found there is dropped. The stake tree is, in order:

+ the treasurybase, if the treasury agenda is active (@sec:policy-coinbase);
+ if $"next" >= "StakeValidationHeight"$, the selected votes (at most
  #param("TicketsPerBlock"), since a vote is only selected for a distinct
  winning ticket);
+ the selected ticket purchases that spend no output of any selected
  transaction and still pay at least the next stake difficulty, up to
  #param("MaxFreshStakePerBlock") (20);
+ if $"next" >= "StakeValidationHeight"$, the selected revocations, up to
  255;
+ if the treasury agenda is active, the selected treasury adds and treasury
  spends, interleaved in selection order.

Selected transactions dropped here are simply absent from the block. The node
then checks that adding the block with this number of ticket purchases
cannot lead to ticket exhaustion (#chref("staking")) and abandons the
template otherwise.

The regular tree is the coinbase followed by the selected regular
transactions in selection order, which places every parent before its
children. The fraud-proof fields of each regular input (from height 2 on)
are set from the chain view; an input whose output is not in the chain must
be created by an earlier transaction of the same tree, and gets
`ValueIn` = that output's value, `BlockHeight` = $"next"$ and `BlockIndex` =
the creating transaction's index in the regular tree.

If $"next" >= "StakeValidationHeight"$ and fewer than 3 votes ended up in the
stake tree, the template is abandoned in favour of the replacement template
of @sec:policy-toofew.

=== Coinbase and Treasurybase <sec:policy-coinbase>

The amounts are those of #chref("subsidy") and #chref("treasury"), computed
for height $"next"$ with the number of votes $V$ in the template and the
subsidy-split variant selected by the active agendas.

*Fees.* Let $F$ be the sum of the fees of all transactions in both trees.
From #param("StakeValidationHeight") on, $F <- floor(F dot V / "TicketsPerBlock")$
(the same reduction consensus applies, #chref("blocks")). For heights above
1, $F$ is added to the value of the proof-of-work output.

#figure(
  caption: [Coinbase transaction built by the template generator],
  table(
    columns: (auto, 1fr),
    table.header([Element], [Value]),
    [Version], [1 before the treasury agenda; 3 (`TxVersionTreasury`) once it is active.],
    [Input], [Previous outpoint: zero hash, index `0xffffffff`, regular tree; sequence `0xffffffff`; `BlockHeight` 0; `BlockIndex` `0xffffffff`; `ValueIn` = work subsidy + treasury subsidy (the latter only before the treasury agenda), *excluding* fees.],
    [Signature script], [`00 00` followed by the ASCII bytes of `/dcrd/` (8 bytes).],
    [Output 0 (before the treasury agenda only)], [If #param("BlockTaxProportion") $> 0$: the treasury subsidy paid to #param("OrganizationPkScript") (script version 0); otherwise value 0 to the script `OP_TRUE`.],
    [Next output], [Value 0, script `6a 0c` ‖ $"LE"_32("next")$ ‖ $"LE"_64(r)$: `OP_RETURN` with a 12-byte push of the height and a fresh random 64-bit extra nonce $r$, which makes every template's merkle root unique.],
    [Last output], [Work subsidy plus $F$, paid to the mining address's payment script (or `OP_TRUE`, version 0, when no address is given).],
    [Height 1], [When #param("BlockOneLedger") is non-empty, the coinbase instead has version 1, `ValueIn` = the block-one subsidy, and one output per ledger entry (#chref("subsidy")).],
  ),
) <tab:policy-coinbase>

The treasurybase (treasury agenda active) has version 3; one input with the
same null outpoint, sequence, `BlockHeight`, `BlockIndex` as the coinbase,
an empty signature script and `ValueIn` equal to the treasury subsidy;
output 0 paying the treasury subsidy to the one-byte script `OP_TADD`
(`c1`), script version 0; and output 1 of value 0 with the same 12-byte
`OP_RETURN` height-and-random-nonce script as the coinbase (with its own
random nonce).

=== Header Fields <sec:policy-header>

#figure(
  caption: [Header of a block template],
  table(
    columns: (auto, 1fr),
    table.header([Field], [Value]),
    [`Version`], [11 on the main network (`generatedBlockVersion`), 12 on all other networks (`generatedBlockVersionTest`).],
    [`PrevBlock`], [The chosen parent (@sec:policy-parent).],
    [`MerkleRoot`], [With the `headercommitments` agenda (#dcp(5)) active for the block: the combined root of both trees; otherwise the regular tree's merkle root (#chref("encoding")).],
    [`StakeRoot`], [With `headercommitments` active: the version 1 commitment root over the block's version 2 compact filter (#chref("filters")); otherwise the stake tree's merkle root.],
    [`VoteBits`], [Below #param("StakeValidationHeight"): `0x0001`. Otherwise `0x0001` if strictly more than half of the included votes set bit 0 of their vote bits (approve the parent's regular tree), else `0x0000`. No other bits are set.],
    [`FinalState`, `PoolSize`, `SBits`], [The next-block values from the chain state (#chref("staking"), #chref("difficulty")).],
    [`Voters`, `FreshStake`, `Revocations`], [The numbers of votes, tickets and revocations in the stake tree.],
    [`Bits`], [The required proof-of-work difficulty for a block extending the parent with this timestamp (#chref("difficulty")).],
    [`Height`], [$"next"$.],
    [`Size`], [The serialized size of the complete block.],
    [`Timestamp`], [See below.],
    [`Nonce`, `ExtraData`], [Zero; varied by the miner.],
    [`StakeVersion`], [The stake version expected for the block after the parent (#chref("voting")).],
  ),
) <tab:policy-header>

*Timestamp.* The generator takes the network-adjusted time (local clock
corrected by the median offset reported by peers), raises it to one second
after the tip's median time if it is earlier, and then subtracts
`--miningtimeoffset` seconds (default 0; positive values move the timestamp
into the past). The header stores whole seconds. Miners refresh the
timestamp the same way while they work (@sec:policy-getwork,
@sec:policy-cpuminer); `Bits` is not recomputed when they do.

Finally the complete block is validated against every consensus rule except
the proof of work (#chref("blocks")); a template that fails is discarded and
an error recorded.

=== Replacement Template When Votes Are Missing <sec:policy-toofew>

If the next block is at or above #param("StakeValidationHeight") and no
block of the tip generation has 3 votes, or too few votes survive into the
stake tree, the generator by default ("aggressive mining") builds a
*replacement for the tip*: a sibling of the tip, at the tip's height and
extending the tip's parent, which already has votes. With `--nonaggressive`
it produces no template instead. The replacement:

- starts from a copy of the tip's header, so every field not listed here
  (including `Version`, `FinalState`, `Voters`, `FreshStake`,
  `Revocations`, `PoolSize`, `SBits`, `StakeVersion`, `Nonce` and
  `ExtraData`) keeps the tip's value;
- has a new coinbase built for the tip's height and the tip's `Voters`, with
  a fresh extra nonce and *no fees added* to the proof-of-work output; its
  version, treasury output and subsidy split are selected by the agenda
  states for the block after the tip (not after the tip's parent);
- if the treasury agenda is active for the block after the tip, has a new
  treasurybase for the tip's height and `Voters`;
- contains all of the tip's other regular transactions and all of its other
  stake transactions, in the tip's order (the tip's first stake transaction
  is skipped as its treasurybase whenever the treasury agenda is active for
  the block after the tip);
- has a fresh `Timestamp` (as above), recomputed `Size`, `MerkleRoot` and
  `StakeRoot` (using the agenda state for the block after the tip's
  parent), and `Bits` recomputed for a block extending the tip's parent.

It is fully validated as a block connecting to the tip's parent. Because the
coinbase differs, the replacement has a different hash from the tip and
competes with it; it can win only if the tip never collects enough votes.

== Background Template Generation <sec:policy-bg>

The background generator keeps one current template and regenerates it in
response to chain events, votes and new transactions. Its aim is to start
work on a new tip as soon as it can be mined, to include as many votes as
possible without waiting long, and to prefer the first block seen at a
height so that a miner cannot gain an advantage by withholding the votes on
a competitor's block. Generation runs asynchronously; starting a new
generation cancels any in progress. While a generation triggered by a new
parent or new votes is running, requests for the current template block
until it finishes.

No templates are generated while the node is not synced unless
`--allowunsyncedmining` is given (refused on the main network, always on for
the simulation and regression networks), nor during a chain reorganization:
when a reorganization starts the current template is cleared and requests
block; when it ends the new tip is handled as a newly connected block. At
startup (after waiting for sync if required) the tip is likewise handled as
newly connected.

#figure(
  caption: [Template regeneration triggers. $V(B)$ is the number of votes on
    block $B$ in the vote tracker; $V_"max"$ = #param("TicketsPerBlock") (5);
    $V_"min"$ = $floor(V_"max" / 2) + 1$ (3).],
  table(
    columns: (36%, 1fr),
    table.header([Event], [Reaction]),
    [New tip $B$ connected, $"height"(B) + 1 < "StakeValidationHeight"$], [Generate immediately on $B$.],
    [New tip $B$ connected, $V(B) >= V_"max"$], [Generate immediately on $B$.],
    [New tip $B$ connected, $V_"min" <= V(B) < V_"max"$], [Lock $B$ in as the base; start a 2.5 s timer (`maxVoteTimeoutDuration`). Generate when it fires, or earlier when $V(B)$ reaches $V_"max"$.],
    [New tip $B$ connected, $V(B) < V_"min"$], [Keep the current template (normally built on $B$'s parent, so that it competes with $B$); stop the regeneration timer; start a 3 s timer (`minVotesTimeoutDuration`).],
    [Vote on such a waiting tip $B$], [When $V(B) >= V_"min"$: lock $B$ in, cancel side-chain tracking, then as for a newly connected tip with that many votes.],
    [3 s timer fires, $B$ still short of votes], [Consider $B$'s siblings in the tip generation in descending order of votes: force a reorganization to the first with $V >= V_"min"$ for which it succeeds, and build on it once the reorganization completes. Otherwise start watching the siblings with fewer than $V_"min"$ votes; if no base block is set for the next template (at startup and after a reorganization), generate on $B$'s parent (which yields the replacement template of @sec:policy-toofew); else restart the 30 s timer.],
    [Block accepted that is a sibling of a tip still short of votes (after the 3 s timer)], [Watch it for votes; when it reaches $V_"min"$, force a reorganization to it.],
    [Vote on the base block of the current template], [If the template already has $V_"max"$ votes, nothing. Otherwise regenerate immediately with the extra vote, except while the 2.5 s timer is pending, when only reaching $V_"max"$ triggers.],
    [Template generated], [Record the time; (re)start a 30 s timer (`templateRegenSecs`).],
    [30 s timer fires], [If the pool changed (to the second) since the template was generated, regenerate to include new transactions; otherwise check again every second.],
    [Generation failed], [Retry after 1 s.],
    [Tip disconnected], [Generate immediately on the new tip (its votes were in the disconnected block).],
    [`regentemplate` RPC], [Regenerate immediately, unless the 2.5 s timer is pending.],
  ),
) <tab:policy-bg>

Subscribers (the CPU miner and websocket `notifywork` clients) receive each
new template with a reason: _new parent_ (also used for the first template on
a parent even if triggered by a vote), _new votes_ or _new transactions_.
A new subscriber immediately receives the current template. Notifications
are dropped for subscribers that fall more than
$2 (V_"max" - V_"min" + 1)$ notifications behind.

== Mining Interfaces <sec:policy-mining>

dcrd provides work to external miners through the `getwork` RPC and its
websocket counterpart `notifywork`; it has no `getblocktemplate` RPC. Solved
blocks can also be submitted whole with `submitblock`.

=== getwork Data <sec:policy-getwork>

`getwork` without arguments returns an object with two hex strings, `data`
and `target`. `data` is the 180-byte serialized block header
(#chref("encoding")), *exactly as serialized*, with every integer
little-endian and no per-word byte swapping, followed by 12 bytes of padding,
for a total of 192 bytes (both `getworkDataLenBlake256` and
`getworkDataLenBlake3` are 192). @tab:policy-getwork gives the offsets.

#figure(
  caption: [Layout of getwork `data` (offsets in bytes)],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Offset], [Size], [Field], [Notes]),
    [0], [4], [`Version`], [],
    [4], [32], [`PrevBlock`], [],
    [36], [32], [`MerkleRoot`], [With `StakeRoot`, identifies the template on submission.],
    [68], [32], [`StakeRoot`], [],
    [100], [2], [`VoteBits`], [],
    [102], [6], [`FinalState`], [],
    [108], [2], [`Voters`], [],
    [110], [1], [`FreshStake`], [],
    [111], [1], [`Revocations`], [],
    [112], [4], [`PoolSize`], [],
    [116], [4], [`Bits`], [],
    [120], [8], [`SBits`], [],
    [128], [4], [`Height`], [Start of the third 64-byte block.],
    [132], [4], [`Size`], [],
    [136], [4], [`Timestamp`], [May be updated by the miner.],
    [140], [4], [`Nonce`], [Varied by the miner.],
    [144], [32], [`ExtraData`], [Extra nonce space; dcrd's own miner uses the first 8 bytes.],
    [176], [4], [`StakeVersion`], [],
    [180], [12], [padding], [See below; not part of the hashed message.],
  ),
) <tab:policy-getwork>

The padding makes the last 64 bytes of `data` exactly the final message
block of the hash function in use, so a miner can compute the state after
the first two blocks (bytes 0–127) once and iterate only on the final block,
which contains `Timestamp`, `Nonce` and `ExtraData`. Which hash is used is
decided by whether the `blake3pow` agenda (#dcp(11)) is active for the block
after `PrevBlock`:

- *BLAKE-256* (agenda inactive): the padding is the BLAKE-256 message
  padding for a 1440-bit message, #hex("8000000100000000000005a0"): the byte
  `80`, two zero bytes, the byte `01` (the final 1 bit of BLAKE padding), and
  the bit length 1440 as a big-endian 64-bit integer. The final block is
  processed with counter 1440.
- *BLAKE3* (agenda active): the padding is 12 zero bytes. BLAKE3 hashes the
  180-byte header as a single chunk of three blocks; the final block must be
  compressed with a block length of 52 (not 64), counter 0 and the
  chunk-end and root flags, the zero padding being the zero fill BLAKE3
  applies to a short block.

In both cases the proof-of-work hash is computed over the 180 header bytes
only, as specified in #chref("difficulty")\; the padding is a convenience and
is not hashed as message data.

`target` is the 256-bit target encoded by `Bits` (#chref("difficulty")),
written as 32 bytes *little-endian*. A hash solves the work when, read as a
little-endian 256-bit integer, it is less than or equal to the target.

#pitfall[
  Source comments in dcrd's `serializeGetWorkData` list `Bits`,
  `Timestamp`, `Nonce` and the extra nonce at offsets one byte lower than the
  ones the serialization actually produces. @tab:policy-getwork gives the
  offsets of the serialized data, which agree with the offsets the CPU
  miner writes to (136, 140 and 144).
]

#vector[getwork data for the main-network genesis header (BLAKE-256 padding)][
  ```
    0  0100000000000000000000000000000000000000000000000000000000000000
   32  000000000dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb9
   64  9174aa6600000000000000000000000000000000000000000000000000000000
   96  0000000000000000000000000000000000000000ffff011b00c2eb0b00000000
  128  0000000000000000a0d7b8560000000000000000000000000000000000000000
  160  00000000000000000000000000000000000000008000000100000000000005a0

  With BLAKE3 padding the last 12 bytes are 000000000000000000000000.
  target (Bits 1b01ffff):
       000000000000000000000000000000000000000000000000ffff010000000000
  ```
]

*Serving work.* `getwork` fails if the CPU miner is running, if no mining
address is configured, if the node has no peers or is not synced (both
unless unsynced mining is allowed; the sync check is also skipped while
both the best header and the best block are at height 0; these first four
checks apply to submissions as well), or, for a request, if the current
background template is in an error state. Requests and submissions are
serialized. When the tip has changed since the previous request, templates
whose height is below $"tip height" - 3$ (`getworkExpirationDiff`) are
discarded and the request waits for a fresh template: it takes the next
template notification (the current template is delivered at once), and if
that template has already been handed out, waits up to a further 5.5 s for a
newer one before falling back to the current template. The header of the
chosen template is copied, its timestamp refreshed as in
@sec:policy-header, serialized as above, and the template is stored in a
table keyed by the 64 bytes `MerkleRoot` ‖ `StakeRoot`. Because the coinbase
extra nonce makes the merkle root unique per template, refreshing the
timestamp does not create new entries.

=== Work Submission <sec:policy-submit>

`getwork` with a `data` argument submits a solution:

+ The hex string, after prefixing a `0` if its length is odd, must decode to
  exactly 192 bytes; otherwise an invalid-parameter error is returned.
+ The first 180 bytes are deserialized as a header; the padding is ignored.
+ If `PrevBlock` is unknown the result is `false`.
+ The proof-of-work hash (BLAKE-256 or BLAKE3 as above) must satisfy the
  proof-of-work check against the header's own `Bits` and the network's
  proof-of-work limit; otherwise `false`.
+ The template is looked up by `MerkleRoot` ‖ `StakeRoot`; if absent,
  `false`.
+ The block is reconstructed from the template's transactions and the
  *submitted* header in its entirety (so every header field is taken from
  the miner), and processed exactly like a block received from a peer. The
  result is `true` if it is accepted and `false` if consensus rejects it.

=== notifywork <sec:policy-notifywork>

A websocket client that has called `notifywork` receives a `work`
notification for every new background template, with the same `data` and
`target` encodings and a `reason` of `newparent`, `newvotes`, `newtxns` or
`unknown`. The data carries the template's own timestamp (not refreshed).
Each notified template is stored in the same submission table, which is
pruned as above whenever the reason is `newparent`. `stopnotifywork` ends the
subscription.

=== Other Mining RPCs <sec:policy-otherrpc>

#figure(
  caption: [Mining-related RPC methods],
  table(
    columns: (auto, 1fr),
    table.header([Method], [Behaviour]),
    [`submitblock`], [Accepts a fully serialized block in hex (a leading `0` is added to odd-length input) and processes it like a block from a peer; returns null on success or the string `rejected: ` followed by the reason.],
    [`regentemplate`], [Asks the background generator to regenerate (@tab:policy-bg).],
    [`generate`], [Mines the requested number of blocks with the CPU miner and returns their hashes. Refused on networks with #param("GenerateSupported") false (the main network).],
    [`setgenerate`, `getgenerate`], [Start or stop the CPU miner with a given number of workers (0 stops it); report whether it runs.],
    [`gethashespersec`, `getmininginfo`, `getnetworkhashps`], [Informational.],
    [`estimatefee`], [Returns the configured minimum relay fee rate in DCR/kB, irrespective of the argument.],
    [`estimatesmartfee`], [Returns the fee estimator's result (@sec:policy-feeest) for a confirmation target; only the `conservative` mode is supported.],
  ),
) <tab:policy-rpc>

=== CPU Miner <sec:policy-cpuminer>

The built-in CPU miner, intended for test networks, subscribes to the
background generator and works on each new template, abandoning the previous
one. A worker serializes the header once, picks a random 64-bit offset, and
for each extra nonce value (offset plus a counter, wrapping) writes it
little-endian into `ExtraData`\[0:8\] (offset 144) and tries every nonce
from 0 to $2^32 - 1$ (offset 140), hashing with BLAKE-256 or BLAKE3 as the
`blake3pow` agenda dictates and accepting a hash less than or equal to the
target. Every 65535 nonces it checks for cancellation and refreshes the
timestamp (offset 136). Without peers it waits, except on the simulation and
regression networks, where it also stops after 4 solved blocks on the same
parent fail to be accepted, so that a stalled simulated chain is not mined
pointlessly. It runs one worker by default, at most twice the number of CPU
cores.

== Fee Estimation <sec:policy-feeest>

The fee estimator (`internal/fees`) answers `estimatesmartfee`: the fee rate
that, judged by recent history, gets a transaction confirmed within a target
number of blocks with high probability. It is purely advisory and uses
floating-point arithmetic throughout.

*Buckets.* Fee rates are divided into buckets whose upper bounds start at
the minimum relay fee rate $r$ and grow by a factor of 1.1
(`DefaultFeeRateStep`) while below $100 r$ (`DefaultMaxBucketFeeMultiplier`).
An extra bound of 100000 atoms/kB (the default minimum relay fee of dcrd
releases up to 1.1.0) is inserted where the sequence crosses it, and a last
bound of $+infinity$ catches everything else. With the default $r = 10000$
this gives 51 buckets: 10000, 11000, 12100, …, 98497.33, 100000, 108347.06,
…, 970172.34, $+infinity$. A rate falls in the first bucket whose bound is
at least the rate. Each bucket keeps, for each of 32 confirmation ranges
(`DefaultMaxConfirmations`; range $c$ means "confirmed within $c + 1$ blocks",
the last range meaning "32 or more"), a decayed count of confirmed
transactions and the sum of their rates, plus the same data for transactions
still in the pool.

*Tracking.* The estimator starts when the first block is accepted after
startup while the node is synced (or unsynced mining is allowed). A transaction entering the pool is recorded if it has not been
recorded before, is not a treasury spend, and its rate
$floor(f / s) dot 1000$, computed with integer division *before* the
multiplication, is at least $r$; so recorded rates are multiples of 1000
atoms/kB, and votes (fee 0) are never recorded. A recorded transaction is
placed in range 0 of its bucket's pool data, together with the estimator's
current height (the height of the last block it processed, or of the block
that started it).

*Per block.* When a block is connected at a height above the last processed
one (reorganizations are not tracked): every confirmed statistic is
multiplied by 0.998 (`defaultDecay`); the pool data of every bucket shifts
up one range, the next-to-last range being added into the last; and each
transaction of the block that was recorded is moved from the pool data to
the confirmed data, counted in every range from $d - 1$ (capped at 31)
upward, where $d$ is the block height minus the height at which it entered
the pool. Unrecorded transactions are ignored, so a miner cannot skew the
estimate with transactions it never broadcast. Transactions leaving the pool
unmined are removed from the pool data.

*Estimate.* For a target of $k$ blocks ($1 <= k <= 32$), with range index
$c = k - 1$ and required success ratio 0.95: walk the buckets from the
highest down, accumulating the total (all confirmed transactions of the
bucket plus those still pending in range $c$) and the number confirmed
within range $c$. Whenever the accumulated
total exceeds 1, close a group: if its success ratio is below 0.95, stop
(failing if no group has passed yet); otherwise remember it as the best
group and start a new one. If no group is ever closed, the best group is the
highest ($+infinity$) bucket alone. The estimate is the average rate (rate sum
divided by count) of the bucket containing the median confirmed transaction
of the best — that is, the lowest-fee passing — group (failing if that group
has no confirmed transactions), rounded to the
nearest atom and raised to $r$ if lower. The estimator's state, but not its
pool data, persists across restarts in a `feesdb` database in the data
directory.

== Policy Constants <sec:policy-constants>

#figure(
  caption: [Policy constants of the reference node. Per-network values are
    main-network values; options are command-line or configuration
    settings.],
  table(
    columns: (31%, 25%, 1fr),
    table.header([Name], [Value], [Meaning]),
    table.cell(colspan: 3)[_Mempool (`internal/mempool`)_],
    [`MaxStandardTxSize`], [100000 bytes], [Largest standard transaction; also `MaxOrphanTxSize`.],
    [`maxStandardSigScriptSize`], [1650 bytes], [Largest standard signature script.],
    [`maxStandardP2SHSigOps`], [15], [Sigops allowed in a standard P2SH redemption.],
    [`maxStandardMultiSigKeys`], [3], [Keys allowed in a standard bare multisig output.],
    [`maxNullDataOutputs`], [4], [Null-data outputs allowed in a standard regular transaction.],
    [`MaxDataCarrierSizeV0`], [256 bytes], [Largest standard null-data push (`txscript/stdscript`).],
    [`DefaultMinRelayTxFee`], [10000 atoms/kB], [Default `--minrelaytxfee` (0.0001 DCR/kB); also the template fee floor and dust basis.],
    [dust input size, divisor], [165 bytes, 3], [Constants of @eq:policy-dust.],
    [`maxRelayFeeMultiplier`], [10000], [High-fee limit factor (1 DCR/kB by default).],
    [`MaxSigOpsPerTx`], [1000], [`MaxSigOpsPerBlock` / 5.],
    [`BaseStandardVerifyFlags`], [—], [Discourage upgradable NOPs, clean stack, CLTV, CSV.],
    [`AcceptNonStdTxs`], [false], [Per network; true on testnet, simnet, regnet.],
    [`defaultMaxOrphanTransactions`], [100], [Default `--maxorphantx`.],
    [`orphanTTL`], [15 min], [Orphan lifetime.],
    [`orphanExpireScanInterval`], [5 min], [Minimum time between orphan expiry scans.],
    [`maxFutureVoteAge`], [5], [Blocks beyond the tip a vote may reference.],
    [`MaxVoteAge`], [#param("CoinbaseMaturity") (256)], [Vote age window; 1440 on testnet (`defaultMaximumVoteAge`).],
    [`defaultAllowOldVotes`], [false], [Default of `--allowoldvotes`.],
    [`maxVoteDoubleSpends`], [5], [Votes per ticket in the pool.],
    [`heightDiffToPruneTicket`], [288], [Ticket age (blocks) before pruning.],
    [`heightDiffToPruneVotes`], [10], [Vote and revocation age before pruning; also tracker pruning.],
    [`MempoolMaxConcurrentTSpends`], [7], [Treasury spends in the pool.],
    [tspend start threshold], [$2 T M$ (6912)], [Maximum distance to a treasury spend's voting window.],
    [`maxRejectedTxns`], [62500], [Capacity of the rejected-hash filter (`internal/netsync`), false-positive rate $10^(-7)$.],
    [`maxReorgDepthNotify`], [6], [Reorganization depth limit for winning-ticket notifications.],
    table.cell(colspan: 3)[_Block templates (`internal/mining`, `config.go`)_],
    [`generatedBlockVersion`], [11], [Template block version, main network.],
    [`generatedBlockVersionTest`], [12], [Template block version, other networks.],
    [`defaultBlockMaxSize`], [375000 bytes], [Default `--blockmaxsize`.],
    [`blockMaxSizeMin`], [1000 bytes], [Smallest permitted `--blockmaxsize`.],
    [`blockMaxSizeMax`], [#param("MaximumBlockSizes")\[0\] $- 1000$], [Largest permitted `--blockmaxsize` (392216).],
    [`blockHeaderOverhead`], [189 bytes], [`MaxBlockHeaderPayload` (180) + `MaxVarIntPayload` (9).],
    [`coinbaseFlags`], [`/dcrd/`], [Coinbase signature script tag (after two zero bytes).],
    [`ancestorTrackingLimit`], [25], [Ancestor/descendant limit for ancestor statistics.],
    [`UnminedHeight`], [`0x7fffffff`], [Height assigned to outputs of unconfirmed transactions.],
    [`MaxTAddsPerBlock`], [20], [Consensus limit, enforced during selection.],
    [`MaxSigOpsPerBlock`], [5000], [Consensus limit, enforced during selection.],
    [minimum votes], [$floor("TicketsPerBlock" / 2) + 1$ (3)], [Votes needed to build on a block.],
    [`MiningTimeOffset`], [0 s], [Default `--miningtimeoffset`.],
    [aggressive mining], [on], [Replacement templates unless `--nonaggressive`.],
    [`defaultAllowUnsyncedMining`], [false], [Forced on for simnet and regnet; refused on mainnet.],
    table.cell(colspan: 3)[_Background generator_],
    [`minVotesTimeoutDuration`], [3 s], [Wait for the minimum votes before considering siblings.],
    [`maxVoteTimeoutDuration`], [2.5 s], [Wait for further votes after the minimum is reached.],
    [`templateRegenSecs`], [30 s], [Regeneration interval for new transactions.],
    [retry and recheck delay], [1 s], [After a failed generation; between pool-change checks.],
    table.cell(colspan: 3)[_Mining interfaces (`internal/rpcserver`, `internal/mining/cpuminer`)_],
    [`getworkDataLenBlake256`, `getworkDataLenBlake3`], [192 bytes], [Length of getwork `data`.],
    [`getworkExpirationDiff`], [3], [Templates below tip height − 3 are discarded.],
    [`maxTemplateTimeoutDuration`], [5.5 s], [Wait for a fresh template after a tip change.],
    [`merkleRootPairSize`], [64 bytes], [Submission table key.],
    [`maxNonce`], [$2^32 - 1$], [CPU miner nonce range.],
    [`maxSimnetToMine`], [4], [Failed CPU-mined blocks per parent before stopping (simnet, regnet).],
    [`defaultNumWorkers`], [1], [Default CPU miner workers; maximum $2 times$ CPU cores.],
    table.cell(colspan: 3)[_Fee estimation (`internal/fees`, `server.go`)_],
    [`DefaultMaxConfirmations`], [32], [Confirmation ranges.],
    [`DefaultFeeRateStep`], [1.1], [Ratio between bucket bounds.],
    [`DefaultMaxBucketFeeMultiplier`], [100], [Finite bucket bounds stay below $100 r$.],
    [`ExtraBucketFee`], [100000 atoms/kB], [Additional tracked bound.],
    [`defaultDecay`], [0.998], [Per-block decay of confirmed statistics.],
    [success ratio], [0.95], [Required by `EstimateFee`.],
    [`maxAllowedBucketFees`, `maxAllowedConfirms`], [2000, 788], [Sanity limits on the estimator database.],
  ),
) <tab:policy-constants>
