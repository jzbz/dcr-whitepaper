#import "../template.typ": *

= Transactions <ch:transactions>

A transaction moves value. It consumes previously created, still unspent
transaction outputs and creates new ones. This chapter specifies every
consensus rule whose subject is a single transaction: what makes a
transaction well formed, how it is classified, when it may appear in a block,
which outputs it may spend, how its fee is determined, and how its scripts are
invoked. Rules whose subject is a whole block (sizes, sigop totals, header
commitments, the order of block connection) are specified in #chref("blocks")\;
the detailed structure of tickets, votes and revocations in #chref("staking")\;
of treasury transactions in #chref("treasury")\; and of the coinbase in
#chref("subsidy"). The serialization of transactions and their hashes is
given in #chref("encoding"), and the script engine in #chref("script").

== Overview <sec:transactions-overview>

Every transaction in a block passes through the stages listed in
@tab:transactions-stages. A block is invalid if any transaction in it fails
any stage. The stages are listed approximately in the order in which dcrd
applies them (dcrd checks expiry before the context stage, and runs the
input, sequence-lock and script stages first for the whole stake tree and
then for the whole regular tree); the order affects only which error is
reported, except where noted in
@sec:transactions-connect, because the state of the set of unspent outputs
changes as transactions are connected.

#figure(
  caption: [Stages of transaction validation within block validation],
  table(
    columns: (auto, 1fr, auto),
    table.header([Stage], [Content], [Section]),
    [Sanity], [Context-free structural checks: counts, size, amounts, duplicate inputs.], [@sec:transactions-sanity],
    [Context], [Checks that depend on agenda state but not on the set of unspent outputs: versions, input
      forms per type, stake opcodes in regular outputs, placement of each type in the correct tree.],
    [@sec:transactions-classes, @sec:transactions-context],
    [Expiry], [The block height must be below the transaction's expiry.], [@sec:transactions-expiry],
    [Finality], [The absolute lock time must have passed.], [@sec:transactions-locktime],
    [Inputs], [Each input must reference an available output; maturity, tag, value and fee rules;
      the transaction is then connected.], [@sec:transactions-inputs, @sec:transactions-connect],
    [Sequence locks], [Relative lock times must be satisfied.], [@sec:transactions-seqlocks],
    [Scripts], [Every input script is executed against the script of the output it spends.],
    [@sec:transactions-scripts],
  ),
) <tab:transactions-stages>

#note[
  A node deciding whether to accept an unconfirmed transaction into its memory
  pool applies these same rules from the point of view of a hypothetical next
  block, together with additional, stricter policy rules (standardness, fees,
  limits on versions and script forms) that are not consensus. Policy is
  described in #chref("policy").
]

=== Agendas affecting transaction rules <sec:transactions-agendas>

Several transaction rules changed through stakeholder votes. Each is
identified below by its agenda identifier. Throughout this chapter, "agenda
_X_ is active" always means that _X_ is active *for the block being validated*
(the block that contains the transaction), which dcrd determines from the
parent of that block as described in #chref("voting").

#figure(
  caption: [Agendas that change transaction-level rules],
  table(
    columns: (auto, auto, 1fr),
    table.header([Agenda id], [DCP], [Effect on transaction rules]),
    [`lnfeatures`], [#dcp(2), #dcp(3)], [Enables sequence locks; finality uses the parent's past median
      time instead of the header timestamp; enables `OP_CHECKSEQUENCEVERIFY` and `OP_SHA256` in
      scripts.],
    [`fixlnseqlocks`], [#dcp(4)], [Corrected the set of outputs visible to sequence-lock
      evaluation. No longer consulted by dcrd; see @sec:transactions-dcp4.],
    [`treasury`], [#dcp(6)], [Treasury transaction types; coinbase must be version 3; treasury
      opcodes; maturity of vote and revocation outputs raised to #param("CoinbaseMaturity")\;
      `OP_TGEN` maturity; `OP_TADD` outputs unspendable.],
    [`explicitverupgrades`], [#dcp(8)], [Transaction versions above 3 and regular-transaction output
      script versions above 0 are rejected.],
    [`autorevocations`], [#dcp(9)], [Revocations must be version 2; scripts of version 2 or later
      revocations are not executed.],
  ),
) <tab:transactions-agendas>

=== Constants <sec:transactions-constants>

