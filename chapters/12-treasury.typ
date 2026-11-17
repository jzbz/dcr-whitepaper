#import "../template.typ": *

= The Decentralized Treasury <ch:treasury>

A fixed share of every block subsidy is reserved for the development of the
project. Since the activation of #dcp(6) @dcp0006 this share is not paid to an
address but credited to an on-chain *treasury account*: a balance that exists
only as consensus state, that no private key controls, and that can be debited
only by a *treasury spend* transaction which is both signed by one of a small
set of well-known keys and approved by the stakeholders through the ordinary
proof-of-stake votes. This chapter specifies the account, the three
transaction types that change it, the voting procedure for spends, and the
three successive expenditure policies that limit how fast the account may be
drawn down.

== Background and Overview <sec:treasury-overview>

=== The legacy arrangement <sec:treasury-legacy>

From block 2 until the activation of the `treasury` agenda, the coinbase
transaction of every block was required to pay the treasury share of the
subsidy in its output 0 to a fixed, network-specific script,
#param("OrganizationPkScript") (on the main network a 2-of-3 pay-to-script-hash
script controlled by a conventional legal entity), and from stake validation
height on the amount was reduced in proportion to the number of votes in the
block. The exact amounts and the
coinbase rules of that era are specified in #chref("subsidy")\; the relevant
facts here are that these payments created ordinary unspent outputs, that
spending them required only the keys behind the organization script, and that
they lived in the regular transaction tree, so that a block whose regular tree
was disapproved by the next block's voters also lost its treasury payment.

#rationale[
  #dcp(6) gives the motivation: the legacy treasury put sovereignty over spending
  in the hands of the key holders rather than the stakeholders, exposed the
  funds to theft, coercion or loss of key holders, and was insufficiently
  transparent. The decentralized treasury converts the treasury from an output
  model to an account model whose debits require a stakeholder vote.
]

=== The account model <sec:treasury-account>

With the `treasury` agenda active, value enters and leaves the treasury
through three new kinds of stake transaction, all of transaction version 3
(`TxVersionTreasury`) and all carried in the stake tree:

#figure(
  caption: [Treasury transaction types],
  table(
    columns: (auto, auto, 0.8fr, 1.6fr),
    table.header([Type], [Created by], [Per block], [Effect on the treasury account]),
    [Treasurybase], [The block's miner], [exactly one, first in the stake tree],
    [Credits the treasury share of the block subsidy. Replaces the legacy coinbase output.],
    [Treasury add (TAdd)], [Anyone], [at most 20],
    [Burns ordinary coins (its inputs) and credits the amount of its `OP_TADD` output.],
    [Treasury spend (TSpend)], [Holders of a Politeia key (Pi key)], [only in treasury vote interval blocks],
    [Debits the treasury by its input value and creates `OP_TGEN`-tagged outputs paying the recipients.],
  ),
) <tab:treasury-types>

The balance of the account is not stored in any output. Every full node
computes it from the chain (@sec:treasury-balance). Credits and debits are
subject to coinbase maturity: the value changes made by a block take effect in
the balance #param("CoinbaseMaturity") blocks later.

A treasury spend names its own voting window through its `Expiry` field.
Ticket holders vote yes or no on it by appending an optional output to their
ordinary vote transactions (@sec:treasury-votes). The spend may be included
only in a block whose height is a multiple of the *treasury vote interval*
(TVI), only within its window, only once on a given chain, only with a quorum
of votes and a sufficient yes majority, and only if the total spent stays
within the expenditure policy in force (@sec:treasury-policy).

=== Activation <sec:treasury-activation>