#figure(
  caption: [Constants and parameters used in this chapter],
  table(
    columns: (auto, auto, 1fr),
    table.header([Name], [Value], [Meaning]),
    [#const("MaxAmount")], [2100000000000000], [Largest valid amount in atoms ($21 times 10^6 times 10^8$).],
    [#param("MaxTxSize")], [393216 (mainnet)], [Largest serialized transaction, in bytes. 1000000 on
      the other networks.],
    [#param("CoinbaseMaturity")], [256 (mainnet)], [Blocks before coinbase and related outputs may be
      spent. 16 on the other networks.],
    [#param("SStxChangeMaturity")], [1], [Blocks before ticket change outputs may be spent; 1 on
      every network.],
    [#param("TicketMaturity")], [256 (mainnet)], [Used by staking maturity rules; 16 on the other
      networks.],
    [#param("StakeBaseSigScript")], [`0x0000` (mainnet)], [Required signature script of a vote's
      stakebase input (two bytes). `0x7357` on regnet, `0x0000` on testnet3 and simnet.],
    [#const("MinCoinbaseScriptLen")], [2], [Minimum coinbase and stakebase signature script length.],
    [#const("MaxCoinbaseScriptLen")], [100], [Maximum coinbase and stakebase signature script length.],
    [#const("TSpendScriptLen")], [100], [Exact treasury spend signature script length.],
    [#const("LockTimeThreshold")], [500000000], [Lock times below this are heights, others are Unix
      times.],
    [#const("NoExpiryValue")], [0], [Expiry value meaning "never expires".],
    [#const("NullValueIn")], [$-1$], [Placeholder input amount allowed by the sanity rules.],
    [#const("NullBlockHeight")], [0], [Null input witness block height.],
    [#const("NullBlockIndex")], [#hex("ffffffff")], [Null input witness block index.],
    [#const("MaxScriptSize")], [16384], [Output scripts longer than this are never spendable.],
    [#const("MaxSigOpsPerBlock")], [5000], [Block signature-operation limit (#chref("blocks")).],
    [`TxVersionSeqLock`], [2], [Lowest transaction version subject to sequence locks.],
    [`TxVersionTreasury`], [3], [Version of treasury transactions and post-treasury coinbases.],
    [`TxVersionAutoRevocations`], [2], [Required revocation version under `autorevocations`.],
  ),
) <tab:transactions-constants>

== The UTXO Model <sec:transactions-utxo>

Decred, like Bitcoin @bitcoin, keeps no account balances. The ledger state is
the *UTXO set*: the set of transaction outputs that exist on the chain and
have not been consumed. A transaction input names one entry of the set by its
*outpoint* and consumes it; the transaction's outputs become new entries.
Validation of a transaction therefore needs, for each input, the entry it
references.

=== Outpoints and transaction trees <sec:transactions-outpoints>

A block carries two ordered lists of transactions, the *regular tree* and the
*stake tree* (#chref("encoding")). Stake transactions (tickets, votes,
revocations and the treasury types) live in the stake tree; all others,
including the coinbase, live in the regular tree. The tree is part of an
output's identity. An outpoint is the triple

$ ("hash", "index", "tree") $

where `hash` is the transaction hash of the creating transaction, `index` its
zero-based output index (`uint32`), and `tree` is 0 for the regular tree and 1
for the stake tree (`int8`). Two outpoints are equal only if all three fields
are equal.

#rule("Outpoint tree must match the creating transaction", src: (
  "internal/blockchain/utxoviewpoint.go · addTxOuts",
  "internal/blockchain/validate.go · CheckTransactionInputs",
))[
  The UTXO entry created by output $k$ of transaction $T$ is keyed by
  $("hash"(T), k, t)$, where $t = 1$ if $T$ is of any stake type
  (@sec:transactions-classes) and $t = 0$ otherwise. An input whose outpoint
  carries the other tree value references a nonexistent entry and the
  transaction #MUST be rejected under @rule:transactions-input-exists.
] <rule:transactions-tree-byte>

The *null outpoint* is the outpoint with the all-zero hash, index
#hex("ffffffff") and tree 0. It references nothing and is used as the
placeholder input of transactions that create value from nothing (coinbase,
vote stakebase, treasurybase, treasury spend).

=== Unspent output entries <sec:transactions-entries>

An entry records the information consensus later needs about the output and
its creating transaction (@tab:transactions-entry). These fields are fixed at
creation; only the spent/unspent state changes.

#figure(
  caption: [Content of a UTXO entry as used by consensus],
  table(
    columns: (auto, auto, 1fr),
    table.header([Field], [Type], [Meaning]),
    [amount], [`int64`], [Value of the output in atoms.],
    [script version], [`uint16`], [Version of the output script.],
    [script], [bytes], [The output script.],
    [height], [`uint32`], [Height of the block containing the creating transaction.],
    [index], [`uint32`], [Position of the creating transaction within its tree (regular-tree
      position for regular transactions, stake-tree position for stake transactions).],
    [coinbase flag], [bool], [The creating transaction is a coinbase (@alg:transactions-coinbase-form,
      evaluated with the `treasury` state of the creating block).],
    [expiry flag], [bool], [The creating transaction's expiry field is nonzero.],
    [transaction type], [enum], [`stake_type` of the creating transaction
      (@alg:transactions-classify; a coinbase is recorded as `REGULAR`), used by staking rules.],
    [ticket outputs], [list], [For output 0 of a ticket only: the amount, script version and script of
      every output of the ticket, needed later to validate the vote or revocation that spends it
      (#chref("staking")).],
  ),
) <tab:transactions-entry>

#rule("Outputs that never enter the UTXO set", src: (
  "internal/blockchain/utxoviewpoint.go · addTxOuts, connectStakeTransaction",
  "txscript/script.go · IsUnspendable",
))[
  When a transaction is connected, an entry is created for each of its outputs
  *except*:
  + any output whose amount is 0;
  + any output whose script is longer than #const("MaxScriptSize") (16384)
    bytes;
  + any output whose script is non-empty and begins with the byte `0x6a`
    (`OP_RETURN`);
  + any output whose script does not parse as a version 0 script
    (#chref("script")), regardless of the output's script version;
  + output 0 of a treasury add;
  + every output of the treasurybase (when `treasury` is active, the stake
    transaction at index 0 adds no entries at all).
  Such outputs can never be spent: an input referencing one #MUST be rejected
  under @rule:transactions-input-exists.
] <rule:transactions-unspendable>

An entry is *spent* once a connected transaction has consumed it; from then on
it is no longer part of the UTXO set and no later transaction may reference
it. Spending is undone only when the spending transaction is disconnected,
either by a chain reorganization or because the next block disapproves the
regular tree containing it (#chref("blocks")); disconnection restores the
entry with all of its original fields.

#note[
  Condition 4 cannot produce a difference for a valid block, because every
  output of a regular transaction must already tokenize as version 0
  (@rule:transactions-no-stake-opcodes) and every output of a stake
  transaction is a version 0 script of a fixed form. The genesis block is
  never connected to the UTXO set; its outputs are not spendable.
]

=== Input witness fields <sec:transactions-witness>

Each input carries, in the witness part of its serialization
(#chref("encoding")), three fields that duplicate information about the
referenced output: `ValueIn` (`int64`), `BlockHeight` (`uint32`) and
`BlockIndex` (`uint32`). They were designed to let lightweight clients prove
fraud and are called the *fraud proof*. Consensus constrains them as follows.

#figure(
  caption: [Constraints on input witness fields],
  table(
    columns: (auto, 1fr, 1fr),
    table.header([Input], [`ValueIn`], [`BlockHeight`, `BlockIndex`]),
    [Any input], [$-1$ or in $[0, #const("MaxAmount")]$ (@rule:transactions-sanity-valuein).], [—],
    [Input spending a UTXO entry], [Equal to the entry's amount (@rule:transactions-witness).],
      [Equal to the entry's height and index (@rule:transactions-witness).],
    [Coinbase input], [Equal to the block's coinbase subsidy (#chref("subsidy")).],
      [0 and #hex("ffffffff") (@rule:transactions-coinbase-input).],
    [Vote stakebase (input 0)], [Equal to the vote subsidy (#chref("staking")).],
      [0 and #hex("ffffffff") (part of the vote's structural definition, #chref("staking")).],
    [Treasurybase input], [Equal to the treasury subsidy (#chref("subsidy"), #chref("treasury")).],
      [0 and #hex("ffffffff") (@rule:transactions-treasurybase-input).],
    [Treasury spend input], [The amount withdrawn, matching the commitment in output 0
      (#chref("treasury")).], [0 and #hex("ffffffff") (@rule:transactions-tspend-input).],
  ),
) <tab:transactions-witness>

#rule("Witness fields of spending inputs", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  For every input that references a UTXO entry (every input except those
  listed in @rule:transactions-input-skip), the input's `ValueIn` #MUST equal
  the entry's amount, `int64(BlockHeight)` #MUST equal the entry's height, and
  `BlockIndex` #MUST equal the entry's index. These comparisons are exact.
] <rule:transactions-witness>

#pitfall[
  The witness fields are not covered by the transaction hash (#chref("encoding")),
  so two encodings of the same transaction with different witness values
  have the same hash, and only one of them is valid in a given chain context.
  For an output created earlier in the same block, `BlockHeight` is the height
  of the block itself and `BlockIndex` is the creating transaction's position in
  its own tree.
]

== Classification <sec:transactions-classes>

Many rules depend on what kind of transaction is being validated. Decred has
no explicit type field: the type is inferred from the structure of the
transaction. The structural predicates are defined elsewhere and are only
named here: `is_ticket`, `is_vote`, `is_revocation` in #chref("staking")\;
`is_treasury_add`, `is_treasury_spend`, `is_treasurybase` in #chref("treasury").
Each predicate is a pure function of the transaction alone. The coinbase
predicate is given below because it depends on the `treasury` agenda.

#algorithm("Coinbase form", src: "blockchain/standalone/tx.go · IsCoinBaseTx")[
  ```python
  ZERO_HASH = bytes(32)

  def is_coinbase_form(tx, treasury_active: bool) -> bool:
      if treasury_active and tx.version != 3:
          return False
      if len(tx.inputs) != 1:
          return False
      prev = tx.inputs[0].prev_out
      if prev.index != 0xffffffff or prev.hash != ZERO_HASH:
          return False                     # prev.tree is NOT examined here
      if treasury_active and is_tspend_like(tx):
          return False
      return True

  def is_tspend_like(tx) -> bool:          # only reached with exactly one input
      if len(tx.outputs) < 2:
          return False
      sig = tx.inputs[0].sig_script
      if len(sig) == 0 or len(tx.outputs[0].pk_script) == 0 \
              or len(tx.outputs[1].pk_script) == 0:
          return False
      return (sig[-1] == 0xc2                          # OP_TSPEND
              and tx.outputs[0].pk_script[0] == 0x6a   # OP_RETURN
              and tx.outputs[1].pk_script[0] == 0xc3)  # OP_TGEN
  ```
] <alg:transactions-coinbase-form>

#algorithm("Transaction type", src: (
  "blockchain/stake/staketx.go · DetermineTxType",
  "internal/blockchain/validate.go · checkTransactionContext",
))[
  ```python
  STAKE_TYPES = {TICKET, VOTE, REVOCATION, TREASURY_ADD, TREASURY_SPEND, TREASURYBASE}

  def stake_type(tx):                      # independent of every agenda
      if is_ticket(tx):      return TICKET
      if is_vote(tx):        return VOTE
      if is_revocation(tx):  return REVOCATION
      if tx.version >= 3:
          if is_treasury_add(tx):   return TREASURY_ADD
          if is_treasury_spend(tx): return TREASURY_SPEND
          if is_treasurybase(tx):   return TREASURYBASE
      return REGULAR

  def classify(tx, treasury_active):
      t = stake_type(tx)
      if t == REGULAR and is_coinbase_form(tx, treasury_active):
          return COINBASE
      return t
  ```
] <alg:transactions-classify>

The six stake predicates are mutually exclusive, so the order of the tests in
`stake_type` does not matter for well-formed input; it is given as dcrd
applies it. A transaction that almost, but not exactly, satisfies a stake
predicate is classified `REGULAR` and is then subject to the regular rules,
which normally reject it (for example a malformed vote has a null outpoint as
input 0 and fails @rule:transactions-nonnull-inputs).

#pitfall[
  `stake_type` does not consult the `treasury` agenda: a version 3
  transaction of treasury-add, treasury-spend or treasurybase form is
  classified as such even before the agenda is active. Before activation such
  a transaction is invalid in either tree (@rule:transactions-tree-placement).
  The coinbase predicate, in contrast, does depend on the agenda, and once
  `treasury` is active a treasurybase also satisfies `is_coinbase_form`; code
  that tests for a coinbase in the stake tree must test for the treasurybase
  first.
]

#figure(
  caption: [Transaction types, their trees and where their structure is specified],
  table(
    columns: (auto, auto, 1fr, auto),
    table.header([Type], [Tree], [Placement condition], [Structure]),
    [Coinbase], [regular], [Exactly one, at index 0.], [#chref("subsidy")],
    [Regular], [regular], [Any index other than 0.], [this chapter],
    [Ticket], [stake], [Any position (after the treasurybase when `treasury` is active).],
      [#chref("staking")],
    [Vote], [stake], [Only at or above #param("StakeValidationHeight").], [#chref("staking")],
    [Revocation], [stake], [Only at or above #param("StakeValidationHeight").], [#chref("staking")],
    [Treasurybase], [stake], [Exactly one, at stake index 0, when and only when `treasury` is
      active.], [#chref("treasury")],
    [Treasury add], [stake], [Only when `treasury` is active.], [#chref("treasury")],
    [Treasury spend], [stake], [Only when `treasury` is active, at or above
      #param("StakeValidationHeight"), on a treasury vote interval.], [#chref("treasury")],
  ),
) <tab:transactions-types>

#rule("Tree placement of transaction types", src: "internal/blockchain/validate.go · checkBlockContext")[
  + Every transaction in the regular tree #MUST have `stake_type` equal to
    `REGULAR` (`ErrStakeTxInRegularTree`).
  + Every transaction in the stake tree #MUST have `stake_type` different from
    `REGULAR` (`ErrRegTxInStakeTree`).
  + If `treasury` is not active, the stake tree #MUSTNOT contain transactions of
    type `TREASURY_ADD`, `TREASURY_SPEND` or `TREASURYBASE`. (dcrd enforces this by
    counting only the other three types when the agenda is inactive and
    requiring the counts to add up to the size of the stake tree,
    `ErrNonstandardStakeTx`.)
  The remaining placement conditions of @tab:transactions-types are block
  rules specified in #chref("blocks"), #chref("staking") and #chref("treasury").
] <rule:transactions-tree-placement>

== Context-Free Sanity Rules <sec:transactions-sanity>

These rules depend on nothing but the transaction and the network
parameters. dcrd applies them to every transaction of both trees when it first
receives a block, before any agenda state is known, and they are identical
for all heights.

#rule("Inputs and outputs present", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  A transaction #MUST have at least one input (`ErrNoTxInputs`) and at least
  one output (`ErrNoTxOutputs`).
] <rule:transactions-sanity-counts>

#rule("Maximum serialized size", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  The size in bytes of the serialization of the transaction, in the
  serialization type with which it was decoded, #MUSTNOT exceed
  #param("MaxTxSize"). For every transaction that can appear in a valid block
  this is the full serialization (prefix and witness, #chref("encoding")),
  because a transaction of any other serialization type is always rejected by
  other rules. #param("MaxTxSize") is
  393216 on mainnet and 1000000 on the other networks (`ErrTxTooBig`).
  The limit is inclusive: a transaction of exactly #param("MaxTxSize") bytes is
  valid.
] <rule:transactions-sanity-size>

#rule("Output amounts", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  For each output in order, its amount $v$ #MUST satisfy
  $0 <= v <= #const("MaxAmount")$, and the running total of the amounts of
  that output and all preceding outputs #MUST satisfy
  $0 <= "total" <= #const("MaxAmount")$ (`ErrBadTxOutValue`). A zero amount
  is valid (such an output is never spendable, @rule:transactions-unspendable).
] <rule:transactions-sanity-outputs>

#rule("Input witness amounts", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  For each input, `ValueIn` #MUST either equal #const("NullValueIn") ($-1$) or
  satisfy $0 <= "ValueIn" <= #const("MaxAmount")$ (`ErrFraudAmountIn`). No
  constraint is placed on the sum of the `ValueIn` fields here.
] <rule:transactions-sanity-valuein>

#rule("No duplicate inputs", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  No two inputs of a transaction may have equal outpoints, where equality
  compares hash, index and tree (`ErrDuplicateTxInputs`).
] <rule:transactions-sanity-dup>

#note[
  Because the tree is part of outpoint equality, two inputs that differ only in
  the tree byte pass @rule:transactions-sanity-dup; at most one of them can
  reference an existing entry, so the transaction still fails input
  validation. Null outpoints count for the purpose of the duplicate check.
]

#algorithm("Context-free sanity check", src: "blockchain/standalone/tx.go · CheckTransactionSanity")[
  ```python
  MAX_AMOUNT = 2_100_000_000_000_000

  def check_sanity(tx, max_tx_size):
      if len(tx.inputs) == 0:  reject("ErrNoTxInputs")
      if len(tx.outputs) == 0: reject("ErrNoTxOutputs")
      if full_serialize_size(tx) > max_tx_size: reject("ErrTxTooBig")
      total = 0
      for out in tx.outputs:
          if out.value < 0 or out.value > MAX_AMOUNT: reject("ErrBadTxOutValue")
          total = total + out.value      # cannot exceed 2*MAX_AMOUNT: no overflow
          if total > MAX_AMOUNT:          reject("ErrBadTxOutValue")
      for txin in tx.inputs:
          if (txin.value_in < 0 and txin.value_in != -1) or txin.value_in > MAX_AMOUNT:
              reject("ErrFraudAmountIn")
      seen = set()
      for txin in tx.inputs:
          key = (txin.prev_out.hash, txin.prev_out.index, txin.prev_out.tree)
          if key in seen: reject("ErrDuplicateTxInputs")
          seen.add(key)
  ```
] <alg:transactions-sanity>

#vector[Sanity checks (results from `standalone.CheckTransactionSanity`)][
  ```
  one output of 2100000000000000                      valid
  one output of 2100000000000001                      ErrBadTxOutValue
  outputs 2100000000000000 and 1                      ErrBadTxOutValue (total)
  one output of 0                                     valid
  one output of -1                                    ErrBadTxOutValue
  input ValueIn -2                                    ErrFraudAmountIn
  input ValueIn 2100000000000000                      valid
  input ValueIn 2100000000000001                      ErrFraudAmountIn
  inputs (h, 1, tree 0) and (h, 1, tree 1)            valid
  inputs (h, 1, tree 0) and (h, 1, tree 0)            ErrDuplicateTxInputs
  ```
]

== Contextual Structure Rules <sec:transactions-context>

The rules in this section depend on the transaction and on the agenda state
for the containing block, but not on the UTXO set. They apply to every
transaction of both trees. The type `t` used below is
`classify(tx, treasury_active)` (@alg:transactions-classify).

=== Versions <sec:transactions-versions>

The transaction version is a 16-bit field (#chref("encoding")). Script
versions are 16-bit fields of each output.

#rule("Maximum transaction version", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `explicitverupgrades` (#dcp(8)) is active, the transaction version #MUST
  be at most 3. Otherwise every version from 0 to 65535 is permitted by this
  rule (`ErrTxVersionTooHigh`). This applies to all types in both trees.
] <rule:transactions-max-version>

#rule("Maximum output script version of regular transactions", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `REGULAR` or `COINBASE` and `explicitverupgrades` is active, every
  output #MUST have script version 0 (`ErrScriptVersionTooHigh`). Without the
  agenda any script version is permitted by this rule. Stake transactions are
  exempt from this rule because their structural definitions already require
  version 0 for every output.
] <rule:transactions-max-script-version>

#rationale[
  #dcp(8) makes every future change to transaction or script semantics
  introduce a new version number, so that the version itself proves the
  enabling agenda is active and old software cannot be tricked into treating
  new-version outputs as anyone-can-spend. Before the agenda, output scripts
  with a nonzero version always succeed when executed (#chref("script")),
  provided the script engine can be created for the spend
  (@rule:transactions-script-failure); such
  outputs created before activation remain in the UTXO set and remain
  spendable afterwards, because @rule:transactions-max-script-version
  constrains only the outputs a transaction creates.
]

Version-specific semantics elsewhere: sequence locks apply to versions 2 and
above (@sec:transactions-seqlocks); the coinbase must be version 3 when
`treasury` is active (@alg:transactions-coinbase-form); revocations must be
version 2 under `autorevocations` (@rule:transactions-revocation-version);
treasury transactions are version 3 by definition (#chref("treasury")); votes
carrying treasury-spend votes are version 3 (#chref("staking")).

=== Regular transaction outputs <sec:transactions-regular-outputs>

#rule("No stake opcodes in regular outputs", src: (
  "internal/blockchain/validate.go · checkTransactionContext",
  "txscript/script.go · ContainsStakeOpCodes",
))[
  If `t` is `REGULAR` or `COINBASE`, every output script is tokenized as a
  version 0 script (#chref("script")), whatever its declared script version.
  + If tokenization fails (for example a data push extends past the end of the
    script), the transaction #MUST be rejected (`ErrScriptMalformed`).
  + No opcode of the script (data inside pushes is not an opcode) may be one of
    `OP_SSTX` (`0xba`), `OP_SSGEN` (`0xbb`), `OP_SSRTX` (`0xbc`),
    `OP_SSTXCHANGE` (`0xbd`); and, if `treasury` is active, also `OP_TADD`
    (`0xc1`), `OP_TSPEND` (`0xc2`), `OP_TGEN` (`0xc3`)
    (`ErrRegTxCreateStakeOut`).
  dcrd scans as it tokenizes, so a script with a forbidden opcode before a
  malformed push is reported with the second error kind; the transaction is
  rejected either way.
] <rule:transactions-no-stake-opcodes>

#pitfall[
  Output scripts with a nonzero script version are nonetheless tokenized with
  version 0 rules here. Before `explicitverupgrades`, a regular output with
  script version 1 whose bytes do not tokenize as version 0 makes the whole
  block invalid.
]

=== Input forms by type <sec:transactions-input-forms>

#rule("Coinbase input", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `COINBASE`:
  + its single input's outpoint #MUST be the null outpoint, including tree 0
    (`ErrBadCoinbaseOutpoint`; `is_coinbase_form` does not examine the tree);
  + the input's `BlockHeight` #MUST be 0 and `BlockIndex` #MUST be #hex("ffffffff")
    (`ErrBadCoinbaseFraudProof`);
  + the length $l$ of its signature script #MUST satisfy $2 <= l <= 100$
    (`ErrBadCoinbaseScriptLen`).
  The coinbase's `ValueIn`, outputs and height commitment are specified in
  #chref("subsidy").
] <rule:transactions-coinbase-input>

#rule("Vote stakebase and ticket input", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `VOTE`:
  + the length $l$ of the signature script of input 0 (the stakebase) #MUST
    satisfy $2 <= l <= 100$ (`ErrBadStakebaseScriptLen`);
  + the signature script of input 0 #MUST equal #param("StakeBaseSigScript")
    byte for byte (`ErrBadStakebaseScrVal`);
  + the outpoint of input 1 #MUSTNOT be the null outpoint (`ErrBadTxInput`).
] <rule:transactions-vote-input>

#rule("Revocation version and input", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `REVOCATION`:
  + if `autorevocations` (#dcp(9)) is active, the transaction version #MUST
    equal 2 (`ErrInvalidRevocationTxVersion`);
  + the outpoint of input 0 #MUSTNOT be the null outpoint (`ErrBadTxInput`).
] <rule:transactions-revocation-version>

#rule("Treasurybase input", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `TREASURYBASE`: input 0 #MUST have the null outpoint
  (`ErrBadTreasurybaseOutpoint`), `BlockHeight` 0 and `BlockIndex`
  #hex("ffffffff") (`ErrBadTreasurybaseFraudProof`), and an empty signature
  script (`ErrBadTreasurybaseScriptLen`). The first and third conditions are
  already implied by `is_treasurybase`.
] <rule:transactions-treasurybase-input>

#rule("Treasury spend input", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `TREASURY_SPEND`: input 0 #MUST have the null outpoint
  (`ErrBadTSpendOutpoint`), `BlockHeight` 0 and `BlockIndex` #hex("ffffffff")
  (`ErrBadTSpendFraudProof`), and a signature script of exactly 100 bytes
  (`ErrBadTSpendScriptLen`, already implied by `is_treasury_spend`). Note that
  `is_treasury_spend` itself does not require the null outpoint.
] <rule:transactions-tspend-input>

#rule("Treasury add change", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `TREASURY_ADD` and it has exactly two outputs, the amount of
  output 1 (the change) #MUSTNOT be 0 (`ErrInvalidTAddChange`). Treasury adds
  are additionally subject to @rule:transactions-nonnull-inputs.
] <rule:transactions-tadd-change>

#rule("Non-null inputs", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If `t` is `REGULAR`, `TICKET` or `TREASURY_ADD`, no input may have the null
  outpoint (`ErrBadTxInput`).
] <rule:transactions-nonnull-inputs>

#note[
  The coinbase, treasurybase and treasury spend each have exactly one input by
  their definitions, so the rules above constrain all of their inputs. A vote
  has exactly two inputs and a revocation exactly one (#chref("staking")).
]

#algorithm("Contextual structure check", src: "internal/blockchain/validate.go · checkTransactionContext")[
  ```python
  def check_context(tx, params, treasury, explicit_upgrades, auto_revocations):
      if explicit_upgrades and tx.version > 3: reject("ErrTxVersionTooHigh")
      t = classify(tx, treasury)
      i0 = tx.inputs[0]
      if t == VOTE:
          if not 2 <= len(i0.sig_script) <= 100: reject("ErrBadStakebaseScriptLen")
          if i0.sig_script != params.stake_base_sig_script:
              reject("ErrBadStakebaseScrVal")
          if is_null_outpoint(tx.inputs[1].prev_out):  reject("ErrBadTxInput")
      elif t == REVOCATION:
          if auto_revocations and tx.version != 2: reject("ErrInvalidRevocationTxVersion")
          if is_null_outpoint(i0.prev_out): reject("ErrBadTxInput")
      elif t == COINBASE:
          if not is_null_outpoint(i0.prev_out): reject("ErrBadCoinbaseOutpoint")
          if not is_null_witness(i0):           reject("ErrBadCoinbaseFraudProof")
          if not 2 <= len(i0.sig_script) <= 100: reject("ErrBadCoinbaseScriptLen")
      elif t == TREASURYBASE:
          if not is_null_outpoint(i0.prev_out): reject("ErrBadTreasurybaseOutpoint")
          if not is_null_witness(i0):           reject("ErrBadTreasurybaseFraudProof")
          if len(i0.sig_script) != 0:           reject("ErrBadTreasurybaseScriptLen")
      elif t == TREASURY_SPEND:
          if not is_null_outpoint(i0.prev_out): reject("ErrBadTSpendOutpoint")
          if not is_null_witness(i0):           reject("ErrBadTSpendFraudProof")
          if len(i0.sig_script) != 100:         reject("ErrBadTSpendScriptLen")
      else:                                     # REGULAR, TICKET, TREASURY_ADD
          if t == TREASURY_ADD and len(tx.outputs) == 2 and tx.outputs[1].value == 0:
              reject("ErrInvalidTAddChange")
          for txin in tx.inputs:
              if is_null_outpoint(txin.prev_out): reject("ErrBadTxInput")
      if t in (REGULAR, COINBASE):
          for out in tx.outputs:
              if explicit_upgrades and out.version > 0: reject("ErrScriptVersionTooHigh")
              ops = tokenize_v0(out.pk_script)  # reject("ErrScriptMalformed") on failure
              if any(is_stake_opcode(op, treasury) for op in ops):
                  reject("ErrRegTxCreateStakeOut")

  def is_null_outpoint(op):
      return op.hash == ZERO_HASH and op.index == 0xffffffff and op.tree == 0

  def is_null_witness(txin):          # ValueIn is not part of this test
      return txin.block_height == 0 and txin.block_index == 0xffffffff
  ```
] <alg:transactions-context>

== Expiry <sec:transactions-expiry>

A transaction may name a height from which it can no longer be mined. This
lets a transaction that fails to confirm in time become permanently invalid
instead of lingering. The `Expiry` field (`uint32`) of value 0 means no
expiry.

#rule("Expired transactions", src: (
  "internal/blockchain/validate.go · IsExpiredTx",
  "internal/blockchain/validate.go · checkBlockDataPositional",
))[
  Let $h$ be the height of the block containing the transaction and $E$ its
  `Expiry`. If $E != 0$ and $h >= E$, the transaction is expired and the block
  #MUST be rejected (`ErrExpiredTx`). Equivalently, a transaction with
  $E != 0$ is valid only in blocks of height at most $E - 1$. This applies to
  every transaction in both trees, the coinbase included.
] <rule:transactions-expiry>

Expiry has one further consensus effect: outputs of a transaction with a
nonzero expiry require #param("CoinbaseMaturity") confirmations before they
can be spent (@rule:transactions-expiry-maturity). Treasury spends have
additional expiry requirements tied to the treasury voting windows, specified
in #chref("treasury").

#vector[Expiry (results from `IsExpiredTx`)][
  ```
  Expiry 0,    height 1000000   not expired
  Expiry 1000, height 999       not expired
  Expiry 1000, height 1000      expired
  Expiry 1000, height 1001      expired
  ```
]

== Lock Time Finality <sec:transactions-locktime>

The `LockTime` field (`uint32`) sets the earliest point at which a
transaction may be mined, either as a block height or as a Unix time. A
transaction that may be mined is *final*. As in Bitcoin, setting every
input's sequence number to its maximum value #hex("ffffffff") disables the
lock time.

#rule("Lock time finality", src: (
  "internal/blockchain/validate.go · IsFinalizedTransaction",
  "internal/blockchain/validate.go · checkBlockContext",
))[
  Every transaction in both trees of a block at height $h$ #MUST be final,
  otherwise the block is invalid (`ErrUnfinalizedTx`). Let $L$ be the
  transaction's `LockTime`. The transaction is final if and only if at least
  one of the following holds:
  + $L = 0$;
  + $L < 500000000$ (#const("LockTimeThreshold")) and $L < h$;
  + $L >= 500000000$ and $L < tau$, where $tau$ is the *lock-time reference
    time* defined below;
  + every input has sequence number #hex("ffffffff").
  All comparisons are strict as written. The reference time $tau$ is:
  - if `lnfeatures` is *not* active: the timestamp field of the header of the
    block being validated;
  - if `lnfeatures` is active: the past median time of the *parent* of the
    block being validated (the median of the timestamps of the 11 blocks
    ending with the parent, or of all blocks back to the genesis block if
    there are fewer, as defined in #chref("blocks")).
] <rule:transactions-finality>

#history[
  #dcp(3) changed the reference time from the block's own timestamp to the
  parent's past median time, because the median time never decreases
  while miner-chosen timestamps need not. On mainnet `lnfeatures` became active
  at block 189568.
]

#pitfall[
  An input sequence number of #hex("fffffffe") disables relative locks for that
  input (its bit 31 is set, @sec:transactions-seqlocks) but does *not* count
  toward condition 4. Condition 4 is evaluated on all inputs, including the
  null inputs of a coinbase or stakebase.
]

#vector[Finality (results from `IsFinalizedTransaction`; $h$ = block height, $tau$ = reference time)][
  ```
  LockTime    sequences             h          tau          final
  0           00000000              100        1600000000   yes
  99          00000000              100        1600000000   yes
  100         00000000              100        1600000000   no
  101         00000000              100        1600000000   no
  100         ffffffff              100        1600000000   yes
  100         ffffffff fffffffe     100        1600000000   no
  499999999   00000000              499999999  1600000000   no
  499999999   00000000              500000000  1            yes
  500000000   00000000              999999999  500000000    no
  500000000   00000000              1          500000001    yes
  1600000000  00000000              1          1599999999   no
  1600000000  00000000              1          1600000000   no
  1600000000  00000000              1          1600000001   yes
  ```
]