The rules of this chapter apply to a block exactly when the `treasury` agenda
(#dcp(6)) *is active for the block* in the sense of #chref("voting"). In dcrd
the question is always asked of the block's parent: the agenda is active for
block $B$ when it is active "as of the block after" $B$'s parent. The agenda is
never active for the genesis block or for block 1, regardless of network.

#history[
  On the main network the `treasury` agenda became active with block 552448;
  `reverttreasurypolicy` (#dcp(7)) with block 657280; and `maxtreasuryspend`
  (#dcp(13)) with block 1052416. These heights are informative. An
  implementation derives activation from the votes in the chain, as described
  in #chref("voting"), and the other networks activate at different heights.
]

The balance of the treasury account starts at zero. Activation did not move
any funds held under the legacy organization script: dcrd contains no code that
credits a legacy balance, and the account balance is defined solely by the
treasury transactions in blocks for which the agenda is active. Moving legacy
funds into the account is possible only through ordinary treasury add
transactions, which is one of the uses #dcp(6) names for them.

Activation of the `treasury` agenda changes several rules owned by other
chapters. They are listed in @tab:treasury-side-effects for orientation and
those that concern treasury transactions are specified in
@sec:treasury-interactions.

#figure(
  caption: [Rules changed by the `treasury` agenda],
  table(
    columns: (1fr, auto),
    table.header([Change], [Specified in]),
    [The coinbase transaction must have version 3; it no longer pays the treasury, and its height-encoding null-data output moves from output 1 to output 0.], [#chref("subsidy")],
    [The treasury subsidy is no longer reduced by the number of votes in the block.], [#chref("subsidy")],
    [The opcodes 0xc1, 0xc2 and 0xc3 are interpreted as `OP_TADD`, `OP_TSPEND` and `OP_TGEN`, and are forbidden in the outputs of regular transactions.], [#chref("script"), @rule:treasury-regular-opcodes],
    [`OP_TSPEND` counts as a signature operation.], [#chref("script"), @sec:treasury-sigops],
    [Vote transactions may carry a final treasury-vote output.], [#chref("staking"), @sec:treasury-vote-output],
    [Outputs tagged `OP_SSGEN` or `OP_SSRTX` require #param("CoinbaseMaturity") confirmations instead of #param("SStxChangeMaturity").], [@rule:staking-stake-output-maturity],
    [Treasurybase, treasury add and treasury spend transactions are accepted in the stake tree.], [this chapter],
  ),
) <tab:treasury-side-effects>

== Parameters and Constants <sec:treasury-params>

@tab:treasury-params lists the network parameters and constants used in this
chapter with their main-network values. Abbreviations used in formulas are
given in the second column. The values for the other networks are tabulated in
#chref("parameters").

#figure(
  caption: [Treasury parameters and constants (main network)],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Name], [Symbol], [Value], [Meaning]),
    [#param("TreasuryVoteInterval")], [TVI], [288], [Treasury spends may only be included in blocks whose height is a nonzero multiple of TVI.],
    [#param("TreasuryVoteIntervalMultiplier")], [TVIM], [12], [Length of a voting window in TVIs.],
    [#param("TreasuryVoteQuorumMultiplier")], [TVQM], [1], [Quorum numerator.],
    [#param("TreasuryVoteQuorumDivisor")], [TVQD], [5], [Quorum denominator (quorum 20%).],
    [#param("TreasuryVoteRequiredMultiplier")], [TVRM], [3], [Required yes fraction numerator.],
    [#param("TreasuryVoteRequiredDivisor")], [TVRD], [5], [Required yes fraction denominator (60%).],
    [#param("TreasuryExpenditureWindow")], [TEW], [2], [Length of an expenditure policy window in voting windows.],
    [#param("TreasuryExpenditurePolicy")], [TEP], [6], [Number of prior policy windows averaged (#dcp(6) policy only).],
    [#param("TreasuryExpenditureBootstrap")], [TEB], [1600000000000], [Average assumed when no prior window has spends (#dcp(6) policy only), in atoms (16000 DCR).],
    [#param("PiKeys")], [], [2 keys], [Compressed secp256k1 public keys allowed to sign treasury spends (@tab:treasury-pikeys).],
    [#param("CoinbaseMaturity")], [CM], [256], [Maturity of treasury credits and debits and of `OP_TGEN` outputs.],
    [#param("TicketsPerBlock")], [TPB], [5], [Votes per block; bounds the treasury vote count.],
    [#param("StakeValidationHeight")], [SVH], [4096], [Treasury spend voting windows may not start before this height.],
    [#param("BaseSubsidy")], [], [3119582664], [Initial block subsidy; defines the #dcp(13) floor.],
    [`TxVersionTreasury`], [], [3], [Transaction version of all treasury transactions.],
    [`MaxTAddsPerBlock`], [], [20], [Maximum number of treasury adds per block.],
    [`TSpendScriptLen`], [], [100], [Exact length of a treasury spend signature script.],
    [`OP_TADD`, `OP_TSPEND`, `OP_TGEN`], [], [0xc1, 0xc2, 0xc3], [Treasury opcodes (#chref("script")).],
  ),
) <tab:treasury-params>

#figure(
  caption: [Main-network Pi keys (#param("PiKeys")), as 33-byte compressed public keys],
  table(
    columns: (auto, 1fr),
    table.header([Index], [Public key]),
    [0], [#hex("03f6e7041f1cf51ee10e0a01cd2b0385ce3cd9debaabb2296f7e9dee9329da946c")],
    [1], [#hex("0319a37405cb4d1691971847d7719cfce70857c0f6e97d7c9174a3998cf0ab86dd")],
  ),
) <tab:treasury-pikeys>

Several derived quantities recur. With the main-network values:

/ Voting window length: $"TVI" dot "TVIM" = 3456$ blocks.
/ Expenditure policy window $W$: $"TVI" dot "TVIM" dot "TEW" = 6912$ blocks.
/ Maximum votes in a window: $"TPB" dot "TVI" dot "TVIM" = 17280$.
/ Quorum: $floor(17280 dot "TVQM" / "TVQD") = 3456$ votes.
/ Lower bound on the expiry of an includable spend: $2 + "SVH" + "TVI" dot "TVIM" = 7554$
  (@rule:treasury-tspend-full-window). The bound is not itself a valid
  expiry, because $"Expiry" - 2$ must be a multiple of TVI; the smallest
  valid expiry is 7778, with window $[4320, 7776]$.
/ #dcp(13) spend floor: $floor("BaseSubsidy" / 10) dot "TVI" dot "TVIM" = 1078127767296$ atoms.

#vector[Derived treasury quantities on every network][
  ```
  network   floor          W     maxVotes quorum bound minExp TVI TVIM CM  SVH
  mainnet   1078127767296  6912  17280    3456   7554  7778   288 12   256 4096
  testnet3  60000000000    960   1200     240    1010  1022   60  4    16  768
  simnet    720000000000   576   720      144    290   290    48  3    16  144
  regnet    60000000000    48    60       12     158   158    4   3    16  144
  ```
  `bound` is $2 + "SVH" + "TVI" dot "TVIM"$; `minExp` is the smallest expiry
  at or above it with $"Expiry" - 2$ a multiple of TVI.
]

== Classification of Treasury Transactions <sec:treasury-classify>

Every transaction is classified as exactly one of: regular, ticket, vote,
revocation, treasury add, treasury spend or treasurybase. The ticket, vote and
revocation tests (#chref("staking")) are applied first. A transaction that is
none of these is tested for the three treasury types only if its version is at
least 3, in the order treasury add, treasury spend, treasurybase; the first
structural predicate that holds determines the type, and a transaction that
satisfies none is regular. The three structural predicates are defined in
@alg:treasury-tadd-structure, @alg:treasury-tspend-structure and
@alg:treasury-tbase-structure. Each requires version exactly 3, and the three
are mutually exclusive, so the order matters only for performance.

Classification is a pure function of the transaction and does not depend on
whether the `treasury` agenda is active. The following two rules make the
agenda's state matter.

#rule("Treasury transactions only in the stake tree", src: "internal/blockchain/validate.go · checkBlockContext")[
  A block's regular transaction tree #MUSTNOT contain any transaction that is
  classified as anything other than regular, including treasury add, treasury
  spend and treasurybase transactions. This rule applies whether or not the
  `treasury` agenda is active for the block.
] <rule:treasury-stake-tree-only>

#rule("No treasury transactions before activation", src: "internal/blockchain/validate.go · checkBlockContext")[
  If the `treasury` agenda is not active for a block, its stake tree #MUSTNOT
  contain any transaction classified as treasury add, treasury spend or
  treasurybase. (dcrd counts the stake transactions of each type it accepts,
  counting the treasury types only when the agenda is active, and rejects the
  block when the counts do not add up to the number of stake transactions.)
] <rule:treasury-inactive>

#rule("Permitted stake transactions before stake validation height", src: "internal/blockchain/validate.go · checkBlockContext")[
  In a block whose height is below #param("StakeValidationHeight"), every stake
  transaction #MUST be a ticket, a treasury add or a treasurybase (the latter
  two only when the agenda is active). In particular a treasury spend is never
  valid below stake validation height.
] <rule:treasury-early-stake>

The coinbase test of the regular tree (#chref("subsidy")) also depends on the
agenda and on the treasury spend format, because a treasury spend, like a
coinbase, has a single input that references the null outpoint.

#rule("Coinbase detection with the treasury active", src: "blockchain/standalone/tx.go · IsCoinBaseTx")[
  When the `treasury` agenda is active, a transaction is a coinbase only if, in
  addition to the conditions of #chref("subsidy") (exactly one input whose
  previous outpoint has index $2^32 - 1$ and the all-zero hash), its version is 3
  and it is *not treasury-spend-like*. A transaction is treasury-spend-like
  when it has at least two outputs, its input 0 signature script and the
  scripts of outputs 0 and 1 are all non-empty, the last byte of the input 0
  signature script is `OP_TSPEND` (0xc2), the first byte of the output 0 script
  is `OP_RETURN` (0x6a), and the first byte of the output 1 script is `OP_TGEN`
  (0xc3). Note that a treasurybase satisfies this coinbase test; dcrd excludes
  it explicitly wherever the distinction matters, as noted below.
] <rule:treasury-coinbase-detect>

== The Treasury Balance <sec:treasury-balance>

=== Treasury values of a block <sec:treasury-values>

Each block for which the `treasury` agenda is active carries a list of
*treasury values*: signed amounts, in atoms, that change the treasury balance.
Credits are positive and debits negative. The list is derived from the block's
stake tree in transaction order, as in @alg:treasury-values. The *net change*
of a block is the sum of its values. A block for which the agenda is not active
has no treasury values.

#algorithm("Treasury values of a block", src: "internal/blockchain/treasury.go · dbPutTreasuryBalance")[
  ```python
  def treasury_values(block) -> list[tuple[str, int64]]:
      values = []
      for tx in block.stake_transactions:            # in block order
          t = classify(tx)
          if t == "tadd":
              values.append(("tadd", tx.outputs[0].value))   # change ignored
          elif t == "treasurybase":
              values.append(("tbase", tx.outputs[0].value))
          elif t == "tspend":
              total_out = 0
              for out in tx.outputs[1:]:                     # output 0 is the OP_RETURN
                  values.append(("tspend", -out.value))
                  total_out += out.value
              # The fee, recorded as a non-positive debit.
              values.append(("fee", total_out - tx.inputs[0].value_in))
      return values

  def is_debit(kind) -> bool:
      return kind == "tspend" or kind == "fee"

  def net_change(block) -> int64:
      return sum(amount for (_, amount) in treasury_values(block))
  ```
] <alg:treasury-values>

For a treasury spend the values sum to exactly $-$`ValueIn` of its single input:
the payouts plus the recorded fee, which is `ValueIn` minus the payouts. The
transaction fee (`ValueIn` minus the sum of all output values) is paid out of
the treasury and, like every other stake-tree fee, is available to the block's
coinbase (#chref("subsidy")). The two differ only by the value of output 0,
which is a null-data output and is therefore destroyed.

=== Balance and maturity <sec:treasury-maturity>

#rule("Treasury balance", src: ("internal/blockchain/treasury.go · calculateTreasuryBalance", "internal/blockchain/chain.go · connectBlock"))[
  Let $B$ be a block at height $H$ for which the `treasury` agenda is active,
  and let $A$ be the height of the earliest block on $B$'s chain for which the
  agenda is active. The *treasury balance as of $B$* is
  $ "bal"(B) = sum_(h = A)^(H - "CM") "net"(B_h), $
  where $B_h$ is $B$'s ancestor at height $h$ and the sum is zero when
  $H - "CM" < A$. Equivalently, $"bal"(B) = 0$ if the agenda is not active for
  $B$'s parent or if $H - "CM" < A$, and otherwise
  $"bal"(B) = "bal"("parent"(B)) + "net"(B_(H - "CM"))$.
] <rule:treasury-balance>

The balance as of $B$ therefore includes the values of $B$'s ancestor
#param("CoinbaseMaturity") blocks back but none of the values of the
$"CM"$ most recent blocks, $B$ itself included. Credits (treasurybases and
treasury adds) and debits (treasury spends and their fees) mature alike. With
$"CM" = 256$, the treasurybase of the first active block on the main network,
552448, first counts in the balance of block 552704.

The balance does not depend on the approval of any block by the following
block's voters. All treasury transactions are in the stake tree, which a
disapproval vote never removes (#chref("blocks")). This is a deliberate change
from the legacy arrangement, in which a disapproved block lost its treasury
payment.

#pitfall[
  The balance used to check a treasury spend (@rule:treasury-expenditure) does
  not reflect debits from treasury spends mined in the preceding
  $"CM" - 1$ blocks, because they have not yet matured. On the main network,
  testnet and simnet $"TVI" > "CM"$, so the spends of one TVI block have matured
  by the next. On regnet ($"TVI" = 4$, $"CM" = 16$) they have not. An
  implementation must use exactly the balance of @rule:treasury-balance and must
  not subtract immature debits. On regnet the balance of a later block can
  therefore become negative once the spends of several TVI blocks less than
  CM apart mature, each of which passed @alg:treasury-expenditure-check; no
  consensus rule checks the balance of a block that contains no treasury
  spend. dcrd cannot record a negative balance in its treasury state and fails
  to connect such a block with an internal database error, not with a rule
  violation.
]

== Treasurybase <sec:treasury-tbase>

The treasurybase carries the treasury share of the block subsidy into the
account. It has a single input that, like a coinbase input, references no
previous output and whose `ValueIn` states the amount created; an `OP_TADD`
output whose value is that amount; and a null-data output that commits to the
block height, which makes every treasurybase hash distinct.

#fieldtable(
  caption: [Treasurybase transaction],
  ("Version", "uint16", "2", [3.]),
  ("TxIn[0].PreviousOutPoint", "outpoint", "37", [Null outpoint: hash all zero, index 0xffffffff, tree 0 (regular).]),
  ("TxIn[0].Sequence", "uint32", "4", [Unconstrained by consensus (dcrd writes 0xffffffff).]),
  ("TxIn[0].ValueIn", "int64", "8", [The treasury subsidy for the block.]),
  ("TxIn[0].BlockHeight", "uint32", "4", [0x00000000 (null fraud proof).]),
  ("TxIn[0].BlockIndex", "uint32", "4", [0xffffffff (null fraud proof).]),
  ("TxIn[0].SignatureScript", "varbytes", "1", [Empty.]),
  ("TxOut[0].Value", "int64", "8", [The treasury subsidy for the block.]),
  ("TxOut[0].Version", "uint16", "2", [0.]),
  ("TxOut[0].PkScript", "varbytes", "2", [`c1` (`OP_TADD`), exactly one byte.]),
  ("TxOut[1].Value", "int64", "8", [0 (implied by the amount rules).]),
  ("TxOut[1].Version", "uint16", "2", [0.]),
  ("TxOut[1].PkScript", "varbytes", "15", [14 bytes: `6a 0c` followed by $"LE"_32$(height) and 8 arbitrary bytes.]),
  ("LockTime, Expiry", "uint32", "8", [Subject only to the general finality and expiry rules (#chref("transactions")).]),
) <tab:treasury-tbase>

#algorithm("Treasurybase structure", src: ("blockchain/stake/treasury.go · CheckTreasuryBase", "blockchain/standalone/tx.go · IsTreasuryBase"))[
  ```python
  NULL_OUTPOINT = (bytes(32), 0xffffffff, 0)        # (hash, index, tree)

  def is_treasurybase(tx) -> bool:                    # full predicate (stake package)
      if tx.version != 3:                            return False
      if len(tx.inputs) != 1 or len(tx.outputs) != 2: return False
      if len(tx.inputs[0].signature_script) != 0:    return False
      if tx.inputs[0].previous_outpoint != NULL_OUTPOINT: return False
      if any(out.script_version != 0 for out in tx.outputs): return False
      if tx.outputs[0].pk_script != bytes([0xc1]):   return False   # OP_TADD only
      return is_strict_null_data(tx.outputs[1], 12)

  def is_strict_null_data(out, n) -> bool:            # n <= 75
      s = out.pk_script
      return out.script_version == 0 and len(s) == 2 + n and s[0] == 0x6a and s[1] == n

  def is_treasurybase_minimal(tx) -> bool:            # minimal predicate (standalone)
      return (tx.version == 3 and len(tx.inputs) == 1 and len(tx.outputs) == 2
              and len(tx.inputs[0].signature_script) == 0
              and tx.outputs[0].pk_script == bytes([0xc1])
              and len(tx.outputs[1].pk_script) == 14
              and tx.outputs[1].pk_script[0] == 0x6a
              and tx.outputs[1].pk_script[1] == 0x0c
              and tx.inputs[0].previous_outpoint == NULL_OUTPOINT)
  ```
] <alg:treasury-tbase-structure>

`is_strict_null_data` is stated here for the lengths used in this chapter
(12 and 32). For these lengths the general strict null-data test of
#chref("script") reduces to the form shown: `OP_RETURN` followed by the single
canonical push opcode equal to the length, and nothing else. The minimal
predicate differs from the full one only in not checking output script
versions. It is used by the positional rules below. A transaction that passes
the minimal predicate but not the full one is never valid, since it is then
classified as regular, and a regular transaction is rejected in the stake
tree (@rule:blocks-tree-composition) and fails the regular-tree checks
elsewhere.

#rule("Treasurybase required and unique", src: "internal/blockchain/validate.go · checkBlockContext")[
  If the `treasury` agenda is active for a block, its stake tree #MUST be
  non-empty and its first transaction #MUST satisfy the minimal treasurybase
  predicate of @alg:treasury-tbase-structure, and no other transaction in the
  stake tree #MAY satisfy that predicate.
] <rule:treasury-tbase-position>

#rule("Treasurybase form", src: ("blockchain/stake/treasury.go · CheckTreasuryBase", "internal/blockchain/validate.go · checkTransactionContext"))[
  The first stake transaction of a block for which the agenda is active #MUST
  be classified as a treasurybase, so it #MUST satisfy the full predicate of
  @alg:treasury-tbase-structure. As a treasurybase it #MUST additionally have a
  null fraud proof (`BlockHeight` = 0 and `BlockIndex` = 0xffffffff) and an
  empty signature script.
] <rule:treasury-tbase-form>

#rule("Treasurybase height commitment", src: "internal/blockchain/validate.go · checkTreasurybaseUniqueHeight")[
  For a block at height $H >= 2$ for which the agenda is active, output 1 of
  the treasurybase #MUST have script version 0 and a script of exactly 14 bytes
  beginning `6a 0c`, and bytes 2 to 5 of that script, read as a little-endian
  `uint32`, #MUST equal $H$ (as `uint32`). The remaining 8 bytes are
  unconstrained.
] <rule:treasury-tbase-height>

#rule("Treasurybase amount", src: ("internal/blockchain/subsidy.go · checkTreasuryBase", "internal/blockchain/validate.go · checkTransactionsAndConnect", "internal/blockchain/validate.go · CheckTransactionInputs"))[
  Let $S$ be the treasury subsidy for the block, computed as in
  #chref("subsidy") with the treasury agenda active (that is, not reduced by
  the number of votes). For a block at height $H >= 2$ for which the agenda is
  active:
  - the treasurybase #MUST have exactly two outputs, output 0 #MUST have script
    version 0 and the one-byte script `OP_TADD`, and its value #MUST equal $S$;
  - the `ValueIn` of its input #MUST equal $S$;
  - the sum of its output values #MUSTNOT exceed its `ValueIn`. With the two
    preceding conditions, this forces output 1 to have value 0.
] <rule:treasury-tbase-amount>

#rule("Treasurybase creates no outputs", src: "internal/blockchain/utxoviewpoint.go · connectStakeTransaction")[
  Connecting a treasurybase spends nothing and adds none of its outputs to the
  set of unspent transaction outputs. Its only effect on state is its treasury
  value (@alg:treasury-values).
] <rule:treasury-tbase-noutxo>

A treasurybase has no signature operations (@sec:treasury-sigops). Its input
is not checked against any previous output and no script is executed for it.

#vector[Treasurybase, main network, height 1052416, 5 votes][
  Treasury subsidy at height 1052416: 56903836 atoms (with the treasury agenda
  active; the legacy rule would give 34142301 with 3 votes). The 8 arbitrary
  bytes are `01 02 ... 08`.

  Serialized: #hex("03000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff029c48640300000000000001c1000000000000000000000e6a0c000f100001020304050607080000000000000000019c4864030000000000000000ffffffff00")

  Transaction hash (display form):
  #hex("9e57dfea4b6be2bcbab6c05e1b6a481b486fb7a81bcd2aeb168865128f202b5b")
]

== Treasury Add <sec:treasury-tadd>

A treasury add moves existing coins into the treasury account. Anyone may
create one. It spends ordinary outputs, exactly like a regular transaction, and
pays the amount to be credited into an `OP_TADD` output that is never
spendable. Change, if any, must go to a stake change output.

#fieldtable(
  caption: [Treasury add transaction],
  ("Version", "uint16", "2", [3.]),
  ("TxIn[0..n-1]", "inputs", "var", [One or more ordinary inputs spending existing outputs, with ordinary signature scripts.]),
  ("TxOut[0]", "output", "var", [Value: the amount credited to the treasury. Script version 0, script exactly `c1` (`OP_TADD`).]),
  ("TxOut[1]", "output", "var", [Optional. Stake change: script version 0, `OP_SSTXCHANGE` (0xbd) followed by a P2PKH or P2SH script; value nonzero.]),
) <tab:treasury-tadd>

#algorithm("Treasury add structure", src: ("blockchain/stake/treasury.go · CheckTAdd", "blockchain/stake/scripttype.go · isTaggedScript"))[
  ```python
  def is_p2pkh(s) -> bool:   # OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG
      return (len(s) == 25 and s[0] == 0x76 and s[1] == 0xa9 and s[2] == 0x14
              and s[23] == 0x88 and s[24] == 0xac)

  def is_p2sh(s) -> bool:    # OP_HASH160 <20> OP_EQUAL
      return len(s) == 23 and s[0] == 0xa9 and s[1] == 0x14 and s[22] == 0x87

  def is_tagged(out, opcode) -> bool:
      s = out.pk_script
      return (out.script_version == 0 and len(s) >= 1 and s[0] == opcode
              and (is_p2pkh(s[1:]) or is_p2sh(s[1:])))

  def is_tadd(tx) -> bool:
      if tx.version != 3:                         return False
      if len(tx.inputs) < 1:                      return False
      if len(tx.outputs) not in (1, 2):           return False
      for out in tx.outputs:
          if out.script_version != 0 or len(out.pk_script) == 0:
              return False
      if tx.outputs[0].pk_script != bytes([0xc1]): return False    # OP_TADD only
      if len(tx.outputs) == 2 and not is_tagged(tx.outputs[1], 0xbd):
          return False                                            # OP_SSTXCHANGE
      return True
  ```
] <alg:treasury-tadd-structure>

#rule("Treasury add change", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If a treasury add has two outputs, the value of output 1 #MUSTNOT be zero.
] <rule:treasury-tadd-change>

#rule("Treasury add inputs", src: ("internal/blockchain/validate.go · checkTransactionContext", "internal/blockchain/validate.go · CheckTransactionInputs"))[
  No input of a treasury add #MAY reference the null outpoint. Its inputs are
  subject to every input rule that applies to stake transactions
  (#chref("transactions")): they #MUST reference existing unspent outputs, with
  correct fraud-proof fields, satisfying all maturity requirements; they
  #MUSTNOT spend outputs created in the same block (in either tree), except
  the historical outputs of @rule:staking-same-block; they #MUSTNOT
  spend ticket (`OP_SSTX`) outputs; and the sum of the output values #MUSTNOT
  exceed the sum of the input values.
] <rule:treasury-tadd-inputs>

#rule("Treasury add limit", src: "internal/blockchain/validate.go · checkBlockContext")[
  A block #MUSTNOT contain more than `MaxTAddsPerBlock` = 20 treasury adds.
] <rule:treasury-tadd-limit>

#rule("Treasury add outputs are unspendable", src: ("internal/blockchain/utxoviewpoint.go · addTxOuts", "internal/blockchain/validate.go · CheckTransactionInputs"))[
  Output 0 of a treasury add is never added to the set of unspent transaction
  outputs. In addition, when the agenda is active for a block, no input of any
  transaction in it #MAY spend an output whose script version is 0 and whose
  script is exactly the single byte 0xc1. (This matters only for such outputs
  created by regular transactions before activation, when 0xc1 was an unknown
  opcode.)
] <rule:treasury-tadd-unspendable>

The fee of a treasury add (inputs minus outputs) is a stake-tree fee and is
available to the block's coinbase. The change output is an ordinary
`OP_SSTXCHANGE` output and matures under the general rule for stake change,
after #param("SStxChangeMaturity") blocks, or after #param("CoinbaseMaturity")
blocks if the treasury add has a nonzero `Expiry` (#chref("transactions")). The amount
of output 0 may be zero; no rule forbids it. Treasury adds are permitted below
stake validation height.

== Treasury Spend <sec:treasury-tspend>

A treasury spend debits the account. It has a single input that references no
previous output. Its `ValueIn` is the total amount taken from the treasury, and
its signature script carries a Schnorr signature by one of the Pi keys.
Output 0 commits to that amount and makes the transaction unique. Each further
output pays a recipient.

=== Format <sec:treasury-tspend-format>

#fieldtable(
  caption: [Treasury spend transaction],
  ("Version", "uint16", "2", [3.]),
  ("TxIn[0].PreviousOutPoint", "outpoint", "37", [Null outpoint: hash all zero, index 0xffffffff, tree 0.]),
  ("TxIn[0].Sequence", "uint32", "4", [Bit 31 (0x80000000, relative lock time disabled) must be set (@rule:treasury-tspend-sequence). dcrd writes 0xffffffff.]),
  ("TxIn[0].ValueIn", "int64", "8", [Total debited from the treasury: sum of payouts plus fee.]),
  ("TxIn[0].BlockHeight", "uint32", "4", [0x00000000 (null fraud proof).]),
  ("TxIn[0].BlockIndex", "uint32", "4", [0xffffffff (null fraud proof).]),
  ("TxIn[0].SignatureScript", "varbytes", "101", [Exactly 100 bytes, @tab:treasury-tspend-sigscript.]),
  ("TxOut[0]", "output", "45", [Value: any (normally 0). Script version 0. Script: 34 bytes, @tab:treasury-tspend-commit.]),
  ("TxOut[1..n]", "outputs", "var", [At least one. Script version 0. Script: `OP_TGEN` (0xc3) followed by a P2PKH (25-byte) or P2SH (23-byte) script.]),
  ("LockTime", "uint32", "4", [Subject to the general finality rule.]),
  ("Expiry", "uint32", "4", [Determines the voting window (@sec:treasury-window).]),
) <tab:treasury-tspend>

#figure(
  caption: [Treasury spend signature script (100 bytes)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Offset], [Bytes], [Content]),
    [0], [1], [`0x40` (`OP_DATA_64`)],
    [1], [64], [Schnorr signature, EC-Schnorr-DCRv0 encoding $r || s$ (#chref("crypto")). No hash-type byte.],
    [65], [1], [`0x21` (`OP_DATA_33`)],
    [66], [33], [Pi public key, compressed: first byte `0x02` or `0x03`.],
    [99], [1], [`0xc2` (`OP_TSPEND`)],
  ),
) <tab:treasury-tspend-sigscript>

#figure(
  caption: [Treasury spend output 0 script (34 bytes)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Offset], [Bytes], [Content]),
    [0], [1], [`0x6a` (`OP_RETURN`)],
    [1], [1], [`0x20` (`OP_DATA_32`)],
    [2], [8], [$"LE"_64$ of `TxIn[0].ValueIn` (two's complement).],
    [10], [24], [Arbitrary bytes. dcrd uses random bytes so that otherwise identical spends have distinct hashes.],
  ),
) <tab:treasury-tspend-commit>

#algorithm("Treasury spend structure", src: "blockchain/stake/treasury.go · CheckTSpend")[
  ```python
  def check_tspend(tx) -> tuple[bytes, bytes] | None:
      """Returns (signature, pubkey) if tx has the treasury spend form, else None."""
      if tx.version != 3:                              return None
      if len(tx.inputs) != 1 or len(tx.outputs) < 2:   return None
      for out in tx.outputs:
          if out.script_version != 0 or len(out.pk_script) == 0:
              return None
      s = tx.inputs[0].signature_script
      if len(s) != 100 or s[0] != 0x40 or s[65] != 0x21 or s[99] != 0xc2:
          return None
      signature, pubkey = s[1:65], s[66:99]
      if pubkey[0] not in (0x02, 0x03):                return None
      if not is_strict_null_data(tx.outputs[0], 32):   return None
      for out in tx.outputs[1:]:
          p = out.pk_script
          if p[0] != 0xc3:                             return None   # OP_TGEN
          if not (is_p2pkh(p[1:]) or is_p2sh(p[1:])):  return None
      return signature, pubkey

  def is_tspend(tx) -> bool:
      return check_tspend(tx) is not None
  ```
] <alg:treasury-tspend-structure>

Note that the structural predicate does not test the previous outpoint of the
input. It is tested by the next rule, so a transaction of the treasury spend
form whose input references a real output is classified as a treasury spend
and then rejected.

=== Transaction rules <sec:treasury-tspend-rules>

#rule("Treasury spend input", src: "internal/blockchain/validate.go · checkTransactionContext")[
  The input of a treasury spend #MUST reference the null outpoint (all-zero
  hash, index 0xffffffff, tree 0), #MUST have a null fraud proof
  (`BlockHeight` = 0, `BlockIndex` = 0xffffffff), and its signature script
  #MUST be exactly 100 bytes long.
] <rule:treasury-tspend-input>

#rule("Treasury spend key", src: ("internal/blockchain/validate.go · CheckTransactionInputs", "chaincfg/params.go · PiKeyExists"))[
  If the agenda is active for the block, the 33-byte public key at offset 66 of
  a treasury spend's signature script #MUST be byte-for-byte equal to one of the
  network's #param("PiKeys").
] <rule:treasury-tspend-pikey>

#rule("Treasury spend signature", src: ("internal/blockchain/treasury.go · verifyTSpendSignature", "txscript/sign/sign.go · TSpendSignatureScript"))[
  If the agenda is active for the block, the 64 bytes at offset 1 of the
  signature script #MUST parse as an EC-Schnorr-DCRv0 signature, the public key
  #MUST parse as a secp256k1 point, and the signature #MUST verify under that
  key for the message hash
  $ m = "SigHash"("SigHashAll", "tx", 0, "subscript" = "empty"), $
  that is, the signature hash of type `SigHashAll` (0x01) for input index 0
  computed as specified in #chref("script") with an empty subscript. Signature
  parsing and verification are specified in #chref("crypto").
] <rule:treasury-tspend-sig>

The signature hash does not cover the input's `ValueIn` (no Decred signature
hash does). It covers every output, and output 0 commits to `ValueIn`, which
@rule:treasury-tspend-amounts requires to match; the key holder therefore
fixes the exact amount, the recipients and the window (through `Expiry`). The signature script is not
covered (signature scripts never are), and it is never executed by the script
engine: script validation skips every input whose previous outpoint index is
0xffffffff (#chref("script")), so the signature is checked only by
@rule:treasury-tspend-sig.

#rule("Treasury spend amounts", src: ("internal/blockchain/validate.go · checkTreasurySpendInputs", "internal/blockchain/validate.go · CheckTransactionInputs"))[
  For a treasury spend in a block for which the agenda is active:
  - its `ValueIn` #MUST satisfy $0 <= "ValueIn" <= "MaxAmount"$;
  - the eight bytes at offsets 2 to 9 of the output 0 script, read as a
    little-endian `uint64` and reinterpreted as `int64`, #MUST equal `ValueIn`;
  - the sum of all its output values #MUSTNOT exceed `ValueIn`. The
    difference is the fee.
] <rule:treasury-tspend-amounts>