== Relative Lock Times (Sequence Locks) <sec:transactions-seqlocks>

#dcp(3) repurposes the 32-bit sequence number of each input to express a
*relative* lock: a minimum age of the spent output, measured in blocks or in
units of 512 seconds from the block that created the output. The script
opcode `OP_CHECKSEQUENCEVERIFY` lets an output script require such a lock
(#chref("script")); the consensus rule in this section enforces it.

=== Encoding <sec:transactions-seq-encoding>

#figure(
  caption: [Interpretation of an input sequence number under sequence locks],
  table(
    columns: (auto, auto, 1fr),
    table.header([Bits], [Mask], [Meaning]),
    [31], [#hex("80000000")], [Disable flag (`SequenceLockTimeDisabled`). If set, the input has no relative
      lock.],
    [30–23], [—], [Ignored.],
    [22], [#hex("00400000")], [Type flag (`SequenceLockTimeIsSeconds`). Set: the value counts units of
      $2^9 = 512$ seconds. Clear: the value counts blocks.],
    [21–16], [—], [Ignored.],
    [15–0], [#hex("0000ffff")], [Value $v$ (`SequenceLockTimeMask`), $0 <= v <= 65535$.],
  ),
) <tab:transactions-seq-bits>

The maximum relative lock is therefore 65535 blocks or
$65535 times 512 = 33553920$ seconds.

#pitfall[
  The text of #dcp(3) states the type flag the other way round ("when set ...
  blocks"). The reference implementation, and therefore consensus, treats a
  *set* bit 22 as time-based, as in @tab:transactions-seq-bits; the DCP's own
  reference code agrees with this table.
]