#rule("Treasury spend sequence number", src: ("internal/blockchain/sequencelock.go · calcSequenceLock", "internal/blockchain/validate.go · checkConnectBlock"))[
  If the `lnfeatures` agenda (relative lock times, #chref("transactions")) is
  active for the block, bit 31 (0x80000000, `SequenceLockTimeDisabled`) of the
  `Sequence` field of a treasury spend's input #MUST be set.
] <rule:treasury-tspend-sequence>

#pitfall[
  @rule:treasury-tspend-sequence is not stated in #dcp(6). It follows from the
  general relative lock-time rule. That rule is evaluated for every stake
  transaction of version 2 or higher that is neither a coinbase nor a vote, and
  for each input without the disable bit it looks up the referenced output. A
  treasury spend is not a coinbase (@rule:treasury-coinbase-detect) and its
  input references the null outpoint, which never exists, so the block is
  rejected (dcrd reports `ErrMissingTxOut`). The behaviour was confirmed by
  running dcrd with a treasury spend whose sequence number is 0. The treasurybase
  is a coinbase under @rule:treasury-coinbase-detect and is exempt. On the main
  network `lnfeatures` became active long before `treasury`, so the rule applies
  to every treasury spend there. dcrd's memory pool does not evaluate sequence
  locks for treasury spends (policy), so it may accept treasury spends that no
  block may contain.
]

=== Inclusion in a block <sec:treasury-tspend-inclusion>

The following rules restrict where a treasury spend may appear. They
reference the voting window and vote tally defined in @sec:treasury-votes and
the expenditure check of @sec:treasury-policy.

#rule("Treasury spends only on a TVI", src: "internal/blockchain/validate.go · checkBlockContext")[
  If the agenda is active for a block at height $H > 1$ and $H mod "TVI" != 0$,
  the block #MUSTNOT contain any treasury spend.
] <rule:treasury-tspend-tvi>

#rule("Full voting window after stake validation height", src: "internal/blockchain/validate.go · checkBlockContext")[
  If the agenda is active for a block at height $H > 1$ with
  $H mod "TVI" = 0$, every treasury spend in the block #MUST have
  $"Expiry" >= 2 + "SVH" + "TVI" dot "TVIM"$ (compared as unsigned 64-bit
  integers), so that its voting window starts at or after stake validation
  height.
] <rule:treasury-tspend-full-window>

#rule("Treasury spend inside its window", src: ("internal/blockchain/validate.go · tspendChecks", "blockchain/standalone/treasury.go · InsideTSpendWindow"))[
  Every treasury spend in a block at height $H$ #MUST have a valid expiry
  (@rule:treasury-expiry) and #MUST satisfy $"start" <= H <= "end"$, where
  $("start", "end")$ is its voting window and the comparison is on the
  `uint32` value of $H$.
] <rule:treasury-tspend-window>

#rule("Treasury spend not previously mined", src: ("internal/blockchain/validate.go · tspendChecks", "internal/blockchain/treasury.go · checkTSpendExists"))[
  A block #MUSTNOT contain a treasury spend whose transaction hash equals that
  of a treasury spend contained in any of the block's ancestors. Within a
  single block the general rule against duplicate transactions applies
  (#chref("blocks")).
] <rule:treasury-tspend-unique>

#rule("Treasury spend approved", src: ("internal/blockchain/validate.go · tspendChecks", "internal/blockchain/treasury.go · checkTSpendHasVotes"))[
  Every treasury spend in a block #MUST pass the vote check of
  @alg:treasury-approval for that block.
] <rule:treasury-tspend-votes>

#rule("Treasury expenditure", src: ("internal/blockchain/validate.go · tspendChecks", "internal/blockchain/treasury.go · checkTSpendsExpenditure"))[
  For a block at height $H$ with $H mod "TVI" = 0$ for which the agenda is
  active, let $T$ be the sum of the `ValueIn` of all treasury spends in the
  block (as `int64`; the block is invalid if the sum overflows). If $T > 0$, the
  block #MUST pass @alg:treasury-expenditure-check.
] <rule:treasury-expenditure>

A treasury spend has no inputs to spend, so connecting it adds its outputs to
the set of unspent outputs and marks nothing spent. Output 0 is a null-data
script and is never added, and neither is a payout of value zero
(#chref("transactions")).

#rule("Maturity of treasury payouts", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  If the agenda is active for a block, an input in it that spends an output
  whose script is `OP_TGEN`-tagged (script version 0, first byte 0xc3, followed
  by a P2PKH or P2SH script) #MUST satisfy
  $h_"spend" - h_"origin" >= "CM"$, where $h_"spend"$ is the height of the
  spending block and $h_"origin"$ the height of the block containing the
  treasury spend.
] <rule:treasury-tgen-maturity>

Because a treasury spend always has a nonzero `Expiry`, its outputs are also
subject to the general rule that outputs of transactions with an expiry
require #param("CoinbaseMaturity") confirmations (#chref("transactions")),
which imposes the same bound.

#vector[Signed treasury spend (simnet)][
  Simnet Pi key 0, private key
  #hex("62deae1ab2b1ebd96a28c80e870aee325bed359e83d8db2464ef999e616a9eef"),
  public key #hex("02a36b785d584555696b69d1b2bbeff4010332b301e3edd316d79438554cacb3e7").
  One payout of 10000000000 atoms to the P2PKH hash `11`$times$20, fee 10000,
  so `ValueIn` = 10000010000. The arbitrary bytes of output 0 are `00 01 ... 17`.
  Expiry 1154 (computed for a next block height of 1000 on simnet: window
  [1008, 1152]). Sequence 0xffffffff, lock time 0.

  Unsigned serialization (empty signature script):
  #hex("03000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff0200000000000000000000226a20100b0c5402000000000102030405060708090a0b0c0d0e0f101112131415161700e40b540200000000001ac376a914111111111111111111111111111111111111111188ac000000008204000001100b0c540200000000000000ffffffff00")

  Signature hash (`SigHashAll`, input 0, empty subscript):
  #hex("49e42bae2fc61c807b3f3e8dd9cc67b3fdc04bc9da01084731c97d256e0dae8d")

  Signature ($r || s$, deterministic):
  #hex("bdf258f7e1441340a762bac301884a2237b1b05c3e26a58487258e6c360f1bdc7ee535af48c50bbb1f59a61c09fc0024c578b41ec2e1e61aca7c08f704671780")

  Signed serialization:
  #hex("03000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff0200000000000000000000226a20100b0c5402000000000102030405060708090a0b0c0d0e0f101112131415161700e40b540200000000001ac376a914111111111111111111111111111111111111111188ac000000008204000001100b0c540200000000000000ffffffff6440bdf258f7e1441340a762bac301884a2237b1b05c3e26a58487258e6c360f1bdc7ee535af48c50bbb1f59a61c09fc0024c578b41ec2e1e61aca7c08f7046717802102a36b785d584555696b69d1b2bbeff4010332b301e3edd316d79438554cacb3e7c2")

  Transaction hash (display form):
  #hex("8dfae941b11684372a19d55c100ef79c130ab7676b8cd546f89664e7b0b2a6ea")

  Decreasing the payout value by one atom without re-signing makes verification
  fail.
]

== Treasury Spend Voting <sec:treasury-votes>

=== The voting window <sec:treasury-window>

A treasury spend carries no explicit window. The window is derived from its
`Expiry` field, which therefore has a restricted form: it must be exactly two
more than a nonzero multiple of TVI and large enough for a whole window to fit
above height zero.

#rule("Treasury spend expiry and window", src: "blockchain/standalone/treasury.go · CalcTSpendWindow")[
  The expiry $e$ (a `uint32`) of a treasury spend is valid if and only if
  $e >= "TVI" dot "TVIM" + 2$ and $(e - 2) mod "TVI" = 0$. The voting window
  of a treasury spend with a valid expiry is the pair
  $ "start" = e - "TVI" dot "TVIM" - 2, quad "end" = e - 2. $
  A treasury spend with an invalid expiry is outside every window and can never
  be included in a block.
] <rule:treasury-expiry>

Both bounds are multiples of TVI, and $"end" - "start" = "TVI" dot "TVIM"$.
The window is used in two different ways:

- *Votes* are counted from blocks at heights $"start"$ through $H - 1$, where
  $H <= "end"$ is the height of the block that includes the spend. Votes in a
  block at height $"end"$ or above can never count, so for voting the window is
  the half-open interval $["start", "end")$.
- *Inclusion* is allowed in TVI blocks at heights $"start" <= H <= "end"$, an
  interval closed at both ends. Since no votes have been counted at
  $H = "start"$ and the quorum is positive on every network, a spend can never
  be included at $H = "start"$. Even if every ticket votes yes, the earliest
  inclusion is at the first TVI $H$ with
  $"TPB" dot (H - "start") >= floor("TPB" dot "TVI" dot "TVIM" dot "TVRM" / "TVRD")$
  ($"start" + 2304$ on the main network, see @alg:treasury-approval).

The `+ 2` exists because of transaction expiry. A transaction is invalid in a
block at height $h$ when $"Expiry" != 0$ and $h >= "Expiry"$
(#chref("transactions")), and the memory pool removes transactions one block
early. With $"end" = e - 2$, a spend remains valid, and in the memory pool, at
its last possible inclusion height. The general expiry rule never rejects a
treasury spend that satisfies @rule:treasury-tspend-window, since then
$H <= e - 2 < e$.

Wallets and the Pi key holders compute the expiry for a new spend from the
height of the next block $n$ as in @alg:treasury-expiry. Nothing requires this
choice; it yields the earliest window that starts strictly after $n$.

#algorithm("Window computation and conventional expiry", src: ("blockchain/standalone/treasury.go · CalcTSpendWindow", "blockchain/standalone/treasury.go · CalcTSpendExpiry", "blockchain/standalone/treasury.go · InsideTSpendWindow"))[
  ```python
  def tspend_window(expiry: uint32) -> tuple[uint32, uint32] | None:
      if expiry < TVI * TVIM + 2:
          return None                                  # invalid expiry
      if (expiry - 2) % TVI != 0:                     # expiry - 2 > 0 here
          return None
      return expiry - TVI * TVIM - 2, expiry - 2      # (start, end)

  def inside_tspend_window(height: int64, expiry: uint32) -> bool:
      w = tspend_window(expiry)
      if w is None:
          return False
      start, end = w
      return start <= uint32(height) <= end

  # Non-normative: the expiry chosen by wallets for a spend created when the
  # next block will be at height n (n >= 0).
  def tspend_expiry(n: int) -> uint32:
      next_tvi = n + (TVI - n % TVI)                  # strictly greater than n
      return uint32(next_tvi + TVI * TVIM + 2)
  ```
] <alg:treasury-expiry>

#vector[Voting windows (main network: TVI 288, TVIM 12)][
  ```
  next height n   expiry    start     end       note
  1052415         1056098   1052640   1056096
  1052416         1056098   1052640   1056096   (activation block of DCP-0013)
  1052640         1056386   1052928   1056384   n is itself a TVI

  expiry 3457     invalid   (below TVI*TVIM + 2 = 3458)
  expiry 3458     start 0, end 3456
  expiry 3459     invalid   (3457 not a multiple of 288)
  expiry 1056097  invalid;  expiry 1056096  invalid

  inside(h, expiry 1056098): h=1052640 true, 1052641 true, 1056096 true, 1056097 false
  ```
]

=== The treasury vote output <sec:treasury-vote-output>