=== Applicability <sec:transactions-seq-applicability>

#rule("Transactions subject to sequence locks", src: (
  "internal/blockchain/sequencelock.go · calcSequenceLock",
  "internal/blockchain/validate.go · checkConnectBlock",
))[
  Sequence locks are enforced only when `lnfeatures` is active. When it is,
  a transaction is subject to them if and only if all of the following hold:
  + its version is at least 2 (any value from 2 to 65535);
  + it is not of coinbase form, `is_coinbase_form(tx, treasury_active)`
    (this excludes the coinbase and, when `treasury` is active, the
    treasurybase);
  + it is not a vote.
  This includes regular transactions other than the coinbase, tickets,
  revocations, treasury adds and treasury spends.
  Within a subject transaction, an input participates if and only if bit 31 of
  its sequence number is clear.
] <rule:transactions-seq-applicability>

#rule("Treasury spend sequence number", src: "internal/blockchain/sequencelock.go · calcSequenceLock")[
  When `lnfeatures` and `treasury` are both active, the input of a treasury
  spend #MUST have bit 31 of its sequence number set. If it is clear, the
  sequence-lock calculation looks up the null outpoint, which never exists,
  and the block is rejected (`ErrMissingTxOut`).
] <rule:transactions-tspend-sequence>

=== Calculation and enforcement <sec:transactions-seq-calc>

For each participating input, the lock is computed from the UTXO entry it
spends: its height $h_o$ and, for time locks, the past median time of the
block *preceding* the one that contains the output. Each transaction gets one
pair $("MinHeight", "MinTime")$, the maxima over its inputs, with $-1$ meaning
"no constraint".

#algorithm("Sequence lock of a transaction", src: "internal/blockchain/sequencelock.go · calcSequenceLock")[
  ```python
  def sequence_lock(tx, block, view, treasury_active):
      # block: the block being validated (height block.height).
      min_height, min_time = -1, -1                     # int64
      if tx.version < 2 or is_coinbase_form(tx, treasury_active) or is_vote(tx):
          return (min_height, min_time)
      for txin in tx.inputs:
          seq = txin.sequence                           # uint32
          if seq & 0x80000000:
              continue
          entry = view.lookup_including_spent(txin.prev_out)
          if entry is None:
              reject("ErrMissingTxOut")
          h_o = entry.height
          value = seq & 0x0000ffff
          if seq & 0x00400000:                          # time based
              prev_h = max(h_o - 1, 0)
              mtp = past_median_time(ancestor(block, prev_h))   # blocks chapter
              t = mtp + (value << 9) - 1
              min_time = max(min_time, t)
          else:                                         # height based
              min_height = max(min_height, h_o + value - 1)
      return (min_height, min_time)
  ```
] <alg:transactions-seqlock>

`lookup_including_spent` returns the entry whether or not it has been marked
spent: the calculation runs after the transaction's tree has been connected
(@sec:transactions-connect), so the entries it reads have already been spent
by the transaction itself. `ancestor(block, n)` is the block at height $n$ on
the chain ending with `block`; for $n$ equal to the parent's height it is the
parent.

#rule("Sequence lock enforcement", src: (
  "internal/blockchain/validate.go · SequenceLockActive",
  "internal/blockchain/validate.go · checkConnectBlock",
))[
  When `lnfeatures` is active, let $h$ be the height of the block being
  validated and $m$ the past median time of its parent. For every transaction
  subject to sequence locks in either tree, with lock
  $("MinHeight", "MinTime")$ from @alg:transactions-seqlock, the block #MUST be
  rejected (`ErrUnfinalizedTx`) if $h <= "MinHeight"$ or $m <= "MinTime"$.
  Equivalently, each block-based input requires $h >= h_o + v$ and each
  time-based input requires $m >= "mtp"_o + 512 v$.
] <rule:transactions-seq-enforce>

#note[
  A relative lock of $v = 0$ is always satisfied. A regular transaction
  spending an output created earlier in the same block ($h_o = h$) can carry
  only $v = 0$ locks: a block lock of 1 gives $"MinHeight" = h$, and a time lock
  of $v >= 1$ gives $"MinTime" >= m$ because the preceding block is the parent.
  The value `0x7fffffff` that dcrd's sequence-lock code treats as an
  "unconfirmed" height is used only by mempool policy and never occurs in
  block validation.
]

#vector[Sequence locks (from `calcSequenceLock` and `SequenceLockActive`)][
  Chain of regnet blocks with timestamps $1600000000 + 512 h$ for $h >= 1$.
  Past median times: block 19 $arrow.r$ 1600007168, block 24 (the parent)
  $arrow.r$ 1600009728. Output A is created at height 20 and output B at
  height 25; the transaction is validated in the block at height 25.
  ```
  version  inputs (sequence)                 MinHeight  MinTime     satisfied
  1        A:00000005                        -1         -1          yes
  2        A:80000005                        -1         -1          yes
  2        A:00000000                        19         -1          yes
  2        A:00000005                        24         -1          yes
  2        A:00000006                        25         -1          no
  2        A:7f3f0005 (reserved bits set)    24         -1          yes
  2        A:00400005                        -1         1600009727  yes
  2        A:00400006                        -1         1600010239  no
  2        A:00400000                        -1         1600007167  yes
  2        B:00000000                        24         -1          yes
  2        B:00000001                        25         -1          no
  2        A:00400005 B:00000000 A:80000000  24         1600009727  yes
  65535    A:00000005                        24         -1          yes
  ```
  For the time locks: $1600007168 + 5 times 512 - 1 = 1600009727 < 1600009728$,
  so the lock with $v = 5$ is satisfied, and the lock with $v = 6$
  ($"MinTime" = 1600010239$) is not.
]

=== The DCP-0004 correction <sec:transactions-dcp4>

#history[
  From the activation of `lnfeatures` (mainnet block 189568) dcrd in effect
  evaluated sequence locks of regular-tree transactions against a restricted
  view of the outputs, a by-product of the transaction-indexed UTXO storage
  of the time (from January 2019 reproduced by an explicitly constructed
  "legacy" view). That view contained only: outputs of transactions of
  the parent block's regular tree and outputs of transactions referenced by
  that tree's inputs (both only if the block approved its parent), and outputs
  of transactions referenced by, or contained in, the current block's stake
  tree, together with whatever the node's working view happened to contain.
  As a result, a version 2 transaction with an enabled relative lock was
  rejected (with `ErrMissingTxOut`) when it spent an output of an earlier
  transaction in the same block, an output from a block before the parent
  whose transaction was not otherwise referenced, or an output of a
  transaction shared with a disapproved parent.

  #dcp(4) @dcp0004 (agenda `fixlnseqlocks`, mainnet activation at block 342784) replaced
  this with the rule of this section: the view is exactly the set of outputs
  that exist from the point of view of the block being validated. The
  legacy behaviour also depended on the node's prior history (for example on
  the contents of the working view after a reorganization) and so cannot be
  specified as a pure function of the chain.

  dcrd no longer implements the legacy view: at the commit this document
  describes, @rule:transactions-seq-enforce with @alg:transactions-seqlock
  applies to every block for which `lnfeatures` is active, and `fixlnseqlocks`
  is not consulted. Because the corrected rule is strictly less restrictive,
  every block of the historical chains also satisfies it, as #dcp(4)
  anticipates ("new implementations will not require any additional code").
  An implementation that follows this document therefore matches the
  reference implementation exactly.
]

== Input Validation <sec:transactions-inputs>

Input validation checks every input of a transaction against the UTXO set
that exists when the transaction is connected (@sec:transactions-connect),
enforces maturity and tag restrictions on what is spent, sums the input
amounts and computes the fee. Several transaction types have additional input
rules specified in other chapters; @tab:transactions-delegated says where each
one plugs in.

=== Inputs without a referenced output <sec:transactions-input-skip>

#rule("Inputs exempt from UTXO lookup", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  The following inputs do not reference a UTXO entry and are exempt from
  @rule:transactions-input-exists through @rule:transactions-input-amount:
  + the input of the coinbase (the coinbase is exempt from input validation
    altogether, and its fee is 0 by definition);
  + input 0 (the stakebase) of a vote;
  + the input of the treasurybase, when `treasury` is active;
  + the input of a treasury spend, when `treasury` is active.
  For items 2 to 4 the input's `ValueIn` is added to the input total
  (@rule:transactions-input-sum). Its correctness is a rule of the chapter that
  owns the type (@tab:transactions-delegated).
] <rule:transactions-input-skip>

=== Per-input rules <sec:transactions-input-rules>

In the following rules, $h$ is the height of the block containing the
transaction, $e$ the UTXO entry referenced by the input, and
$"age" = h - e."height"$. A script is *tagged with* opcode $o$ when its script
version is 0, its first byte is $o$, and the remaining bytes are exactly a
pay-to-pubkey-hash script (25 bytes:
`OP_DUP OP_HASH160 OP_DATA_20` `<20 bytes>` `OP_EQUALVERIFY OP_CHECKSIG`) or
a pay-to-script-hash script (23 bytes:
`OP_HASH160 OP_DATA_20` `<20 bytes>` `OP_EQUAL`).

#rule("Referenced output exists and is unspent", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  The outpoint of each input #MUST identify an entry of the UTXO set that is
  unspent at the moment the transaction is connected (`ErrMissingTxOut`). The
  set is that of @sec:transactions-connect: it reflects every transaction
  connected before this one, including earlier transactions of the same
  block.
] <rule:transactions-input-exists>

#rule("Stake transactions do not spend same-block outputs", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If the transaction is of any stake type and $e."height" = h$, the
  transaction #MUST be rejected (`ErrMissingTxOut`), unless the input is one of
  the historical exceptions of @tab:transactions-sbss.
] <rule:transactions-no-same-block-stake>

#rule("Zero-value outputs are not spendable", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If $e."amount" = 0$ the transaction #MUST be rejected
  (`ErrZeroValueOutputSpend`). (Such entries cannot exist by
  @rule:transactions-unspendable; the check is defensive.)
] <rule:transactions-zero-value>

The witness rule @rule:transactions-witness applies at this point.

#rule("Coinbase maturity", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If $e$ has the coinbase flag, $"age"$ #MUST be at least
  #param("CoinbaseMaturity") (256 on mainnet) (`ErrImmatureSpend`). An output
  of the coinbase in block $b$ is thus first spendable in block
  $b + #param("CoinbaseMaturity")$.
] <rule:transactions-coinbase-maturity>

#rule("Maturity of outputs of expiring transactions", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If $e$ has the expiry flag (its creating transaction had a nonzero
  `Expiry`), $"age"$ #MUST be at least #param("CoinbaseMaturity")
  (`ErrExpiryTxSpentEarly`).
] <rule:transactions-expiry-maturity>