A ticket holder votes on treasury spends through the vote transaction it
already casts when its ticket is selected (#chref("staking")). With the
`treasury` agenda, a vote transaction may end with one extra null-data output
that lists (treasury spend hash, vote) pairs. #chref("staking") specifies the
rest of the vote format and refers here for this output: its vote predicate
calls `parse_treasury_votes` of @alg:treasury-vote-parse. In a vote with only
two outputs the last output is the vote bits output itself, so that output is
then the one parsed (#chref("staking")).

#figure(
  caption: [Treasury vote output (last output of a vote)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Offset], [Bytes], [Content]),
    [0], [1], [`0x6a` (`OP_RETURN`)],
    [1], [1 or 2], [Push opcode: `OP_DATA_N` with $N = 2 + 33k <= 75$ (so $k <= 2$), or `0x4c` (`OP_PUSHDATA1`) followed by a length byte $L = 2 + 33k <= 255$ (so $k <= 7$).],
    [$p$], [2], [Discriminator `54 56` (ASCII `TV`), where $p$ = 2 for `OP_DATA_N` and 3 for `OP_PUSHDATA1`.],
    [$p + 2 + 33i$], [32], [Hash of the $i$-th treasury spend voted on, in internal byte order (not reversed).],
    [$p + 34 + 33i$], [1], [Vote: `0x01` yes or `0x02` no.],
  ),
) <tab:treasury-vote-output>

#algorithm("Treasury vote output parsing", src: ("blockchain/stake/staketx.go · CheckSSGenVotes", "blockchain/stake/staketx.go · GetSSGenTreasuryVotes", "blockchain/stake/staketx.go · IsNullDataScript"))[
  ```python
  def is_null_data(out) -> bool:
      # Script version 0 and: OP_RETURN alone, or OP_RETURN followed by
      # exactly one push (OP_0, OP_1..OP_16, OP_DATA_1..OP_DATA_75,
      # OP_PUSHDATA1/2/4) that consumes the
      # rest of the script and pushes at most 256 bytes. Non-canonical pushes
      # are allowed. Parsing is as in the script chapter.
      ...

  def parse_treasury_votes(s: bytes) -> list[tuple[bytes, int]]:
      # s is a script already known to be null data
      if len(s) < 4 or s[1] > 0x4c:                   # beyond OP_PUSHDATA1
          reject("ErrSSGenInvalidDiscriminatorLength")
      p = 3 if s[1] == 0x4c else 2
      if p + 2 > len(s):
          reject("ErrSSGenInvalidNullScript")
      if s[p:p+2] != b"TV":                           # 0x54 0x56
          reject("ErrSSGenUnknownDiscriminator")
      body = s[p+2:]
      if len(body) < 33 or len(body) % 33 != 0:
          reject("ErrSSGenInvalidTVLength")
      votes, seen = [], set()
      for i in range(0, len(body), 33):
          h, v = body[i:i+32], body[i+32]
          if v not in (0x01, 0x02):                   # 0x01 yes, 0x02 no
              reject("ErrSSGenInvalidTreasuryVote")
          if h in seen:                               # no duplicate tspend
              reject("ErrSSGenDuplicateTreasuryVote")
          seen.add(h)
          votes.append((h, v))
      return votes

  def treasury_votes(vote_tx) -> list[tuple[bytes, int]]:
      last = vote_tx.outputs[-1]
      if not is_null_data(last):
          return []                                   # no treasury vote output
      votes = parse_treasury_votes(last.pk_script)
      if vote_tx.version != 3:                        # TxVersionTreasury
          reject("ErrSSGenInvalidTxVersion")
      return votes
  ```
] <alg:treasury-vote-parse>

#rule("Treasury vote output", src: ("blockchain/stake/staketx.go · CheckSSGenVotes", "blockchain/stake/staketx.go · GetSSGenTreasuryVotes"))[
  If the last output of a vote transaction is a null-data script (as defined in
  @alg:treasury-vote-parse), the vote #MUST pass every check of
  @alg:treasury-vote-parse: the output #MUST be a well-formed treasury vote
  output listing at least one pair, every vote byte #MUST be 0x01 or 0x02, no
  treasury spend hash #MAY appear twice, and the vote transaction's version
  #MUST be 3. A transaction that fails these checks is not a vote at all; it is
  then classified as regular, and a block containing it in its stake tree is
  invalid because the stake tree may not contain regular transactions
  (#chref("blocks")).
] <rule:treasury-vote-output>

The number of pairs is limited only by the push encoding: at most 2 with
`OP_DATA_N` and at most 7 with `OP_PUSHDATA1`, since its length byte cannot
exceed 255 and pushes larger than `OP_PUSHDATA1` are rejected. No rule requires
a hash to identify an existing treasury spend: a vote may name any 32 bytes.
Pairs whose hash matches no includable spend are simply never counted. A vote
byte of 0x00 is invalid; to abstain, a voter omits the spend.

#pitfall[
  The treasury vote output counts toward the vote's limit of
  `MaxOutputsPerSSGen` = 66 outputs (#chref("staking")), which dcrd's source
  notes "should technically be increased by 1" but cannot be without a
  consensus vote. When the agenda is active the output is excluded from the
  count of payment outputs that must match the ticket's commitments. When the
  agenda is not active it is not excluded, so a vote carrying a treasury vote
  output then fails the payee checks of #chref("staking"). Treasury vote
  outputs are therefore effectively invalid before activation.
]

#vector[Treasury vote outputs][
  One yes vote for the treasury spend of the previous vector
  (`OP_RETURN OP_DATA_35 'T' 'V' <hash> 01`):
  #hex("6a235456eaa6b2b0e76496f846d58c6b67b70a139cf70e105cd5192a378416b141e9fa8d01")

  Note the internal byte order of the hash; its display form is
  #hex("8dfae941b11684372a19d55c100ef79c130ab7676b8cd546f89664e7b0b2a6ea").
  Three pairs (104-byte script, `OP_PUSHDATA1` with length 101) and seven pairs
  (236-byte script, length 233) both parse. The same hash listed twice fails
  with `ErrSSGenDuplicateTreasuryVote`; a vote byte of 0x03 fails with
  `ErrSSGenInvalidTreasuryVote`.
]

=== Tallying and approval <sec:treasury-tally>

The tally for a treasury spend $X$ considered for inclusion in block $B$ at
height $H$ counts every yes and no pair naming $X$'s hash in every vote
transaction in the stake trees of $B$'s ancestors at heights $"start"$ through
$H - 1$. Votes in $B$ itself are not counted. Each ticket votes at most once,
so no further deduplication is needed. Votes are counted by inclusion height,
regardless of maturity and regardless of whether the regular tree of the block
containing them was approved.

#algorithm("Treasury spend vote tally", src: "internal/blockchain/treasury.go · tSpendCountVotes")[
  ```python
  def tally(B, X) -> tuple[uint32, uint32, uint32, uint32]:
      w = tspend_window(X.expiry)
      if w is None:
          reject("ErrInvalidTSpendWindow")    # or ErrInvalidTreasurySpendExpiry
      start, end = w
      if not inside_tspend_window(B.height, X.expiry):
          reject("ErrInvalidTSpendWindow")
      yes: uint32 = 0
      no: uint32 = 0
      n = B.parent
      while n is not None and n.height >= start:
          for stx in n.stake_transactions:
              if not is_vote(stx):            # staking chapter's vote predicate
                  continue
              for (h, v) in treasury_votes(stx):
                  if h == txhash(X):
                      if v == 0x01: yes += 1  # overflow would reject the block
                      if v == 0x02: no += 1   # (unreachable in practice)
          n = n.parent
      return start, end, yes, no
  ```
] <alg:treasury-tally>

The approval test requires a quorum of all possible votes in the window and a
yes count of at least TVRM/TVRD of the votes already cast *plus all votes that
could still be cast* before the end of the window. Counting the remaining
votes as potential no votes lets a spend with an insurmountable yes majority be
approved at an earlier TVI ("short-circuiting"). There is no corresponding
early rejection in consensus. A spend that fails simply cannot be included, and
once its window has passed it can never be included.

#algorithm("Treasury spend approval", src: "internal/blockchain/treasury.go · checkTSpendHasVotes")[
  ```python
  def check_tspend_votes(B, X):
      start, end, yes, no = tally(B, X)
      max_votes = uint32(uint32(TPB) * (end - start))           # uint32 product
      quorum = uint64(max_votes) * TVQM // TVQD                 # uint64
      cast = uint64(uint32(yes + no))
      if cast < quorum:
          reject("ErrNotEnoughTSpendVotes")                     # quorum not met
      remaining_blocks = uint32(end - uint32(B.height))         # >= 0, see tally
      max_remaining = uint64(uint32(remaining_blocks * uint32(TPB)))
      required = (cast + max_remaining) * TVRM // TVRD           # uint64
      if uint64(yes) < required:
          reject("ErrNotEnoughTSpendVotes")                     # not enough yes votes
  ```
] <alg:treasury-approval>

In @alg:treasury-approval `remaining_blocks` is $"end" - H$, which is
non-negative because the tally has already checked $H <= "end"$. All products
fit easily in their types on every network. The widths are stated because dcrd
computes them that way.

#note[
  With the main-network values the threshold has a simple form when every
  ticket votes on the spend: $"cast" + "remaining" = 17280$, so the required
  number of yes votes is $floor(17280 dot 3 / 5) = 10368$, a constant. The
  earliest approval with unanimous yes votes from a window starting at height
  $s$ is at the first TVI $H$ with $5(H - s) >= 10368$, that is
  $H = s + 2304$ (8 TVIs).
]

#vector[Approval at each TVI of a main-network window][
  Expiry 7778, the smallest valid on the main network, window [4320, 7776].
  Votes per block in heights 4320 to 7775. Each entry gives the TVI block
  height and the counted yes/no votes, followed by "pass" or the reason for
  failure.
  ```
  5 yes per block
    4320  0/0      quorum            5184  4320/0    yes < 10368
    4608  1440/0   quorum            5760  7200/0    yes < 10368
    4896  2880/0   quorum            6336  10080/0   yes < 10368
                                     6624  11520/0   pass (and every later TVI)
  3 yes, 2 no per block
    6624  6912/4608   yes < 10368 (remaining 5760)
    7488  9504/6336   yes < 10368 (remaining 1440)
    7776  10368/6912  pass (exactly 60%)
  1 yes, 4 abstaining per block
    7488  3168/0   quorum (3456)    7776  3456/0   pass (quorum exactly; required 2073)
  as above but no vote at height 4320
    7776  3455/0   quorum
  ```
]