#rationale[
  A transaction with an expiry can become invalid if a reorganization moves it
  past its expiry height. Requiring the same maturity as the coinbase limits
  the damage to descendants of such a transaction, just as coinbase maturity
  does for coinbases invalidated by reorganizations.
]

#rule("Treasury generation output maturity", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If `treasury` is active and $e$'s script is tagged with `OP_TGEN` (`0xc3`),
  $"age"$ #MUST be at least #param("CoinbaseMaturity") (`ErrImmatureSpend`).
] <rule:transactions-tgen-maturity>

#rule("Ticket outputs are spent only by votes and revocations", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If $e$'s script is tagged with `OP_SSTX` (`0xba`), the spending transaction
  #MUST be a vote or a revocation (`ErrTxSStxOutSpend`).
] <rule:transactions-sstx-spend>

#rule("Treasury add outputs are unspendable", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If `treasury` is active, $e$'s script version is 0 and its script is the
  single byte `0xc1` (`OP_TADD`), the transaction #MUST be rejected
  (`ErrBadTxInput`).
] <rule:transactions-tadd-spend>

#note[
  Treasury add and treasurybase `OP_TADD` outputs never enter the UTXO set
  (@rule:transactions-unspendable). @rule:transactions-tadd-spend matters for
  regular outputs consisting of the single byte `0xc1` created before
  `treasury` activated, when `0xc1` was not a stake opcode: they become
  permanently unspendable on activation.
]

#rule("Vote and revocation output maturity", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If $e$'s script is tagged with `OP_SSGEN` (`0xbb`) or `OP_SSRTX` (`0xbc`),
  $"age"$ #MUST be at least $M$ (`ErrImmatureSpend`), where
  $M = #param("CoinbaseMaturity")$ if `treasury` is active and
  $M = #param("SStxChangeMaturity")$ (1 on every network) otherwise.
] <rule:transactions-stakeout-maturity>

#history[
  Before the `treasury` agenda (#dcp(6)), outputs of votes and revocations
  required only #param("SStxChangeMaturity") (1) confirmation, although
  dcrd's comments have long described them as subject to coinbase maturity.
  The agenda raised the requirement to #param("CoinbaseMaturity"). Both forms
  are normative; the selection is by the agenda state of the block containing
  the *spending* transaction.
]

#rule("Stake change maturity", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If $e$'s script is tagged with `OP_SSTXCHANGE` (`0xbd`), $"age"$ #MUST be at
  least #param("SStxChangeMaturity") (`ErrImmatureSpend`). This covers ticket
  change outputs and treasury add change outputs.
] <rule:transactions-change-maturity>

#rule("Referenced amount range", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  $e."amount"$ #MUST satisfy $0 <= e."amount" <= #const("MaxAmount")$
  (`ErrBadTxOutValue`). (This cannot fail for entries created under
  @rule:transactions-sanity-outputs.)
] <rule:transactions-input-amount>

All maturity rules are independent: an input may be subject to several (for
example a ticket change output of a ticket with a nonzero expiry needs both
1 and #param("CoinbaseMaturity") confirmations). Every maturity comparison is
"$"age" >= M$", with $"age"$ computed from the height of the block containing
the spending transaction.

#figure(
  caption: [All maturity requirements on spent outputs],
  table(
    columns: (1fr, auto, auto),
    table.header([Spent output], [Required age], [Rule]),
    [Coinbase output], [#param("CoinbaseMaturity")], [@rule:transactions-coinbase-maturity],
    [Any output of a transaction with nonzero expiry], [#param("CoinbaseMaturity")],
      [@rule:transactions-expiry-maturity],
    [`OP_TGEN`-tagged (treasury spend payouts), `treasury` active], [#param("CoinbaseMaturity")],
      [@rule:transactions-tgen-maturity],
    [`OP_SSGEN`/`OP_SSRTX`-tagged, `treasury` active], [#param("CoinbaseMaturity")],
      [@rule:transactions-stakeout-maturity],
    [`OP_SSGEN`/`OP_SSRTX`-tagged, `treasury` inactive], [#param("SStxChangeMaturity")],
      [@rule:transactions-stakeout-maturity],
    [`OP_SSTXCHANGE`-tagged], [#param("SStxChangeMaturity")], [@rule:transactions-change-maturity],
    [Ticket output 0 spent by a vote], [#param("TicketMaturity") $+ 1$], [#chref("staking")],
    [Ticket output 0 spent by a revocation], [#param("TicketMaturity") $+ 2$, or $+ 1$ with
      `autorevocations`], [#chref("staking")],
    [Treasury balance], [#param("CoinbaseMaturity")], [#chref("treasury")],
  ),
) <tab:transactions-maturity>

=== Spending across trees <sec:transactions-cross-tree>

Taken together, the rules above and the structural rules of the stake
transactions determine which outputs each kind of transaction may spend
(@tab:transactions-cross-tree). Apart from the restrictions listed, an output
of either tree may be spent by a transaction of either tree.

#figure(
  caption: [Which spenders may consume which kinds of outputs (outside the same block)],
  table(
    columns: (auto, 1fr, auto),
    table.header([Output kind], [Who may spend it], [Rules]),
    [`OP_SSTX`-tagged (ticket output 0)], [Only a vote (as its input 1) or a revocation (as its input
      0).], [@rule:transactions-sstx-spend, #chref("staking")],
    [`OP_SSTXCHANGE`-tagged (ticket and treasury add change)], [Any transaction after
      #param("SStxChangeMaturity").], [@rule:transactions-change-maturity],
    [`OP_SSGEN`/`OP_SSRTX`-tagged (vote and revocation payouts)], [Any transaction after the maturity
      of @rule:transactions-stakeout-maturity.], [@rule:transactions-stakeout-maturity],
    [`OP_TGEN`-tagged (treasury spend payouts)], [Any transaction after
      #param("CoinbaseMaturity").], [@rule:transactions-tgen-maturity],
    [Single-byte `OP_TADD` script], [Nobody, once `treasury` is active.],
      [@rule:transactions-unspendable, @rule:transactions-tadd-spend],
    [Coinbase outputs], [Any transaction after #param("CoinbaseMaturity").],
      [@rule:transactions-coinbase-maturity],
    [Other outputs], [Any transaction, subject to the input rules of the spender's type.], [—],
  ),
) <tab:transactions-cross-tree>

Votes and revocations have no inputs other than the ticket (and, for votes,
the stakebase); treasury spends and treasurybases have no real inputs.
Tickets and treasury adds are therefore the only stake transactions that
spend ordinary outputs. Tickets are further limited to version 0 outputs that
are plain P2PKH or P2SH, or P2PKH or P2SH tagged with `OP_SSGEN`, `OP_SSRTX` or
`OP_SSTXCHANGE` (so a ticket cannot spend an `OP_TGEN` output directly;
#chref("staking")). Treasury adds may spend any output permitted by the rules
of this chapter.

=== Value and fee <sec:transactions-fee>

#rule("Input total", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  The input total is accumulated in a signed 64-bit integer, in input order,
  from the `ValueIn` of each input of @rule:transactions-input-skip items 2–4
  and the entry amount $e."amount"$ of each other input. After each addition
  the accumulation #MUSTNOT have overflowed (signed overflow) and the running
  total #MUSTNOT exceed #const("MaxAmount") (`ErrBadTxOutValue` in both
  cases).
] <rule:transactions-input-sum>

#rule("Outputs do not exceed inputs; fee", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  Let $I$ be the input total and $O$ the sum of the output amounts (bounded by
  @rule:transactions-sanity-outputs). The transaction #MUST satisfy $I >= O$
  (`ErrSpendTooHigh`). Its *fee* is $I - O$. There is no minimum fee in
  consensus. The coinbase's fee is defined as 0. The block-level use of fees
  (the coinbase may claim them) is specified in #chref("subsidy").
] <rule:transactions-fee>

=== Delegated input rules <sec:transactions-delegated>

#figure(
  caption: [Type-specific input rules specified in other chapters, in the order dcrd applies them
    before the per-input rules],
  table(
    columns: (auto, 1fr, auto),
    table.header([Type], [Rules], [Chapter]),
    [Coinbase], [`ValueIn` equals the subsidy; output total bounded by subsidy plus fees; block-one
      ledger.], [#chref("subsidy")],
    [Ticket], [Every input spends an existing unspent version 0 P2PKH or P2SH output (plain, or
      tagged with `OP_SSGEN`, `OP_SSRTX` or `OP_SSTXCHANGE`); each commitment amount plus change
      equals its input amount
      (`checkTicketPurchaseInputs`). Ticket price versus header: #chref("blocks").],
      [#chref("staking")],
    [Vote], [Stakebase `ValueIn` equals the vote subsidy; input 1 spends output 0 of an unspent,
      mature ticket; payouts match the ticket's commitments (`checkVoteInputs`); the ticket is a
      winner (block rule).], [#chref("staking")],
    [Revocation], [Input 0 spends output 0 of an unspent, mature ticket eligible for revocation;
      payouts match the commitments (`checkRevocationInputs`).], [#chref("staking")],
    [Treasury spend], [Public key is a sanctioned Pi key (`ErrUnknownPiKey`); signature valid
      (`ErrInvalidPiSignature`); `ValueIn` in range and equal to the output 0 commitment
      (`checkTreasurySpendInputs`); voting, window and expenditure checks.], [#chref("treasury")],
    [Treasurybase], [`ValueIn` equals the treasury subsidy; output structure.],
      [#chref("treasury"), #chref("subsidy")],
  ),
) <tab:transactions-delegated>

=== Algorithm <sec:transactions-input-alg>

#algorithm("Input validation and fee", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  ```python
  COINBASE_MATURITY = params.coinbase_maturity
  SSTX_CHANGE_MATURITY = params.sstx_change_maturity

  def check_inputs(tx, h, view, treasury, auto_revocations, params) -> int:
      t = classify(tx, treasury)          # treasurybase tested before coinbase form
      if t == COINBASE:
          return 0                        # see subsidy chapter
      if t == TICKET:         staking.check_ticket_purchase_inputs(tx, view)
      if t == VOTE:           staking.check_vote_inputs(tx, h, view, ...)
      if t == REVOCATION:     staking.check_revocation_inputs(tx, h, view, ...)
      if t == TREASURY_SPEND: treasury.check_tspend_key_signature_and_value(tx)
      stake_out_maturity = COINBASE_MATURITY if treasury else SSTX_CHANGE_MATURITY
      total_in = 0                                      # int64
      for idx, txin in enumerate(tx.inputs):
          if idx == 0 and t in (VOTE, TREASURYBASE, TREASURY_SPEND):
              total_in = add_amount(total_in, txin.value_in)
              continue
          e = view.lookup(txin.prev_out)
          if e is None or e.spent:           reject("ErrMissingTxOut")
          if t in STAKE_TYPES and e.height == h \
                  and not is_sbss_exception(params.net, h, txin.prev_out.hash):
              reject("ErrMissingTxOut")
          if e.amount == 0:                  reject("ErrZeroValueOutputSpend")
          if txin.value_in != e.amount:      reject("ErrFraudAmountIn")
          if txin.block_height != e.height:  reject("ErrFraudBlockHeight")
          if txin.block_index != e.index:    reject("ErrFraudBlockIndex")
          age = h - e.height
          if e.is_coinbase and age < COINBASE_MATURITY: reject("ErrImmatureSpend")
          if e.has_expiry and age < COINBASE_MATURITY:  reject("ErrExpiryTxSpentEarly")
          if treasury and tagged(e, 0xc3) and age < COINBASE_MATURITY:
              reject("ErrImmatureSpend")
          if t not in (VOTE, REVOCATION) and tagged(e, 0xba):
              reject("ErrTxSStxOutSpend")
          if treasury and e.script_version == 0 and e.pk_script == b"\xc1":
              reject("ErrBadTxInput")
          if (tagged(e, 0xbb) or tagged(e, 0xbc)) and age < stake_out_maturity:
              reject("ErrImmatureSpend")
          if tagged(e, 0xbd) and age < SSTX_CHANGE_MATURITY:
              reject("ErrImmatureSpend")
          if e.amount < 0 or e.amount > MAX_AMOUNT:
              reject("ErrBadTxOutValue")
          total_in = add_amount(total_in, e.amount)
      total_out = sum(out.value for out in tx.outputs)
      if total_in < total_out:
          reject("ErrSpendTooHigh")
      return total_in - total_out

  def add_amount(total: int64, amount: int64) -> int64:
      s = int64(total + amount)                         # two's complement wrap
      if (s > total) != (amount > 0):  reject("ErrBadTxOutValue")   # overflow
      if s > MAX_AMOUNT:               reject("ErrBadTxOutValue")
      return s

  def tagged(e, opcode) -> bool:
      s = e.pk_script
      return (e.script_version == 0 and len(s) >= 1 and s[0] == opcode
              and (is_p2pkh(s[1:]) or is_p2sh(s[1:])))
  ```
] <alg:transactions-inputs>

== Connecting Transactions and In-Block Spending <sec:transactions-connect>

After a transaction passes input validation it is *connected*: the entries it
spends are marked spent and entries for its outputs are created
(@rule:transactions-unspendable). The UTXO set against which a transaction is
validated is the set as it stands at that moment, so the order of connection
determines which outputs are available. The block-level orchestration is
specified in #chref("blocks")\; the consequences for a single transaction are
stated here.

#rule("Connection order and output availability", src: (
  "internal/blockchain/validate.go · checkConnectBlock, checkTransactionsAndConnect",
  "internal/blockchain/utxoviewpoint.go · connectBlock",
))[
  For a block $B$ at height $h$, transactions are validated and connected in
  this order, starting from the UTXO set as of $B$'s parent:
  + if $h > 1$ and $B$'s header disapproves its parent's regular tree, the
    effects of that regular tree are undone first: its outputs are removed and
    the outputs it spent are restored (#chref("blocks"));
  + the transactions of $B$'s stake tree, in order;
  + the transactions of $B$'s regular tree, in order.
  Each transaction is validated (@alg:transactions-inputs) against the set
  produced by all preceding steps and is then connected before the next is
  validated. Consequently:
  - an input #MAY reference an output of an *earlier* transaction of the
    same tree or of a tree connected before, subject to all other rules;
  - an input referencing an output of the same transaction or of a *later*
    transaction in the block references a nonexistent entry and #MUST be
    rejected;
  - two inputs anywhere in the block that spend the same output are a double
    spend: the second one to be connected references a spent entry and #MUST
    be rejected.
] <rule:transactions-connect-order>

The combination of @rule:transactions-connect-order with the maturity and
same-block rules yields the following availability matrix.

#figure(
  caption: [May a transaction spend an output created in the same block?],
  table(
    columns: (auto, auto, 1fr),
    table.header([Spender], [Creator], [Verdict]),
    [Regular], [Earlier regular transaction (not the coinbase)], [Yes, unless the creator has a
      nonzero expiry (@rule:transactions-expiry-maturity).],
    [Regular], [Coinbase], [No: coinbase maturity.],
    [Regular], [Same or later regular transaction], [No: entry does not yet exist.],
    [Regular], [Stake transaction of the same block], [The entry exists, but every spendable stake
      output is tagged and subject to a maturity of at least #param("SStxChangeMaturity") $= 1$
      (`OP_SSTX` outputs are not spendable by regular transactions at all), so: no.],
    [Stake], [Any transaction of the same block], [No (@rule:transactions-no-same-block-stake),
      except @tab:transactions-sbss.],
  ),
) <tab:transactions-inblock>

#rationale[
  The stake tree is connected before the regular tree, and may not use outputs
  of the same block, because the next block's votes may disapprove this
  block's regular tree while its stake tree remains valid regardless. A
  stake transaction depending on the regular tree could otherwise be left
  spending outputs that no longer exist.
]

#pitfall[
  Disapproval is applied before the current block's stake tree is validated.
  Neither tree of a block that disapproves its parent can spend outputs created
  by the parent's regular tree, and outputs that the parent's regular
  transactions had spent are available again to both trees of the block.
]

=== Historical same-block stake spends <sec:transactions-sbss>

Rules enforced by earlier software versions allowed stake transactions in a
handful of blocks to spend output 0 of a regular transaction of the same
block. These
blocks are part of the main and test chains and must remain valid.

#rule("Historical same-block stake spend exceptions", src: (
  "internal/blockchain/validate.go · isSBSSViolation, CheckTransactionInputs",
  "internal/blockchain/utxoviewpoint.go · addSBSSViolations",
))[
  On the networks and at the heights listed in @tab:transactions-sbss, if the
  regular tree of the block at that height contains a transaction with the
  listed hash, then before the stake tree of that block is connected (and
  after any disapproval of the parent is applied), an entry for output 0 of
  that transaction is added to the UTXO set as if
  that transaction had been connected (height $h$, index equal to its
  regular-tree position, subject to @rule:transactions-unspendable).
  @rule:transactions-no-same-block-stake does not apply to inputs of that block
  that reference an output of the listed transaction (only output 0 is made
  available in this way). When the regular tree is
  later connected, the listed transaction's outputs are created as usual, which
  sets output 0 unspent again even if a stake transaction spent it.
] <rule:transactions-sbss>

#figure(
  caption: [Historical same-block stake spend exceptions (transaction hashes in display form)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Height], [Regular transaction whose output 0 may be spent]),
    [mainnet], [1106817], [#hex("0875ecdc5f12c8aa6ee0d54331fd5b5e786639882a3adb09882de5e3b939613b")],
    [mainnet], [1106831], [#hex("714e71358937cd33480fd2900853d43ea3440ca67b38bacdfeaeb0c37c80ee27")],
    [mainnet], [1106837], [#hex("aeba09a4efa334e3c13e68f27f40bd37cda7643c263f88d69f38a33c2cdacd18")],
    [mainnet], [1106854], [#hex("17228266d9d6dd7084aa2e479319aca6d755c2a9d2dbb3cf28c8151470c7a439")],
    [mainnet], [1106860], [#hex("20d6d3ed1b609f03969474dca1f452c25e035766457dfd58061f9b9270fc4e6d")],
    [mainnet], [1107195], [#hex("5d2e1898fe0c631cb795b1906fb3cf8d9772f1826be8dea64dd3ab85ac0ab2d3")],
    [testnet3], [1980161], [#hex("451b6eed1a777bc5bbb5c1dbe10a9e444cbeb7d863adb75fc6b7a676b3dcbb58")],
  ),
) <tab:transactions-sbss>

#pitfall[
  The exception is keyed on the network, the height of the block being
  validated and the hash of the referenced transaction; it applies on side
  chains at those heights as well. After such a block, output 0 of the listed
  transaction is an unspent entry of the UTXO set, even though a stake
  transaction in the block consumed it (unless a regular transaction later in
  the same block spends it again). An implementation that marks it spent
  diverges from the reference UTXO set.
]

== Signature Operations <sec:transactions-sigops>

Blocks limit the number of signature-checking operations they contain
(#chref("blocks")). The limit is defined in terms of two per-transaction
counts built on the script-level counting functions of #chref("script"):
`sigop_count`, which counts `OP_CHECKSIG`-class opcodes in one script with
the quick, imprecise method, and `precise_p2sh_sigop_count`, which, given a
signature script and the P2SH output script it spends, counts the opcodes of
the redeem script.

#algorithm("Per-transaction signature operation counts", src: (
  "internal/blockchain/validate.go · countSigOps, countP2SHSigOps, CountTotalSigOps",
))[
  ```python
  def basic_sigops(tx, is_coinbase, is_vote, treasury) -> uint32:
      if treasury and is_treasurybase(tx):
          return 0
      inputs = [] if is_coinbase else (tx.inputs[1:] if is_vote else tx.inputs)
      n = 0
      for txin in inputs:
          n = checked_add_u32(n, sigop_count(txin.sig_script, treasury))
      for out in tx.outputs:
          n = checked_add_u32(n, sigop_count(out.pk_script, treasury))
      return n

  def p2sh_sigops(tx, is_coinbase, is_vote, view, treasury) -> uint32:
      if is_coinbase:
          return 0
      if treasury and (is_treasury_spend(tx) or is_treasurybase(tx)):
          return 0
      n = 0
      for txin in (tx.inputs[1:] if is_vote else tx.inputs):
          e = view.lookup(txin.prev_out)
          if e is None or e.spent: reject("ErrMissingTxOut")
          if not is_p2sh(e.pk_script):           # untagged 23-byte form only
              continue
          n = checked_add_u32(n, precise_p2sh_sigop_count(txin.sig_script,
                                                          e.pk_script, treasury))
      return n

  def total_sigops(tx, is_coinbase, is_vote, view, treasury) -> uint32:
      return checked_add_u32(basic_sigops(tx, is_coinbase, is_vote, treasury),
                             p2sh_sigops(tx, is_coinbase, is_vote, view, treasury))
  # checked_add_u32 rejects with ErrTooManySigOps on uint32 overflow.
  ```
] <alg:transactions-sigops>

The arguments `is_coinbase` and `is_vote` are derived differently at dcrd's
two call sites: from the form of the transaction for every transaction of
both trees in the contextual check, and from its position (first of the
regular tree; a vote in the stake tree) during connection. The two agree for
every block that passes the other rules (#chref("blocks")).

No limit applies to a single transaction. #chref("blocks") specifies the two
block limits: the sum of `basic_sigops` over both trees, and, separately for
each tree during connection, the running sum of `total_sigops`, each bounded by
#const("MaxSigOpsPerBlock") (5000).

#pitfall[
  `p2sh_sigops` recognizes only the untagged pay-to-script-hash form. Inputs
  spending stake-tagged P2SH outputs (for example `OP_SSGEN` followed by a P2SH
  script) contribute only their quick count from `basic_sigops`. During
  connection the `p2sh_sigops` lookup happens before the transaction is
  connected, against the same UTXO state as @alg:transactions-inputs.
]

== Script Validation <sec:transactions-scripts>

Ownership of an output is proved by script execution: for each input, the
signature script of the input and the output script of the referenced output
are executed together by the script engine (#chref("script")). This section
specifies which inputs are executed, with which parameters, and the effect
of a failure.

#rule("Inputs whose scripts are executed", src: (
  "internal/blockchain/scriptval.go · checkBlockScripts",
  "internal/blockchain/validate.go · checkConnectBlock",
))[
  For every transaction in both trees, every input whose outpoint index is
  *not* #hex("ffffffff") (no UTXO entry can have that index) #MUST have its
  scripts executed successfully, except
  that, if `autorevocations` is active, no input of a stake-tree transaction
  that is a revocation (`is_revocation`) with version at least 2 is executed.
  Inputs with index #hex("ffffffff") (the null inputs of the coinbase, vote
  stakebase, treasurybase and treasury spend) are never executed. The
  treasury spend's authorization is verified outside the script engine
  (#chref("treasury")).
] <rule:transactions-script-inputs>

#rationale[
  Under #dcp(9), consensus already forces a version 2 revocation to pay exactly
  the amounts committed by the ticket to the committed addresses, with an
  empty signature script and no fee, so anyone may publish it and no signature
  is needed.
]

#rule("Script execution parameters", src: (
  "internal/blockchain/scriptval.go · validateHandler",
  "internal/blockchain/validate.go · consensusScriptVerifyFlags",
))[
  An executed input $i$ of transaction $T$ spending entry $e$ is evaluated by
  the script engine with: output script $e."script"$; script version
  $e."script version"$ (the version of the *spent output*, not of any output of
  $T$); the transaction $T$ and input index $i$ (for signature hashing); and
  the flag set $F$ of @tab:transactions-flags, determined by the agenda state
  of the block containing $T$. The entry is read from the UTXO set after the
  whole tree containing $T$ has been connected, ignoring its spent state.
] <rule:transactions-script-params>

#figure(
  caption: [Consensus script verification flags],
  table(
    columns: (auto, 1fr),
    table.header([Flag], [Included when]),
    [`ScriptVerifyCleanStack`], [Always (from the genesis block).],
    [`ScriptVerifyCheckLockTimeVerify`], [Always (from the genesis block).],
    [`ScriptVerifyCheckSequenceVerify`], [`lnfeatures` is active.],
    [`ScriptVerifySHA256`], [`lnfeatures` is active.],
    [`ScriptVerifyTreasury`], [`treasury` is active.],
    [`ScriptDiscourageUpgradableNops`], [Never in consensus (a policy flag,
      #chref("policy")).],
    [`ScriptVerifySigPushOnly`], [Never in consensus, and not set by dcrd's
      policy either, which checks for push-only signature scripts separately
      (#chref("policy")).],
  ),
) <tab:transactions-flags>

The meaning of each flag is specified in #chref("script").

#rule("Script failure invalidates the block", src: "internal/blockchain/scriptval.go · validateHandler")[
  If creating the script engine for an executed input fails (malformed
  scripts, a non-push-only signature script spending a P2SH-shaped output,
  and the other preconditions of
  #chref("script")\; `ErrScriptMalformed`), or if execution fails
  (`ErrScriptValidation`), the block #MUST be rejected. An output script with a
  nonzero script version passes execution once the engine is created
  (#chref("script")).
] <rule:transactions-script-failure>

#note[
  dcrd validates scripts in parallel and caches verified signatures; the cache
  and the evaluation order have no effect on the verdict. dcrd skips script
  execution (and expiry and finality checks) for blocks that are ancestors of
  its configured assumed-valid block; that is a trust optimization described
  in #chref("blocks"), not a change to the rules.
]

== Error Kinds <sec:transactions-errors>

@tab:transactions-errors maps each error kind of the reference implementation
that arises from the rules of this chapter to the rule that produces it. Error
kinds do not affect consensus; they are listed as a cross-check.

#figure(
  caption: [Error kinds produced by the rules of this chapter],
  table(
    columns: (auto, 1fr),
    table.header([Error kind], [Rule]),
    [`ErrNoTxInputs`, `ErrNoTxOutputs`], [@rule:transactions-sanity-counts],
    [`ErrTxTooBig`], [@rule:transactions-sanity-size],
    [`ErrBadTxOutValue`], [@rule:transactions-sanity-outputs, @rule:transactions-input-amount,
      @rule:transactions-input-sum],
    [`ErrFraudAmountIn`], [@rule:transactions-sanity-valuein, @rule:transactions-witness],
    [`ErrFraudBlockHeight`, `ErrFraudBlockIndex`], [@rule:transactions-witness],
    [`ErrDuplicateTxInputs`], [@rule:transactions-sanity-dup],
    [`ErrTxVersionTooHigh`], [@rule:transactions-max-version],
    [`ErrScriptVersionTooHigh`], [@rule:transactions-max-script-version],
    [`ErrRegTxCreateStakeOut`], [@rule:transactions-no-stake-opcodes],
    [`ErrScriptMalformed`], [@rule:transactions-no-stake-opcodes, @rule:transactions-script-failure],
    [`ErrBadCoinbaseOutpoint`, `ErrBadCoinbaseFraudProof`, `ErrBadCoinbaseScriptLen`],
      [@rule:transactions-coinbase-input],
    [`ErrBadStakebaseScriptLen`, `ErrBadStakebaseScrVal`], [@rule:transactions-vote-input],
    [`ErrInvalidRevocationTxVersion`], [@rule:transactions-revocation-version],
    [`ErrBadTreasurybaseOutpoint`, `ErrBadTreasurybaseFraudProof`, `ErrBadTreasurybaseScriptLen`],
      [@rule:transactions-treasurybase-input],
    [`ErrBadTSpendOutpoint`, `ErrBadTSpendFraudProof`, `ErrBadTSpendScriptLen`],
      [@rule:transactions-tspend-input],
    [`ErrInvalidTAddChange`], [@rule:transactions-tadd-change],
    [`ErrBadTxInput`], [@rule:transactions-vote-input, @rule:transactions-revocation-version,
      @rule:transactions-nonnull-inputs, @rule:transactions-tadd-spend],
    [`ErrStakeTxInRegularTree`, `ErrRegTxInStakeTree`, `ErrNonstandardStakeTx`],
      [@rule:transactions-tree-placement],
    [`ErrExpiredTx`], [@rule:transactions-expiry],
    [`ErrUnfinalizedTx`], [@rule:transactions-finality, @rule:transactions-seq-enforce],
    [`ErrMissingTxOut`], [@rule:transactions-tree-byte, @rule:transactions-unspendable,
      @rule:transactions-input-exists, @rule:transactions-no-same-block-stake,
      @rule:transactions-tspend-sequence, @rule:transactions-connect-order],
    [`ErrZeroValueOutputSpend`], [@rule:transactions-zero-value],
    [`ErrImmatureSpend`], [@rule:transactions-coinbase-maturity, @rule:transactions-tgen-maturity,
      @rule:transactions-stakeout-maturity, @rule:transactions-change-maturity],
    [`ErrExpiryTxSpentEarly`], [@rule:transactions-expiry-maturity],
    [`ErrTxSStxOutSpend`], [@rule:transactions-sstx-spend],
    [`ErrSpendTooHigh`], [@rule:transactions-fee],
    [`ErrTooManySigOps`], [@alg:transactions-sigops (overflow); limits in #chref("blocks")],
    [`ErrScriptValidation`], [@rule:transactions-script-failure],
  ),
) <tab:transactions-errors>