=== Summary of inclusion conditions <sec:treasury-inclusion-summary>

A treasury spend $X$ may be included in block $B$ at height $H$ exactly when
all of the following hold, in addition to the transaction rules of
@sec:treasury-tspend-rules and the general rules for stake transactions:

#figure(
  caption: [Conditions for including a treasury spend],
  table(
    columns: (1fr, auto),
    table.header([Condition], [Rule]),
    [The `treasury` agenda is active for $B$ and $H >= "SVH"$.], [@rule:treasury-inactive, @rule:treasury-early-stake],
    [$H mod "TVI" = 0$.], [@rule:treasury-tspend-tvi],
    [$X."Expiry" >= 2 + "SVH" + "TVI" dot "TVIM"$.], [@rule:treasury-tspend-full-window],
    [$X."Expiry"$ is valid and $"start" <= H <= "end"$.], [@rule:treasury-expiry, @rule:treasury-tspend-window],
    [$X$ is not in any ancestor of $B$.], [@rule:treasury-tspend-unique],
    [Quorum and yes threshold are met, counting votes in $["start", H - 1]$.], [@rule:treasury-tspend-votes],
    [The total of all spends in $B$ passes the balance and policy checks.], [@rule:treasury-expenditure],
  ),
) <tab:treasury-inclusion>

There is no consensus limit on the number of treasury spends in a block other
than the block size and signature operation limits. (The memory pool holds at
most seven, see @sec:treasury-policy-mempool.) A spend that is mined on one
chain may be mined again on a competing chain that does not contain it, since
@rule:treasury-tspend-unique considers only ancestors.

== Expenditure Policy <sec:treasury-policy>

Even an approved treasury spend may be included only if the treasury can
afford it and the total spent in the recent past stays below a limit. The limit
has had three definitions, each selected by an agenda. All three work on
*expenditure policy windows* of $W = "TVI" dot "TVIM" dot "TEW"$ consecutive
blocks counted backwards from the parent of the TVI block being validated, and
all three sum treasury values by *inclusion* height (the block containing the
transaction), not by maturity.

=== Common procedure <sec:treasury-policy-common>

#algorithm("Window sums", src: "internal/blockchain/treasury.go · sumPastTreasuryChanges")[
  ```python
  def window_sums(n, count: int) -> tuple[int64, int64, Block | None]:
      """Sums the treasury values of `count` blocks: n and its ancestors, newest
      first. Returns (spent, added, next older block or None)."""
      spent = added = 0
      for _ in range(count):
          if n is None:
              break
          if not treasury_active(n):       # no treasury values: stop for good
              n = None
              break
          for (kind, amount) in treasury_values(n):
              if is_debit(kind):
                  spent += -amount         # treasury spend payouts and fees
              else:
                  added += amount          # treasurybases and treasury adds
          n = n.parent
      return spent, added, n
  ```
] <alg:treasury-window-sums>

For each treasury spend, `spent` includes exactly its `ValueIn`. Since the
agenda never becomes inactive again, stopping at the first block without
treasury values is the same as letting all earlier blocks contribute nothing.

#algorithm("Expenditure check", src: ("internal/blockchain/treasury.go · checkTSpendsExpenditure", "internal/blockchain/treasury.go · maxTreasuryExpenditure"))[
  ```python
  def check_expenditure(B, total: int64):
      # B: a block at a TVI height for which the treasury agenda is active.
      # total: sum of ValueIn of all treasury spends in B (> 0).
      bal = treasury_balance(B)                  # balance as of B (rule above)
      if bal - total < 0:
          reject("ErrInvalidExpenditure")        # treasury may not go negative
      P = B.parent
      if agenda_active("maxtreasuryspend", B):          # DCP-0013
          allowed = max_spend_dcp0013(P)
      elif agenda_active("reverttreasurypolicy", B):    # DCP-0007
          allowed = max_spend_dcp0007(P)
      else:                                             # DCP-0006
          allowed = max_spend_dcp0006(P)
      if total > allowed:
          reject("ErrInvalidExpenditure")
  ```
] <alg:treasury-expenditure-check>

The policy is selected by the agendas active for $B$ (asked of $P$ in dcrd's
terms), with `maxtreasuryspend` taking precedence over `reverttreasurypolicy`
regardless of whether the latter is active. In every policy the recent window
covers heights $H - W$ through $H - 1$ for a TVI block at height $H$.

=== The original policy (DCP-0006) <sec:treasury-policy-dcp6>

The original policy limits the spends in the recent window to 150% of the
average spending of the TEP preceding windows, ignoring windows without any
spending. When none of them has spending, the bootstrap value TEB is used as
the average.

#algorithm("Maximum expenditure, DCP-0006", src: "internal/blockchain/treasury.go · maxTreasuryExpenditureDCP0006")[
  ```python
  def max_spend_dcp0006(P) -> int64:
      W = TVI * TVIM * TEW
      spent_recent, _, n = window_sums(P, W)          # heights H-W .. H-1
      prior_total = 0
      nonempty = 0
      # iteration i = 0..TEP-1 covers heights H-(i+2)W .. H-(i+1)W-1
      for _ in range(TEP):
          if n is None:
              break
          spent, _, n = window_sums(n, W)
          if spent > 0:
              prior_total += spent
              nonempty += 1
      if nonempty > 0:
          avg = prior_total // nonempty
      else:
          avg = TEB
      allowance = avg + avg // 2
      return allowance - spent_recent if allowance > spent_recent else 0
  ```
] <alg:treasury-dcp6>

#history[
  The DCP-0006 policy bases the limit on past spending rather than on income,
  unlike the policy in the original Politeia proposal for the decentralized
  treasury, and according to #dcp(7) it prevented payments from the treasury
  from being made. The `reverttreasurypolicy` agenda replaced it. On the main network it
  governs TVI blocks from 552448 up to but not including 657280.
]

=== The reverted policy (DCP-0007) <sec:treasury-policy-dcp7>

The `reverttreasurypolicy` agenda (#dcp(7) @dcp0007) limits spends in the
recent window to 150% of the treasury's income (treasurybases and treasury
adds) in the same window.

#algorithm("Maximum expenditure, DCP-0007", src: "internal/blockchain/treasury.go · maxTreasuryExpenditureDCP0007")[
  ```python
  def max_spend_dcp0007(P) -> int64:
      W = TVI * TVIM * TEW
      spent, added, _ = window_sums(P, W)             # heights H-W .. H-1
      allowance = added + added // 2
      return allowance - spent if allowance > spent else 0
  ```
] <alg:treasury-dcp7>

=== The balance-based policy (DCP-0013) <sec:treasury-policy-dcp13>

The `maxtreasuryspend` agenda (#dcp(13) @dcp0013) limits the spends in a policy
window to 4% of the balance the treasury would have had without those spends,
but never less than a fixed floor and never more than the balance itself. The
floor is the treasury subsidy of one voting window at the initial,
unreduced subsidy rate. It adds no network parameter: the floor is computed from
#param("BaseSubsidy"), TVI and TVIM.

$ F = floor("BaseSubsidy" / 10) dot "TVI" dot "TVIM" $ <eq:treasury-floor>

#algorithm("Maximum expenditure, DCP-0013", src: ("internal/blockchain/treasury.go · maxTreasuryExpenditureDCP0013", "internal/blockchain/chain.go · New"))[
  ```python
  FLOOR = (BaseSubsidy // 10) * (TVI * TVIM)      # 1078127767296 on mainnet

  def max_spend_dcp0013(P) -> int64:
      W = TVI * TVIM * TEW
      spent, _, _ = window_sums(P, W)                 # heights H-W .. H-1
      bal = treasury_balance(child_of(P))             # balance as of the TVI block
      max_spendable = (bal + spent) * 4 // 100        # int64; operands non-negative
      if max_spendable < FLOOR:
          max_spendable = FLOOR
      allowed = max_spendable - spent if max_spendable > spent else 0
      if allowed > bal:
          allowed = bal
      return allowed
  ```
] <alg:treasury-dcp13>

`child_of(P)` is the TVI block being validated, so `bal` is the same balance
used by the non-negativity check of @alg:treasury-expenditure-check. Adding
`spent` back approximates the balance before the window's spends. It is exact
only if those spends have already matured, which on the main network holds for
spends in all earlier TVI blocks. The division by 10 in the floor is part of
the definition. It is not tied to the treasury proportion of the subsidy.

#history[
  Under DCP-0007 the limit shrinks with the block subsidy and would eventually
  leave most of the accumulated balance unspendable. DCP-0013 targets a maximum
  loss of about 20% of the treasury in the event of a key compromise (five
  policy windows of 4% each during the roughly four months a consensus change
  takes) while the floor keeps the limit stable over the emission schedule. On
  the main network the DCP-0013 policy governs TVI blocks from 1052416 on.
]

=== Test vectors <sec:treasury-policy-vectors>

The three policy functions were evaluated by dcrd's own code on synthetic
main-network treasury states: every block from height 2 is given a
treasurybase of $10^8$ atoms (the agenda is never active for block 1,
@sec:treasury-activation). The round amount stands in for the subsidy
schedule; the vectors exercise the policy arithmetic only. The block being validated is
the TVI block at height 48384 (the parent is at 48383). The windows are
therefore: recent $[41472, 48383]$, and prior windows $[34560, 41471]$,
$[27648, 34559]$, $[20736, 27647]$, $[13824, 20735]$, $[6912, 13823]$ and
$[0, 6911]$. Each treasury spend below has a fee of 10000 atoms included in the
stated `ValueIn`.

#vector[Expenditure limits for the TVI block at height 48384][
  ```
  S0: no treasury spends or adds.
      balance 4812700000000 (48127 tbases), recent spent 0, added 691200000000
      DCP-0006  2400000000000   (bootstrap: 16000 DCR * 1.5)
      DCP-0007  1036800000000   (6912 DCR * 1.5)
      DCP-0013  1078127767296   (4% of balance below floor; floor < balance)

  S1: spends with ValueIn 12000 DCR at 20160, 9000 DCR at 34560, 5000 DCR at 43200;
      treasury add 500 DCR at 45000.
      balance 2262700000000, recent spent 500000000000, added 741200000000
      DCP-0006  1075000000000   (avg of 2 non-empty windows 10500 DCR; 15750 - 5000)
      DCP-0007  611800000000    (7412 * 1.5 = 11118 DCR; minus 5000)
      DCP-0013  578127767296    (floor - 5000 DCR)

  S2: as S1 plus a treasury add of 1000000 DCR at height 1000.
      balance 102262700000000, recent spent 500000000000
      DCP-0006  1075000000000,  DCP-0007  611800000000 (unchanged)
      DCP-0013  3610508000000   ((1022627 + 5000) * 4% = 41105.08 DCR; minus 5000)
  ```
  A block at height 48384 whose treasury spends total exactly the stated limit
  passes the policy check, and one atom more fails it.
]

== Interactions with Other Rules <sec:treasury-interactions>

=== Signature operations <sec:treasury-sigops>

The signature operation limits of #chref("blocks") apply to treasury
transactions with the following treasury-specific counting, specified in full
in #chref("script"):

#rule("Signature operations of treasury transactions", src: ("internal/blockchain/validate.go · countSigOps", "internal/blockchain/validate.go · countP2SHSigOps", "txscript/script.go · countSigOpsV0"))[
  When the agenda is active: a treasurybase counts zero signature operations;
  each `OP_TSPEND` in a script counts one signature operation (so the input of a
  treasury spend counts one); outputs are counted as for any transaction (an
  `OP_TGEN`-tagged P2PKH output counts one for its `OP_CHECKSIG`; an
  `OP_TGEN`-tagged P2SH output counts zero); and treasury spends and
  treasurybases contribute no pay-to-script-hash signature operations. A
  treasury add is counted like any other transaction.
] <rule:treasury-sigops>

Treasury transactions count toward the block size like any other transaction.
There is no separate size limit.

=== Regular transactions and treasury opcodes <sec:treasury-regular>

#rule("No treasury opcodes in regular outputs", src: ("internal/blockchain/validate.go · checkTransactionContext", "txscript/script.go · ContainsStakeOpCodes"))[
  When the agenda is active for a block, no output script of a transaction
  classified as regular #MAY contain any of the opcodes 0xc1, 0xc2 or 0xc3, in
  addition to the stake opcodes 0xba to 0xbd that are always forbidden there
  (#chref("transactions")). Scripts are parsed as in #chref("script"). A parse
  failure rejects the block.
] <rule:treasury-regular-opcodes>

When the agenda is active, scripts are executed with the treasury script flag,
under which 0xc1 to 0xc3 are the treasury opcodes rather than unknown opcodes
reserved for upgrades. Their execution semantics, and the handling of
`OP_TGEN`-tagged scripts when their outputs are spent, belong to
#chref("script").

=== Maturity of vote and revocation outputs <sec:treasury-stake-maturity>

When the `treasury` agenda is active for the spending block, an output whose
script is tagged with `OP_SSGEN` or `OP_SSRTX` matures after
#param("CoinbaseMaturity") blocks instead of #param("SStxChangeMaturity"). The
rule is @rule:staking-stake-output-maturity.

#note[
  This change is not mentioned in #dcp(6) but is part of the code that
  implements it. On the main network it raised the maturity of vote and
  revocation outputs from 1 to 256 blocks.
]

=== Other interactions <sec:treasury-other>

- *Disapproval.* A treasurybase, treasury add or treasury spend is never undone
  by disapproval of its block's regular tree. Treasury adds may spend outputs
  of the parent's regular tree like any stake transaction; if the parent is
  disapproved, those outputs do not exist and the treasury add is invalid
  (#chref("blocks")).
- *Fees.* The fees of treasury adds and treasury spends are stake-tree fees
  available to the coinbase. The treasurybase has no fee.
- *Header commitments.* The version 2 compact filters committed to by the
  block header include the payout scripts of treasury spends, the previous
  output scripts spent by treasury adds and the change scripts of treasury adds
  (#chref("filters")).

=== Memory pool and mining policy (non-normative) <sec:treasury-policy-mempool>

The following is dcrd policy, not consensus:

- A treasurybase is never accepted into the memory pool.
- A treasury spend is accepted only if the treasury agenda is active, the next
  block is at or above stake validation height, its expiry is valid, its voting
  window does not start $2 dot "TVI" dot "TVIM"$ or more blocks after the next
  block, its Pi key is known and its signature valid, and it has not been mined
  in an ancestor of the current tip. The memory pool holds at most seven
  treasury spends at a time (`MempoolMaxConcurrentTSpends`), matching the
  maximum number of pairs in one treasury vote output.
- Treasury adds and treasury spends must pay at least the minimum relay fee.
- Voting wallets append treasury votes for the spends in their memory pool
  according to their configured policy.
- The block template generator includes, in TVI blocks, those treasury spends
  that pass the vote check, subject to the maximum expenditure for the block.
  It creates the treasurybase with random bytes after the height.

== Error Kinds <sec:treasury-errors>

@tab:treasury-errors maps the error kinds that dcrd reports for violations of
the rules in this chapter to the rules. It is informative: only validity
matters for consensus, not which error is reported.

#figure(
  caption: [dcrd error kinds and the rules they correspond to],
  table(
    columns: (1fr, auto),
    table.header([Error kind], [Rule]),
    [`ErrStakeTxInRegularTree`, `ErrNonstandardStakeTx`, `ErrInvalidEarlyStakeTx`], [@rule:treasury-stake-tree-only, @rule:treasury-inactive, @rule:treasury-early-stake],
    [`ErrFirstTxNotTreasurybase`, `ErrMultipleTreasurybases`], [@rule:treasury-tbase-position, @rule:treasury-tbase-height],
    [`ErrTreasuryBaseInvalid*` (stake), `ErrBadTreasurybaseOutpoint`, `ErrBadTreasurybaseFraudProof`, `ErrBadTreasurybaseScriptLen`], [@rule:treasury-tbase-form],
    [`ErrTreasurybaseTxNotOpReturn`, `ErrTreasurybaseHeight`], [@rule:treasury-tbase-height],
    [`ErrInvalidTreasurybaseTxOutputs`, `ErrInvalidTreasurybaseVersion`, `ErrInvalidTreasurybaseScript`, `ErrTreasurybaseOutValue`, `ErrBadTreasurybaseAmountIn`, `ErrSpendTooHigh`], [@rule:treasury-tbase-amount],
    [`ErrTAddInvalid*` (stake)], [@alg:treasury-tadd-structure (classification)],
    [`ErrInvalidTAddChange`], [@rule:treasury-tadd-change],
    [`ErrTooManyTAdds`], [@rule:treasury-tadd-limit],
    [`ErrBadTxInput` (spending an `OP_TADD` output)], [@rule:treasury-tadd-unspendable],
    [`ErrTSpendInvalid*` (stake)], [@alg:treasury-tspend-structure (classification)],
    [`ErrBadTSpendOutpoint`, `ErrBadTSpendFraudProof`, `ErrBadTSpendScriptLen`], [@rule:treasury-tspend-input],
    [`ErrUnknownPiKey`], [@rule:treasury-tspend-pikey],
    [`ErrInvalidPiSignature`], [@rule:treasury-tspend-sig],
    [`ErrBadTxInput`, `ErrInvalidTSpendValueIn`, `ErrSpendTooHigh`], [@rule:treasury-tspend-amounts],
    [`ErrMissingTxOut` (sequence lock)], [@rule:treasury-tspend-sequence],
    [`ErrNotTVI`], [@rule:treasury-tspend-tvi],
    [`ErrInvalidTVoteWindow`], [@rule:treasury-tspend-full-window],
    [`ErrInvalidTSpendWindow`, `ErrInvalidTreasurySpendExpiry`], [@rule:treasury-expiry, @rule:treasury-tspend-window],
    [`ErrTSpendExists`], [@rule:treasury-tspend-unique],
    [`ErrNotEnoughTSpendVotes`, `ErrTooManyTreasurySpendVotes` (surfaced by block validation as `ErrNotEnoughTSpendVotes`)], [@rule:treasury-tspend-votes],
    [`ErrInvalidExpenditure`, `ErrBadTxOutValue` (sum overflow)], [@rule:treasury-expenditure],
    [`ErrImmatureSpend`, `ErrExpiryTxSpentEarly`], [@rule:treasury-tgen-maturity, @rule:staking-stake-output-maturity],
    [`ErrSSGenInvalidDiscriminatorLength`, `ErrSSGenInvalidNullScript`, `ErrSSGenUnknownDiscriminator`, `ErrSSGenInvalidTVLength`, `ErrSSGenInvalidTreasuryVote`, `ErrSSGenDuplicateTreasuryVote`, `ErrSSGenInvalidTxVersion`], [@rule:treasury-vote-output],
    [`ErrRegTxCreateStakeOut`, `ErrScriptMalformed`], [@rule:treasury-regular-opcodes],
    [`ErrTooManySigOps`], [@rule:treasury-sigops],
  ),
) <tab:treasury-errors>
