#import "../template.typ": *

= The Stake System <ch:staking>

Decred's proof-of-stake layer lets holders of the currency lock funds in
*tickets*. Every block draws a small set of tickets at random from the pool of
live tickets; the holders of the drawn tickets publish *votes* that approve or
disapprove the regular transactions of the block they vote on and express
preferences on proposed rule changes. The next block is only valid if it
carries votes from a majority of the drawn tickets. A ticket that is drawn but
whose vote is not included is *missed*; a ticket that is never drawn
eventually *expires*. The locked funds of missed and expired tickets are
returned by a *revocation*.

This chapter specifies the three stake transaction types (ticket purchase,
vote and revocation) byte for byte, the rules that tie their amounts to one
another, the ticket database that every node maintains, the lottery that draws
the winning tickets, and every block-level rule whose subject is a ticket, a
vote or a revocation. Several neighboring subjects are specified elsewhere
and only summarized here: the ticket price algorithm (stake difficulty) in
#chref("difficulty")\; the value of the vote subsidy in #chref("subsidy")\; the
treasury transactions that also live in the stake tree in #chref("treasury")\;
the meaning of the vote bits other than bit 0, and the vote version, in
#chref("voting")\; the consequences of a disapproved block for its regular
transactions in #chref("blocks")\; the general transaction rules (sanity,
fraud proofs, script execution, fees) in #chref("transactions") and
#chref("script").

== Overview <sec:staking-overview>

=== Terminology <sec:staking-terms>

/ Stake tree: The second of the two transaction lists of a block (the first is
  the *regular tree*). Every ticket purchase, vote and revocation, and every
  treasury transaction, is in the stake tree; no other transaction may be
  (@rule:staking-tree-membership).
/ Ticket: A *ticket purchase transaction* (dcrd: _SStx_, "stake submission").
  Its first output locks the *ticket price* under a script tagged
  `OP_SSTX`. The ticket is identified by its transaction hash.
/ Stake difficulty: The minimum ticket price, carried in the `SBits` field of
  the block header and computed by the algorithm of #chref("difficulty").
/ Commitment: An `OP_RETURN` output of a ticket that names, for one funding
  input, the hash of the address that will receive that input's share of the
  ticket's eventual return, the amount contributed, and optional fee limits
  (@sec:staking-commitment).
/ Immature ticket: A ticket that has been mined but has not yet entered the
  live ticket pool.
/ Live ticket: A ticket in the *live ticket pool*, eligible to be drawn.
/ Winner: One of the #param("TicketsPerBlock") tickets drawn by the lottery
  run on block $N$; the winners of block $N$ are the only tickets that may vote
  in block $N + 1$, and their votes are votes _on_ block $N$.
/ Vote: A *vote transaction* (dcrd: _SSGen_, "stake generation") that spends a
  winning ticket, names the block it votes on, carries the vote bits, and pays
  the ticket price plus the *vote subsidy* to the ticket's commitments.
/ Stakebase: The first input of a vote. It spends nothing and introduces the
  vote subsidy, much as a coinbase introduces the proof-of-work subsidy.
/ Missed ticket: A winner whose vote is not included in the next block.
/ Expired ticket: A live ticket that was not drawn within #param("TicketExpiry")
  blocks of entering the pool.
/ Revocation: A *revocation transaction* (dcrd: _SSRtx_, "stake revocation")
  that spends a missed or expired ticket and returns the ticket price to the
  commitments.

=== Life of a ticket <sec:staking-life>

@tab:staking-timeline follows a ticket mined in the block at height $p$
through its life, using main-network parameter values. All heights are
consequences of rules stated later in this chapter, which are referenced in
the last column.

#figure(
  caption: [Timeline of a ticket mined at height $p$ (main network:
    #param("TicketMaturity") $= 256$, #param("TicketExpiry") $= 40960$)],
  table(
    columns: (auto, 1fr, auto),
    table.header([Height], [Event], [Reference]),
    [$p$], [Ticket purchase mined. The price is at least the stake difficulty
      in the header of block $p$.], [@rule:staking-ticket-price],
    [$p + 256$], [The ticket enters the live pool while block $p + 256$ is
      connected, provided $p + 256 >=$ #param("StakeEnabledHeight").],
      [@alg:staking-connect],
    [$p + 256$], [First lottery that can draw it: the lottery run on block
      $p + 256$ selects the winners for block $p + 257$.],
      [@alg:staking-connect],
    [$p + 257$], [Earliest block that can contain its vote.],
      [@rule:staking-spend-maturity],
    [$p + 257$], [Earliest block in which it can become missed (and, with
      #dcp(9) active, be revoked).], [@rule:staking-spend-maturity],
    [$p + 258$], [Earliest revocation of a missed ticket before #dcp(9).],
      [@rule:staking-spend-maturity],
    [$p + 256 + 40960$], [Last block in which it can vote. If it is not a
      winner for this block it expires while this block is connected.],
      [@alg:staking-connect],
  ),
) <tab:staking-timeline>

=== Parameters and constants <sec:staking-params>

@tab:staking-params lists the network parameters used in this chapter with
their main-network values; the values for the other networks are tabulated in
#chref("parameters"). @tab:staking-consts lists the network-independent
constants.

#figure(
  caption: [Stake parameters (main network)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Parameter], [Value], [Meaning]),
    [#param("TicketsPerBlock")], [5], [Winners drawn per block; maximum votes
      per block.],
    [#param("TicketMaturity")], [256], [Blocks between a ticket's purchase and
      its entry into the live pool.],
    [#param("TicketExpiry")], [40960], [Blocks a ticket may remain live before
      it expires.],
    [#param("StakeEnabledHeight")], [512], [First height at which tickets can
      enter the live pool and at which the ticket database processes votes,
      expiries and revocations.],
    [#param("StakeValidationHeight")], [4096], [First height that must contain
      votes; the lottery first runs on the block one below it.],
    [#param("MaxFreshStakePerBlock")], [20], [Maximum ticket purchases per
      block.],
    [#param("MinimumStakeDiff")], [200000000], [Absolute minimum ticket price
      in atoms (2 DCR).],
    [#param("StakeBaseSigScript")], [#hex("0000")], [Required signature script
      of every stakebase input.],
    [#param("SStxChangeMaturity")], [1], [Maturity of ticket change outputs
      (and of vote and revocation outputs before the treasury agenda).],
    [#param("CoinbaseMaturity")], [256], [Maturity of vote and revocation
      outputs once the treasury agenda is active.],
    [#param("TicketPoolSize")], [8192], [Not used by this chapter; used by the
      stake difficulty algorithm (#chref("difficulty")).],
  ),
) <tab:staking-params>

#note[
  #param("StakeBaseSigScript") differs between networks: it is `0000` on the
  main, test and simulation networks and `7357` on the regression test
  network. #param("TicketsPerBlock") (5), #param("MaxFreshStakePerBlock")
  (20) and #param("SStxChangeMaturity") (1) are the same on all four
  networks; every other parameter in @tab:staking-params differs from its
  main-network value on at least one other network; see
  #chref("parameters").
]

#figure(
  caption: [Network-independent constants],
  table(
    columns: (auto, auto, 1fr),
    table.header([Name], [Value], [Meaning]),
    [#const("MaxInputsPerSStx")], [64], [Maximum inputs of a ticket.],
    [#const("MaxOutputsPerSStx")], [129], [Maximum outputs of a ticket
      ($2 times 64 + 1$).],
    [#const("NumInputsPerSSGen")], [2], [Exact number of inputs of a vote.],
    [#const("MaxOutputsPerSSGen")], [66], [Maximum outputs of a vote
      ($64 + 2$), including any treasury vote output. A vote for a ticket
      with 64 commitments therefore has no room for that output and can
      never cast treasury votes.],
    [#const("NumInputsPerSSRtx")], [1], [Exact number of inputs of a
      revocation.],
    [#const("MaxOutputsPerSSRtx")], [64], [Maximum outputs of a revocation.],
    [#const("SStxPKHMinOutSize")], [32], [Minimum length of a commitment
      script.],
    [#const("SStxPKHMaxOutSize")], [77], [Maximum length of a commitment
      script.],
    [#const("SSGenBlockReferenceOutSize")], [38], [Exact length of a vote's
      block reference script.],
    [#const("SSGenVoteBitsOutputMinSize")], [4], [Minimum length of a vote's
      vote bits script.],
    [#const("SSGenVoteBitsOutputMaxSize")], [77], [Maximum length of a vote's
      vote bits script.],
    [#const("MaxDataCarrierSize")], [256], [Maximum data in a null data script
      (@rule:staking-nulldata).],
    [#const("TxVersionAutoRevocations")], [2], [Revocation version introduced
      by #dcp(9).],
    [#const("TxVersionTreasury")], [3], [Transaction version required for a
      vote that carries treasury votes.],
    [`maxRevocationsPerBlock`], [255], [Maximum revocations per block.],
    [`earlyVoteBitsValue`], [`0x0001`], [Required header vote bits below
      #param("StakeValidationHeight").],
    [`seedConst`], [#hex("243f6a8885a308d3")], [Constant appended to the
      lottery seed (the first 64 bits of the fractional part of $pi$).],
  ),
) <tab:staking-consts>

=== Rule changes affecting this chapter <sec:staking-agendas>

Several consensus votes changed the rules in this chapter. Each rule that
depends on one names the agenda; "the agenda is active" always means active
_for the block being validated_, as defined in #chref("voting") (dcrd
evaluates it on the block's parent).

#figure(
  caption: [Agendas that modify stake rules],
  table(
    columns: (auto, auto, 1fr),
    table.header([Agenda], [DCP], [Effect in this chapter]),
    [`treasury`], [#dcp(6)], [Votes may carry treasury spend votes in a final
      output (@sec:staking-tvote); the number of required vote payments
      excludes that output; vote and revocation outputs need
      #param("CoinbaseMaturity") instead of #param("SStxChangeMaturity")
      confirmations (@rule:staking-stake-output-maturity); treasury
      transactions join the stake tree.],
    [`autorevocations`], [#dcp(9)], [Revocations must be version 2, carry an
      empty signature script, pay zero fee and distribute the rounding
      remainder pseudorandomly; they skip script validation; tickets may be
      revoked in the block in which they become missed or expired; blocks must
      revoke every such ticket.],
    [`explicitverupgrades`], [#dcp(8)], [Caps the transaction version at 3
      (#chref("transactions")); this bounds the versions of stake
      transactions.],
    [`changesubsidysplit`, `changesubsidysplitr2`], [#dcp(10), #dcp(12)],
      [Change the vote subsidy value (#chref("subsidy")); the formulas of this
      chapter are unchanged.],
  ),
) <tab:staking-agendas>

== Classification and Common Script Forms <sec:staking-classification>

Whether a transaction is a ticket, a vote or a revocation is decided purely
from its own contents, by three structural predicates defined in
@sec:staking-ticket, @sec:staking-vote and @sec:staking-revocation. The
classification does not depend on the chain, on agenda state, or on the tree
in which the transaction appears. A transaction that fails a predicate is not
thereby invalid; it is simply not of that type. It will usually be invalid
for some other reason, for example because it is a regular transaction placed
in the stake tree (@rule:staking-tree-membership) or because it creates
stake-tagged outputs outside a stake transaction (#chref("transactions")).

#rule("Stake transaction type", src: "blockchain/stake/staketx.go · DetermineTxType")[
  The type of a transaction is the first of the following that applies:
  + _ticket_, if it satisfies the ticket predicate (@alg:staking-check-ticket);
  + _vote_, if it satisfies the vote predicate (@alg:staking-check-vote);
  + _revocation_, if it satisfies the revocation predicate
    (@alg:staking-check-revocation);
  + if its version is at least #const("TxVersionTreasury") $= 3$: _treasury
    add_, _treasury spend_ or _treasurybase_, by the predicates of
    #chref("treasury") in that order;
  + otherwise _regular_.
  The three stake predicates are mutually exclusive, so the order of the
  first three tests does not matter in practice.
] <rule:staking-classify>

=== Tagged scripts <sec:staking-tagged>

Every non-`OP_RETURN` output of a stake transaction is a pay-to-pubkey-hash
(P2PKH) or pay-to-script-hash (P2SH) script prefixed with one byte, a *stake
tag* opcode, that marks how it was created and therefore how it may be spent
(#chref("script") gives the opcodes no execution semantics beyond a no-op).

#figure(
  caption: [Stake tag opcodes and tagged script forms. $h$ is a 20-byte hash.],
  table(
    columns: (auto, auto, 1fr),
    table.header([Tag], [Byte], [Used for]),
    [`OP_SSTX`], [`0xba`], [Ticket output 0: the ticket price and the right to
      vote.],
    [`OP_SSGEN`], [`0xbb`], [Vote payment outputs.],
    [`OP_SSRTX`], [`0xbc`], [Revocation payment outputs.],
    [`OP_SSTXCHANGE`], [`0xbd`], [Ticket change outputs.],
    table.cell(colspan: 3)[Tagged P2PKH (26 bytes):
      $T || "76" || "a9" || "14" || h || "88" || "ac"$ #h(1em) Tagged P2SH (24
      bytes): $T || "a9" || "14" || h || "87"$],
  ),
) <tab:staking-tags>

#rule("Tagged script", src: "blockchain/stake/scripttype.go · isTaggedScript")[
  A public key script $s$ with script version $v$ is *tagged with* opcode $T$
  if and only if $v = 0$, $|s| >= 1$, $s[0] = T$, and $s[1:]$ is exactly one
  of the following, where $h$ is any 20 bytes:
  #block[
    #set par(justify: false)
    - a 25-byte P2PKH script `76 a9 14` $h$ `88 ac`, that is,
      `OP_DUP OP_HASH160 OP_DATA_20` $h$ `OP_EQUALVERIFY OP_CHECKSIG`;
    - a 23-byte P2SH script `a9 14` $h$ `87`, that is,
      `OP_HASH160 OP_DATA_20` $h$ `OP_EQUAL`.
  ]
  No other length or form is accepted.
] <rule:staking-tagged>

=== Null data scripts <sec:staking-nulldata>

#rule("Null data script", src: "blockchain/stake/staketx.go · IsNullDataScript")[
  A public key script $s$ with script version $v$ is a *null data script* if
  and only if $v = 0$, $s[0] = $ `0x6a` (`OP_RETURN`), and either $|s| = 1$, or
  $s[1:]$ parses as exactly one opcode that consumes all of $s[1:]$, where that
  opcode is one of `OP_0` (`0x00`), a direct push `OP_DATA_1`…`OP_DATA_75`
  (`0x01`–`0x4b`), `OP_PUSHDATA1`, `OP_PUSHDATA2` or `OP_PUSHDATA4`
  (`0x4c`–`0x4e`), or `OP_1`…`OP_16` (`0x51`–`0x60`), and the number of bytes it
  pushes is at most #const("MaxDataCarrierSize") $= 256$. A push whose length
  prefix or data runs past the end of the script does not parse. Pushes need
  not be minimally encoded. `OP_0` and `OP_1`…`OP_16` push no data bytes for the
  purpose of this length test.
] <rule:staking-nulldata>

== Ticket Purchase Transactions <sec:staking-ticket>

A ticket is funded by one or more inputs, possibly owned by different parties
(this is how stake pools and ticket splitting work). For each input $i$ the
ticket carries a pair of outputs: a *commitment* naming who receives input
$i$'s share when the ticket is later spent, and a *change* output returning
whatever part of input $i$ was not contributed. Output 0 holds the ticket
price; whoever can satisfy its script can vote with the ticket.

#figure(
  caption: [Layout of a ticket with $n$ inputs ($1 <= n <= 64$)],
  table(
    columns: (auto, 1fr),
    table.header([Position], [Content]),
    [Inputs $0 … n-1$], [Any outpoints (subject to @rule:staking-ticket-inputs).
      Input $i$ funds the commitment at output $2i + 1$.],
    [Output 0], [Ticket price. Script tagged `OP_SSTX` (voting rights).],
    [Output $2i + 1$], [Commitment for input $i$: a null data script with the
      30-byte payload of @tab:staking-commitment.],
    [Output $2i + 2$], [Change for input $i$. Script tagged `OP_SSTXCHANGE`. The
      value may be zero.],
  ),
) <tab:staking-ticket-layout>

=== The commitment output <sec:staking-commitment>

#fieldtable(
  caption: [Commitment output script (output $2i + 1$ of a ticket); offsets
    are into the public key script],
  ("[0]", "uint8", "1", [`0x6a` (`OP_RETURN`).]),
  ("[1]", "uint8", "1", [Push opcode `0x1e`…`0x4b` (`OP_DATA_30`…`OP_DATA_75`);
    equals $|s| - 2$.]),
  ("[2:22]", "bytes", "20", [Payment hash $h$: a public key hash (P2PKH) or a
    script hash (P2SH), selected by the flag in bit 63 of the next field.]),
  ("[22:30]", "uint64 LE", "8", [Encoded amount $a$. Bit 63 (the top bit of
    byte 29) is the P2SH flag; the committed amount is $a "AND" (2^63 - 1)$.]),
  ("[30:32]", "uint16 LE", "2", [Fee limits $f$ (@tab:staking-feelimits).]),
  ("[32:]", "bytes", "0–45", [Arbitrary, ignored.]),
) <tab:staking-commitment>

#figure(
  caption: [Bits of the 16-bit fee limits field $f$],
  table(
    columns: (auto, auto, 1fr),
    table.header([Bits], [Mask], [Meaning]),
    [0–5], [`0x003f`], [$k_"vote"$: base-2 logarithm of the fee limit for
      votes.],
    [6], [`0x0040`], [Vote fee limit flag. When clear, each vote output must
      pay exactly its computed amount.],
    [7], [`0x0080`], [Unused, ignored.],
    [8–13], [`0x3f00`], [$k_"rev"$: base-2 logarithm of the fee limit for
      revocations, $(f "AND" "0x3f00") >> 8$.],
    [14], [`0x4000`], [Revocation fee limit flag (ignored for revocations once
      #dcp(9) is active).],
    [15], [`0x8000`], [Unused, ignored.],
  ),
) <tab:staking-feelimits>

How the fee limits constrain votes and revocations is specified in
@rule:staking-payee-value.

=== Structure <sec:staking-ticket-structure>

#algorithm("Ticket predicate", src: "blockchain/stake/staketx.go · CheckSStx")[
  ```python
  OP_RETURN, OP_SSTX, OP_SSGEN, OP_SSRTX, OP_SSTXCHANGE = 0x6a, 0xba, 0xbb, 0xbc, 0xbd

  def is_ticket(tx) -> bool:
      if len(tx.inputs) > 64:                       # MaxInputsPerSStx
          return False
      if len(tx.outputs) > 129:                     # MaxOutputsPerSStx
          return False
      if len(tx.outputs) == 0:
          return False
      for out in tx.outputs:
          if out.script_version != 0:
              return False
      if not is_tagged(0, tx.outputs[0].script, OP_SSTX):
          return False
      if 2 * len(tx.inputs) + 1 != len(tx.outputs):
          return False
      for i in range(1, len(tx.outputs)):
          s = tx.outputs[i].script
          if i % 2 == 0:                            # change output
              if not is_tagged(0, s, OP_SSTXCHANGE):
                  return False
          else:                                     # commitment output
              if not is_null_data(0, s):
                  return False
              if len(s) < 32 or len(s) > 77:
                  return False
              if s[0] != OP_RETURN or not (0x1e <= s[1] <= 0x4b):
                  return False
      return True
  ```
] <alg:staking-check-ticket>

@alg:staking-check-ticket implies that a commitment script is exactly
$2 + m$ bytes with a direct push of $m in [30, 75]$ bytes, so the 30 bytes of
@tab:staking-commitment are always present. A transaction with no inputs is
excluded by the transaction sanity rules (#chref("transactions")), not by this
predicate.

#note[
  The value fields of commitment outputs are not constrained by any stake
  rule. They are ordinary, unspendable outputs: any value placed in them
  counts towards the ticket's total output value (and so reduces its fee) and
  is lost.
]

=== Inputs, commitments and price <sec:staking-ticket-inputs>

#rule("Ticket input script forms", src: "internal/blockchain/validate.go · checkTicketPurchaseInputs, isAllowedTicketInputScriptForm")[
  For every input of a ticket, the referenced output #MUST exist and be
  unspent, #MUST have script version 0, and its public key script #MUST be one
  of: an untagged P2PKH script (25 bytes) or untagged P2SH script (23 bytes) of
  the exact forms in @rule:staking-tagged, or a script tagged with
  `OP_SSGEN`, `OP_SSRTX` or `OP_SSTXCHANGE`. In particular a ticket cannot be
  funded by an `OP_SSTX` output, a treasury (`OP_TGEN`) output, or any other
  script type.
] <rule:staking-ticket-inputs>

#rule("Ticket commitment amounts", src: "internal/blockchain/validate.go · checkTicketPurchaseInputs, extractTicketCommitAmount")[
  For every input $i$ of a ticket, let $v_i$ be the amount of the output it
  spends, $c_i$ the committed amount of output $2i + 1$ (bytes 22–29 decoded as
  a little-endian `uint64` with bit 63 cleared, taken as `int64`), and $r_i$ the
  value of output $2i + 2$. Then $c_i + r_i$ #MUST equal $v_i$ exactly.
] <rule:staking-ticket-commitment>

#rule("Ticket price", src: "internal/blockchain/validate.go · checkProofOfStake")[
  The value of output 0 of every ticket in a block's stake tree #MUST be at
  least the `SBits` field of that block's header (`ErrNotEnoughStake`), and
  #MUST be at least #param("MinimumStakeDiff") (`ErrStakeBelowMinimum`). Both
  comparisons are "not less than": a ticket may pay more than the stake
  difficulty. The check uses the block's own claimed `SBits` and is context
  free; @rule:difficulty-sbits separately requires the claim to equal the
  stake difficulty computed by #chref("difficulty").
] <rule:staking-ticket-price>

The general input rules (#chref("transactions")) also apply to tickets:
total input value at least total output value, no zero-value inputs, fraud
proofs, maturity of spent outputs, script validation, and the prohibition on
spending outputs created in the same block (@rule:staking-same-block).

#note[
  Write $P$ for the ticket price (output 0), $C = sum c_i$ for the total
  commitment and $R = sum r_i$. The input rules give
  $sum v_i >= P + R + ("values of the commitment outputs")$, and
  @rule:staking-ticket-commitment gives $sum v_i = C + R$, so $C >= P > 0$.
  The difference $C - P$ is the ticket's transaction fee plus any value placed
  in commitment outputs. Since $C > 0$, the division in
  @alg:staking-return-amounts never divides by zero.
]

#vector[A ticket purchase (dcrd regression-network test chain, block 19)][
  ```
  ticket 2f278527eea8d2e6663c547f9b669a6c1aaa8f330bac43f16bb8bb93e0d21df5 (display)
  input 0 spends 320000 atoms
  out 0  value 20000  ba76a9149bc83f416940190002e6bdded468709d87ffd36088ac
         = OP_SSTX-tagged P2PKH, hash 9bc83f416940190002e6bdded468709d87ffd360
  out 1  value 0      6a1e9bc83f416940190002e6bdded468709d87ffd36000e20400000000000058
         push 0x1e (30 bytes)
         hash     9bc83f416940190002e6bdded468709d87ffd360
         amount   00e2040000000000 -> 0x000000000004e200 = 320000, bit 63 clear: P2PKH
         limits   0058 -> 0x5800: vote flag (0x0040) clear -> votes pay exact amounts
                  revocation flag (0x4000) set, k_rev = (0x5800 & 0x3f00) >> 8 = 24
  out 2  value 0      bd76a914000000000000000000000000000000000000000088ac
         = OP_SSTXCHANGE-tagged P2PKH (change of 0 atoms)
  check  c_0 + r_0 = 320000 + 0 = v_0   ticket fee = 320000 - 20000 = 300000
  ```
]

== Vote Transactions <sec:staking-vote>

A vote spends a winning ticket. Its first input, the stakebase, creates the
vote subsidy; its second input spends output 0 of the ticket. Its first two
outputs are data: the block being voted on and the vote bits. Then follows one
payment per ticket commitment, in commitment order. Once the treasury agenda
is active a vote may end with one more data output carrying votes on treasury
spends.

#figure(
  caption: [Layout of a vote for a ticket with $n$ commitments],
  table(
    columns: (auto, 1fr),
    table.header([Position], [Content]),
    [Input 0 (stakebase)], [Previous outpoint: hash all zero, index
      `0xffffffff`, tree 0. Fraud proof: block height 0, block index
      `0xffffffff`, value in = vote subsidy. Signature script =
      #param("StakeBaseSigScript").],
    [Input 1], [Outpoint (ticket hash, index 0, tree 1): output 0 of the
      ticket. Signature script satisfies the `OP_SSTX` script.],
    [Output 0], [Block reference: `6a 24` $||$ block hash (32 bytes) $||$
      $"LE"_32$(block height). Exactly 38 bytes.],
    [Output 1], [Vote bits: `6a` $||$ push(2…75 bytes) beginning with
      $"LE"_16$(vote bits).],
    [Outputs $2 … n+1$], [Payment $j$ (output $j + 2$) pays commitment $j$
      (ticket output $2j + 1$); script tagged `OP_SSGEN`.],
    [Output $n + 2$ (optional)], [Treasury votes: `6a` $||$ push(`"TV"` $||$
      1 to 7 entries of 33 bytes). Only with the treasury agenda active
      (@sec:staking-tvote).],
  ),
) <tab:staking-vote-layout>

=== Block reference and vote bits outputs <sec:staking-vote-outputs>

#fieldtable(
  caption: [Vote output 0: block reference script (exactly 38 bytes)],
  ("[0]", "uint8", "1", [`0x6a` (`OP_RETURN`).]),
  ("[1]", "uint8", "1", [`0x24` (`OP_DATA_36`).]),
  ("[2:34]", "hash", "32", [Hash of the block voted on, in internal byte order
    (the order in which a block hash is serialized, not display order).]),
  ("[34:38]", "uint32 LE", "4", [Height of the block voted on.]),
) <tab:staking-vote-ref>

#fieldtable(
  caption: [Vote output 1: vote bits script ($4 <= |s| <= 77$)],
  ("[0]", "uint8", "1", [`0x6a` (`OP_RETURN`).]),
  ("[1]", "uint8", "1", [Push opcode `0x02`…`0x4b`; equals $|s| - 2$.]),
  ("[2:4]", "uint16 LE", "2", [Vote bits (@sec:staking-votebits).]),
  ("[4:8]", "uint32 LE", "0 or 4", [Vote version. Present only when
    $|s| >= 8$; otherwise the vote version is 0.]),
  ("[8:]", "bytes", "0–69", [Remaining extended vote bits; no consensus
    meaning.]),
) <tab:staking-vote-bits>

dcrd calls bytes $[4:|s|)$ the *extended vote bits* (at most
$75 - 2 = 73$ bytes); the vote version occupies the first four of them.

=== Structure <sec:staking-vote-structure>

#algorithm("Vote predicate", src: "blockchain/stake/staketx.go · CheckSSGenVotes, IsStakeBase")[
  ```python
  NOT_A_VOTE = None

  def is_vote(tx):          # returns the list of treasury votes, or NOT_A_VOTE
      if len(tx.inputs) != 2:                       # NumInputsPerSSGen
          return NOT_A_VOTE
      if len(tx.outputs) > 66:                      # MaxOutputsPerSSGen
          return NOT_A_VOTE
      if len(tx.outputs) < 2:
          return NOT_A_VOTE
      sb = tx.inputs[0]                             # stakebase
      if not (sb.prev.hash == bytes(32) and sb.prev.index == 0xffffffff
              and sb.prev.tree == 0):
          return NOT_A_VOTE
      if not (sb.block_height == 0 and sb.block_index == 0xffffffff):
          return NOT_A_VOTE
      if tx.inputs[1].prev.index != 0:
          return NOT_A_VOTE
      if tx.inputs[1].prev.tree != 1:               # stake tree
          return NOT_A_VOTE
      for out in tx.outputs:
          if out.script_version != 0:
              return NOT_A_VOTE
      s0 = tx.outputs[0].script
      if not is_null_data(0, s0) or len(s0) != 38 or s0[0:2] != b"\x6a\x24":
          return NOT_A_VOTE
      s1 = tx.outputs[1].script
      if not is_null_data(0, s1) or not (4 <= len(s1) <= 77):
          return NOT_A_VOTE
      if s1[0] != 0x6a or not (0x02 <= s1[1] <= 0x4b):
          return NOT_A_VOTE
      end = len(tx.outputs)
      tvotes = []
      last = tx.outputs[-1]
      if is_null_data(last.script_version, last.script):
          end = end - 1
          tvotes = parse_treasury_votes(last.script)
          if tvotes is NOT_A_VOTE:
              return NOT_A_VOTE
          if not (len(tvotes) > 0 and tx.version == 3):   # TxVersionTreasury
              return NOT_A_VOTE
      for i in range(2, end):
          if not is_tagged(0, tx.outputs[i].script, OP_SSGEN):
              return NOT_A_VOTE
      return tvotes
  ```
] <alg:staking-check-vote>

#pitfall[
  The test for a treasury vote output looks only at the _last_ output and
  applies whenever it is a null data script, whatever the transaction version
  and whatever the agenda state. In a two-output transaction the last output
  is the vote bits output itself, so such a transaction is a vote only if its
  vote bits push happens to parse as treasury votes (and its version is 3).
  Conversely, a transaction whose last output is any null data script that
  does not parse as treasury votes is not a vote at all.
]

=== Treasury votes <sec:staking-tvote>

The format of the treasury vote output and the function
`parse_treasury_votes` used by @alg:staking-check-vote are specified in
#chref("treasury") (@alg:treasury-vote-parse). Wherever that algorithm
rejects, `parse_treasury_votes` yields `NOT_A_VOTE` here: the transaction is
not a vote at all.

Because a null data script pushes at most 256 bytes and an `OP_PUSHDATA1`
push at most 255, a vote carries between 1 and 7 treasury votes
($2 + 7 times 33 = 233$; $2 + 8 times 33 = 266$). The hashes are treasury
spend transaction hashes in internal byte order. How treasury votes are
tallied is specified in #chref("treasury").

#rule("Treasury votes require the treasury agenda", src: "internal/blockchain/validate.go · checkVoteInputs, checkTicketRedeemerCommitments")[
  When computing the number of payment outputs of a vote
  (@rule:staking-num-payees) and when matching outputs to commitments
  (@rule:staking-payee-script), the final output is excluded if and only if
  the treasury agenda is active for the block and the vote has a treasury vote
  output. Before the agenda is active the treasury vote output, if any, is
  therefore counted and matched as a payment, which always fails
  (@rule:staking-num-payees or @rule:staking-payee-script). In effect, votes #MUSTNOT
  carry treasury votes before the treasury agenda is active.
] <rule:staking-tvote-agenda>

=== Contextual checks <sec:staking-vote-context>

#rule("Stakebase signature script", src: "internal/blockchain/validate.go · checkTransactionContext")[
  The signature script of input 0 of a vote #MUST be between 2 and 100 bytes
  long inclusive (#const("MinCoinbaseScriptLen"), #const("MaxCoinbaseScriptLen"))
  and #MUST be byte-for-byte equal to #param("StakeBaseSigScript").
] <rule:staking-stakebase-script>

#rule("Ticket input not null", src: "internal/blockchain/validate.go · checkTransactionContext")[
  The previous outpoint of input 1 of a vote, and of input 0 of a revocation,
  #MUSTNOT be the null outpoint (all-zero hash, index `0xffffffff`, tree 0).
  (This is already implied by the predicates, which require index 0 and tree 1
  for a vote and tree 1 for a revocation.)
] <rule:staking-ticket-input-not-null>

The stakebase input is not a real spend: it is skipped by the UTXO lookup,
fraud-proof, maturity and script checks of #chref("transactions"), and its
signature script is
excluded from signature operation counting (#chref("script")). Its value-in
contributes the vote subsidy to the vote's inputs
(@rule:staking-stakebase-amount).

The vote's version is otherwise bounded only by the general maximum
transaction version (#chref("transactions")); a vote with a treasury vote
output must have version exactly 3 by @alg:staking-check-vote.

#vector[A vote (dcrd regression-network test chain, block 144)][
  ```
  vote 86f999e29e60384f60c4bc8309f022ef2641e51b4c1f416954cd63a636c60344 (display)
  in 0  stakebase: prev 00..00:ffffffff tree 0, height 0, index ffffffff,
        value in 2970297029 (the vote subsidy)
  in 1  prev 49d9a5021ea29435e45c4a1342d687102d7b307bfd42903fb16a952fd23d912a:0
        tree 1
  out 0 6a24bf7895d75e5da09e707eab994c05a30bf7c5c7e39ace6aed779609b36f0100008f000000
        hash, internal order:
          bf7895d75e5da09e707eab994c05a30bf7c5c7e39ace6aed779609b36f010000
        = block (display order):
          0000016fb3099677ed6ace9ae3c7c5f70ba3054c99ab7e709ea05d5ed79578bf
        height 8f000000 -> 143
  out 1 6a020100   push of 2 bytes: vote bits 0x0001 (approve), vote version 0
  out 2 value 3252437701
        bb76a91463ac6e0158d456f34131bca6eb8b471638daa5ec88ac (OP_SSGEN P2PKH)
  ticket: price 282140672, one commitment of 282440672, vote fee flag clear
  expected payment = floor(282440672 * (282140672 + 2970297029) / 282440672)
                   = 3252437701  (exact, since the vote fee flag is clear)
  ```
]

#note[
  The stakebase signature script of this test-chain vote (`deadbeef`) is not
  today's: the test chain (dcrd's `blockchain/stake/testdata/testexpiry.bz2`)
  was generated with a different genesis block, block-one ledger,
  organization script and #param("StakeBaseSigScript"). Its proof-of-work
  limit and difficulty rules are those of today's regression network.
]

== Revocation Transactions <sec:staking-revocation>

A revocation spends a missed or expired ticket and returns the ticket price to
the commitments, one output per commitment, in commitment order. Before
#dcp(9) @dcp0009 the revocation had to be signed by the holder of the voting rights;
since #dcp(9) anyone, typically the miner, may create it, it carries no
signature and pays no fee, and its outputs are fully determined by the ticket
and the parent block.

#figure(
  caption: [Layout of a revocation for a ticket with $n$ commitments],
  table(
    columns: (auto, 1fr),
    table.header([Position], [Content]),
    [Input 0], [Outpoint (ticket hash, index 0, tree 1). Signature script
      empty if the version is at least 2.],
    [Outputs $0 … n-1$], [Payment $j$ pays commitment $j$ (ticket output
      $2j + 1$); script tagged `OP_SSRTX`.],
  ),
) <tab:staking-rev-layout>

#algorithm("Revocation predicate", src: "blockchain/stake/staketx.go · CheckSSRtx")[
  ```python
  def is_revocation(tx) -> bool:
      if len(tx.inputs) != 1:                       # NumInputsPerSSRtx
          return False
      if len(tx.outputs) > 64:                      # MaxOutputsPerSSRtx
          return False
      if len(tx.outputs) == 0:
          return False
      for out in tx.outputs:
          if out.script_version != 0:
              return False
      if tx.inputs[0].prev.tree != 1:               # stake tree
          return False
      for out in tx.outputs:
          if not is_tagged(0, out.script, OP_SSRTX):
              return False
      if tx.version >= 2:                           # TxVersionAutoRevocations
          if len(tx.inputs[0].sig_script) != 0:
              return False
          if sum(out.value for out in tx.outputs) < tx.inputs[0].value_in:
              return False                          # non-zero fee
      return True
  ```
] <alg:staking-check-revocation>

The version-2 conditions are part of the predicate itself and apply
regardless of agenda state. The `value_in` they use is the fraud-proof
amount of the input, which the general input rules require to equal the
amount of the spent ticket output (#chref("transactions")); with that, the
condition says the fee is zero. The predicate does not check the input's
outpoint index; @rule:staking-ticket-index does.

#rule("Revocation version", src: "internal/blockchain/validate.go · checkTransactionContext")[
  If the `autorevocations` agenda is active for the block, every revocation
  #MUST have version exactly #const("TxVersionAutoRevocations") $= 2$.
] <rule:staking-rev-version>

#rule("Revocation script validation", src: "internal/blockchain/scriptval.go · checkBlockScripts, ValidateTransactionScripts")[
  If the `autorevocations` agenda is active for the block, the input scripts
  of a revocation whose version is at least 2 are not executed. In every other
  case the signature script of a revocation's input #MUST satisfy the ticket's
  `OP_SSTX` output script under the rules of #chref("script").
] <rule:staking-rev-scripts>

#note[
  Before #dcp(9) a revocation of version 2 or higher is required by the
  predicate to have an empty signature script, yet its script is executed and
  an empty signature script cannot satisfy a tagged P2PKH or P2SH script.
  Such revocations therefore never validate; before activation, valid
  revocations have version 0 or 1.
]

#vector[A revocation of an expired ticket, pre-#dcp(9) rules (regression-network test chain, block 420)][
  ```
  revocation (display hash), version 1:
    3ad0c0fd5720d0266d213815614a7dcd08047aa83f21820d22fd3921b7edb0c8
  in 0  prev acc72577d3c3efac89975fddbe22d18eca143a6882d7a49714da81a98f6ed43f:0
        signed; the ticket has price 20000 and one commitment of 320000
        to 9bc83f41...d360 with fee limits 0x5800
  out 0 value 20000  bc76a9149bc83f416940190002e6bdded468709d87ffd36088ac
        = OP_SSRTX-tagged P2PKH to the committed hash 9bc83f41...d360
  expected amount = floor(320000 * 20000 / 320000) = 20000
  revocation fee flag set, k_rev = 24, 2^24 >= 20000:
        allowed range [0, 20000]
  ```
]

== Input and Amount Validation <sec:staking-inputs>

This section specifies the checks that need the UTXO set: that a vote or
revocation spends a real, mature ticket; that it pays the ticket's
commitments exactly the amounts they are owed; and the maturity rules for
outputs created by stake transactions. They are applied to each transaction of
the stake tree, in order, as part of connecting the block
(#chref("transactions") gives the surrounding procedure). Throughout, $h$ is
the height of the block containing the transaction being checked.

=== Spending a ticket <sec:staking-spend-ticket>

#rule("Ticket outpoint index", src: "internal/blockchain/validate.go · checkVoteInputs, checkRevocationInputs")[
  The ticket input of a vote (input 1) and of a revocation (input 0) #MUST
  reference output index 0 of the ticket.
] <rule:staking-ticket-index>

#rule("Ticket output available", src: "internal/blockchain/validate.go · checkVoteInputs, checkRevocationInputs")[
  The output referenced by the ticket input of a vote or revocation #MUST exist
  in the UTXO set as seen by the transaction (that is, after the effects of the
  preceding transactions of the block) and be unspent.
] <rule:staking-ticket-available>

#rule("Ticket submission output", src: "internal/blockchain/validate.go · checkTicketSubmissionInput, isStakeSubmission")[
  The output referenced by the ticket input of a vote or revocation #MUST have
  script version 0, its public key script #MUST be tagged with `OP_SSTX`
  (@rule:staking-tagged), and the transaction that created it #MUST have been
  classified as a ticket (@rule:staking-classify).
] <rule:staking-submission-input>

#rule("Ticket spend maturity", src: "internal/blockchain/validate.go · checkVoteInputs, checkRevocationInputs")[
  Let $p$ be the height of the block that contains the ticket. A vote at height
  $h$ #MUST satisfy $h - p >= #param("TicketMaturity") + 1$. A revocation at
  height $h$ #MUST satisfy $h - p >= #param("TicketMaturity") + 2$ if the
  `autorevocations` agenda is not active for the block, and
  $h - p >= #param("TicketMaturity") + 1$ if it is.
] <rule:staking-spend-maturity>

#rationale[
  A ticket mined at $p$ enters the live pool while block
  $p + #param("TicketMaturity")$ is connected and can first be drawn for the
  following block, so $+1$ is the earliest possible vote. Before #dcp(9) a
  revocation required the ticket to be in the missed set of the parent block,
  which cannot happen before $+2$. With #dcp(9) a ticket may be revoked in the
  very block in which it is missed (code comment in
  #src("internal/blockchain/validate.go", "checkRevocationInputs")).
]

These maturity rules are necessary but far from sufficient: which tickets may
be voted or revoked in a block is decided by the ticket database
(@rule:staking-redeemers). A ticket that never entered the live pool
(@sec:staking-early) can be neither voted nor revoked.

The general input checks of #chref("transactions") also apply to the ticket
input, in particular the fraud proof (the input's value in, block height and
block index must match the ticket output) and script validation (subject to
@rule:staking-rev-scripts).

=== Number of payments <sec:staking-num-payees>

#rule("Number of payments", src: "internal/blockchain/validate.go · checkVoteInputs, checkRevocationInputs")[
  Let $n = (|"ticket outputs"| - 1) \/ 2$ be the number of commitments of the
  spent ticket. For a vote, let $e = 1$ if the treasury agenda is active for
  the block and the vote has a treasury vote output (@alg:staking-check-vote
  returned a non-empty list), and $e = 0$ otherwise; the vote #MUST have exactly
  $2 + n + e$ outputs. A revocation #MUST have exactly $n$ outputs.
] <rule:staking-num-payees>

=== Return amounts <sec:staking-return>

When a ticket is spent, the total to be returned is the ticket price $P$,
plus the vote subsidy $S$ for a vote. The total is divided among the
commitments in proportion to the amounts they committed, which include each
contributor's share of the ticket purchase fee. The division rounds every
share down; the rounding remainder, between 0 and $n - 1$ atoms, is left as
transaction fee for votes and (before #dcp(9)) for revocations. Under #dcp(9)
the remainder of a revocation is distributed one atom at a time to outputs
chosen by the lottery's pseudorandom generator, seeded with the serialized
header of the parent block, so that the fee can be exactly zero.

#algorithm("Ticket return amounts", src: "internal/blockchain/validate.go · calcTicketReturnAmounts")[
  ```python
  def commit_amount(script) -> int64:
      return int64(le64_decode(script[22:30]) & (2**63 - 1))

  def return_amounts(ticket_outs, price, vote_subsidy, prev_header_bytes,
                     is_vote, auto_revocations_active) -> list[int64]:
      commits = [commit_amount(ticket_outs[i].script)
                 for i in range(1, len(ticket_outs), 2)]
      contribution_sum = sum(commits)          # > 0 for every valid ticket
      total = price + vote_subsidy             # vote_subsidy = 0 for revocations
      returns = []
      for c in commits:                        # unbounded (big) integers here
          returns.append(((c * total) << 32) // contribution_sum >> 32)
      if is_vote or not auto_revocations_active:
          return returns
      remainder = total - sum(returns)
      if remainder > 0:
          prng = Hash256PRNG(prev_header_bytes)          # Algorithm "PRNG"
          for _ in range(remainder):
              returns[prng.uniform(uint32(len(returns)))] += 1
      return returns
  ```
] <alg:staking-return-amounts>

The intermediate product $c times "total" times 2^32$ exceeds 64 bits and must
be computed with arbitrary precision (dcrd uses `big.Int`); all operands are
non-negative, so the floor division and right shift are exact floors. The
formula equals $floor(c times "total" \/ "contribution_sum")$ exactly, but an
implementation that evaluates it differently must take care not to overflow.
Each result fits in `int64` because it does not exceed $"total"$.

The pseudorandom generator is the one of @alg:staking-prng, with the 180-byte
serialized header of the parent of the block being validated (the block at
height $h - 1$) as seed. A fresh generator is created for every revocation, so
all revocations in one block draw from the same sequence. That sequence is
also the one the lottery used to select the winners for block $h$.

#vector[Return amounts (computed with dcrd's `calcTicketReturnAmounts`)][
  ```
  prev header (180 bytes, from dcrd validate_test.go):
    07000000dc02335daa073d293e1b150648f0444a60b9c97604abd01e00000000000000003c449b23
    21c4bd0d1fa76ed59f80ebaf46f16cfb2d17ba46948f09f21861095566482410a463ed49473c2727
    8cd7a2a3712a3b19ff1f6225717d3eb71cc2b5590100012c7312a3c30500050095a100000cf42418
    f1820a870300000020a10700091600005b32a55f5bcce31078832100007469943958002e00000000
    0000000000000000000000000000000007000000
  PRNG IV  fd99cb2f0ea29b91d6d4f3366299a9969598ce5c2ff275bd5ed034a23fe993db
  first rand32 values 4254714671 245537681 3604280118 1654237590
    -> uniform(3): 2 2 0 0      uniform(5): 1 1 3 0       (2^32 mod 3 = 2^32 mod 5 = 1)

  commitments [100000000, 200000000, 300000007], price 600000005
    vote, subsidy 0           -> [99999999, 199999999, 300000005]   sum 600000003
    vote, subsidy 123456789   -> [120576130, 241152261, 361728401]  sum 723456792
    revocation, pre-DCP-0009  -> [99999999, 199999999, 300000005]   sum 600000003
    revocation, DCP-0009      -> [99999999, 199999999, 300000007]   sum 600000005
                                 (remainder 2, both atoms to index 2)
  commitments [100000000] x 5, price 400000004
    revocation, DCP-0009      -> [80000001, 80000002, 80000000, 80000001, 80000000]
                                 (remainder 4 to indexes 1, 1, 3, 0)
  ```
]

=== Matching outputs to commitments <sec:staking-payees>

Payment $j$ of a vote is output $j + 2$; payment $j$ of a revocation is output
$j$. Payment $j$ corresponds to commitment $j$, which is output $2j + 1$ of the
ticket, and to the $j$-th return amount $A_j$ of @alg:staking-return-amounts
(computed with $P$ = value of ticket output 0 and, for votes, $S$ = the vote
subsidy of @rule:staking-stakebase-amount).

#rule("Payment script", src: "internal/blockchain/validate.go · checkTicketRedeemerCommitments")[
  For every payment $j$ (every output from the first payment position up to,
  but excluding, the treasury vote output when it is excluded by
  @rule:staking-num-payees):
  + its script version #MUST be 0;
  + if bit 63 of commitment $j$'s encoded amount is set (byte 29 of the
    commitment script has its top bit set), its script #MUST be a P2SH script
    tagged with `OP_SSGEN` (vote) or `OP_SSRTX` (revocation), in the exact
    24-byte form of @rule:staking-tagged; otherwise it #MUST be a P2PKH script
    with the same tag in the exact 26-byte form;
  + the 20-byte hash in that script #MUST equal bytes 2–21 of commitment $j$'s
    script.
] <rule:staking-payee-script>

#rule("Payment value and fee limits", src: "internal/blockchain/validate.go · checkTicketRedeemerCommitments")[
  Let $f$ be the fee limits field of commitment $j$ (@tab:staking-feelimits).
  Payment $j$ is *fee-limited* if
  - the transaction is a vote and bit `0x0040` of $f$ is set, or
  - the transaction is a revocation, bit `0x4000` of $f$ is set, and it is not
    the case that the `autorevocations` agenda is active for the block and the
    revocation's version is at least 2.
  If payment $j$ is not fee-limited its value #MUST equal $A_j$ exactly.
  If it is fee-limited, let $k = f "AND" "0x003f"$ for a vote or
  $k = (f "AND" "0x3f00") >> 8$ for a revocation, and let
  $ L = cases(A_j - 2^k & "if" k < 63 "and" 2^k < A_j, 0 & "otherwise") $
  Then its value $v$ #MUST satisfy $L <= v <= A_j$.
] <rule:staking-payee-value>

#note[
  The fee limit applies to each payment separately, not to the transaction
  fee as a whole. Since $k$ has six bits, $k = 63$ is the only value that
  always permits the whole payment to be taken as fee; a smaller $k$ does so
  only when $2^k >= A_j$. The computation $2^k$ never overflows `int64`
  because it is only evaluated for $k < 63$. Once #dcp(9) is active every revocation
  is version 2 (@rule:staking-rev-version) and therefore not fee-limited: each
  payment is exactly $A_j$, and because the remainder has been distributed the
  payments sum to exactly $P$, which is consistent with the zero-fee condition
  of @alg:staking-check-revocation.
]

#note[
  The values of a vote's two data outputs (and of a treasury vote output) are
  not constrained by any stake rule; value placed there is unspendable and
  counts against the general requirement that outputs not exceed inputs.
]

=== The vote subsidy <sec:staking-subsidy>

#rule("Stakebase amount", src: "internal/blockchain/validate.go · checkVoteInputs")[
  Let $H_v$ be the height encoded in bytes 34–37 of the vote's output 0 (the
  height of the block voted on). The value-in field of the vote's input 0
  #MUST equal the vote subsidy for height $H_v$, computed by the vote subsidy
  function of #chref("subsidy") (dcrd `CalcStakeVoteSubsidyV3`) with the
  subsidy split variant selected by the agendas active for the block: the
  #dcp(12) variant if `changesubsidysplitr2` is active, otherwise the #dcp(10)
  variant if `changesubsidysplit` is active, otherwise the original.
  This value is the subsidy $S$ used in @alg:staking-return-amounts.
] <rule:staking-stakebase-amount>

#note[
  A dcrd source comment records that the subsidy "really should" be computed
  from the height of the block containing the vote rather than the block voted
  on, and that this is now part of consensus. Since votes must vote on the
  parent block (@rule:staking-vote-parent), $H_v = h - 1$ in every valid block.
]

#rule("Stakebase totals", src: "internal/blockchain/validate.go · checkStakeBaseAmounts, getStakeBaseAmounts, checkTransactionsAndConnect")[
  Let $S_(h-1)$ be the vote subsidy for height $h - 1$ (same function and
  variant as in @rule:staking-stakebase-amount). For every vote in the block,
  the sum of all its output values minus the amount of the ticket output it
  spends #MUSTNOT exceed $S_(h-1)$. Summed over all votes in the block, the
  total output value minus the total spent ticket amount #MUSTNOT exceed
  $S_(h-1) times "Voters"$ if $h >= #param("StakeValidationHeight")$, and
  #MUSTNOT exceed 0 otherwise, where `Voters` is the header field.
] <rule:staking-stakebase-total>

These two checks are implied by the preceding rules in any block that
satisfies them, but they are separate checks in dcrd and are stated for
completeness. The stake tree is processed before the regular tree; transaction
fees of stake transactions are added to the fees available to the coinbase as
described in #chref("subsidy").

=== Summary: checking a vote or revocation <sec:staking-redeemer-summary>

@alg:staking-redeemer-inputs collects the transaction-level checks of this
section for one vote or revocation. It adds nothing to the rules above; it
shows which data each check needs. The block-level eligibility of the ticket
(@rule:staking-redeemers) is checked separately.

#algorithm("Input checks for a vote or revocation at height h", src: "internal/blockchain/validate.go · checkVoteInputs, checkRevocationInputs, checkTicketRedeemerCommitments")[
  ```python
  def check_redeemer_inputs(tx, h, utxo, parent_header, flags, params):
      is_vote = tx_type(tx) == VOTE
      if is_vote:
          tin = tx.inputs[1]
          voted_height = le32_decode(tx.outputs[0].script[34:38])
          subsidy = vote_subsidy(voted_height, flags.subsidy_variant)
          if tx.inputs[0].value_in != subsidy:
              reject("bad stakebase amount")
      else:
          tin = tx.inputs[0]
          subsidy = 0
      if tin.prev.index != 0:
          reject("ticket input must reference output 0")
      entry = utxo.lookup(tin.prev)
      if entry is None or entry.spent:
          reject("missing ticket output")
      if (entry.script_version != 0 or not is_tagged(0, entry.script, OP_SSTX)
              or entry.tx_type != TICKET):
          reject("not a ticket submission output")
      extra = 1 if is_vote or flags.auto_revocations else 2
      if h - entry.height < params.TicketMaturity + extra:
          reject("immature ticket spend")
      ticket_outs = entry.ticket_outputs        # every output of the ticket
      n = (len(ticket_outs) - 1) // 2
      if is_vote:
          e = 1 if flags.treasury and len(is_vote_tvotes(tx)) > 0 else 0
          first, payments = 2, len(tx.outputs) - 2 - e
      else:
          first, payments = 0, len(tx.outputs)
      if payments != n:
          reject("wrong number of payments")
      amounts = return_amounts(ticket_outs, ticket_outs[0].value, subsidy,
                               serialize(parent_header), is_vote,
                               flags.auto_revocations)
      for j in range(payments):
          check_payment(tx, first + j, ticket_outs[2 * j + 1].script,
                        amounts[j], is_vote, flags)   # payment script and value rules
  ```
] <alg:staking-redeemer-inputs>

Here `is_vote_tvotes(tx)` is the list returned by @alg:staking-check-vote.

#pitfall[
  Validating a vote or revocation needs *all* outputs of the spent ticket: the
  ticket price from output 0 and the hashes, amounts and fee limits of the
  commitment outputs, which are unspendable null data outputs that a UTXO set
  would normally discard. dcrd stores them with the ticket's output 0 in its
  UTXO entry for as long as that output is unspent
  (#src("internal/blockchain/utxoentry.go", "TicketMinimalOutputs")). An
  implementation must likewise retain every output (value, script version and
  script) of each unspent ticket.
]

=== Outputs created by stake transactions <sec:staking-stake-outputs>

#rule("Ticket outputs are spent only by votes and revocations", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  An input of any transaction that is neither a vote nor a revocation #MUSTNOT
  spend an output whose script (with its script version) is tagged with
  `OP_SSTX`.
] <rule:staking-sstx-spend>

#rule("Maturity of stake outputs", src: "internal/blockchain/validate.go · CheckTransactionInputs")[
  Let $o$ be the height of the block containing the spent output and $h$ the
  height of the spending transaction's block.
  - An output tagged with `OP_SSGEN` or `OP_SSRTX` #MUSTNOT be spent unless
    $h - o >= #param("SStxChangeMaturity")$ when the treasury agenda is not
    active for the block, or $h - o >= #param("CoinbaseMaturity")$ when it is.
  - An output tagged with `OP_SSTXCHANGE` #MUSTNOT be spent unless
    $h - o >= #param("SStxChangeMaturity")$.
] <rule:staking-stake-output-maturity>

#pitfall[
  #param("SStxChangeMaturity") is 1 on every network, so before the treasury
  agenda vote rewards and revocation refunds could be spent in the very next
  block. Informative documentation that describes a 256-block wait for vote
  rewards matches the consensus rule only once the treasury agenda is
  active. The general coinbase and expiry maturity rules of
  #chref("transactions") still apply independently.
]

#rule("Stake transactions do not spend same-block outputs", src: "internal/blockchain/validate.go · CheckTransactionInputs, isSBSSViolation")[
  No input of a ticket, vote, revocation, treasury add, treasury spend or
  treasurybase (other than input 0 of a vote, treasury spend or
  treasurybase, which spends nothing) may spend an output created in
  the same block (in either tree), except the single historical outputs listed
  in @tab:staking-sbss: on the given network, at the given height, output 0 of
  the regular-tree transaction with the given hash may be spent by a stake
  transaction of the same block.
] <rule:staking-same-block>

#figure(
  caption: [Same-block stake spends grandfathered into the chain (hashes in
    display order)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Network], [Height], [Transaction]),
    [main], [1106817], [#hex("0875ecdc5f12c8aa6ee0d54331fd5b5e786639882a3adb09882de5e3b939613b")],
    [main], [1106831], [#hex("714e71358937cd33480fd2900853d43ea3440ca67b38bacdfeaeb0c37c80ee27")],
    [main], [1106837], [#hex("aeba09a4efa334e3c13e68f27f40bd37cda7643c263f88d69f38a33c2cdacd18")],
    [main], [1106854], [#hex("17228266d9d6dd7084aa2e479319aca6d755c2a9d2dbb3cf28c8151470c7a439")],
    [main], [1106860], [#hex("20d6d3ed1b609f03969474dca1f452c25e035766457dfd58061f9b9270fc4e6d")],
    [main], [1107195], [#hex("5d2e1898fe0c631cb795b1906fb3cf8d9772f1826be8dea64dd3ab85ac0ab2d3")],
    [testnet3], [1980161], [#hex("451b6eed1a777bc5bbb5c1dbe10a9e444cbeb7d863adb75fc6b7a676b3dcbb58")],
  ),
) <tab:staking-sbss>

The mechanics of this exception (dcrd re-adds output 0 of the listed
transaction to the view before connecting the stake tree) belong to the UTXO
model of #chref("transactions").

== The Lottery <sec:staking-lottery>

After each block at height $N >= #param("StakeValidationHeight") - 1$ is
connected, every node draws #param("TicketsPerBlock") distinct winners from
the live ticket pool as it stands after that block. The draw is a
deterministic function of two things only: the serialized header of block $N$
and the set of live tickets. Because the header commits to the block's
transactions and to its proof of work, a miner cannot cheaply bias the draw,
and every node computes the same winners. The winners of block $N$ may vote on
block $N$ in block $N + 1$. A six-byte digest of the draw, the *final state*,
is committed in the header of block $N + 1$ so that a node can check it has
the same live pool and the same winners before validating the votes.

All hashing in this section is BLAKE-256 (#chref("crypto")), written
$"BLAKE256"(x)$, producing 32 bytes.

=== The pseudorandom generator <sec:staking-prng>

The generator, `Hash256PRNG`, turns a seed of arbitrary length into a stream
of 32-bit integers. The seed is hashed together with a constant to a 32-byte
initialization vector (IV). The first eight outputs are the eight big-endian
32-bit words of the IV itself; every following group of eight is the words of
$"BLAKE256"("IV" || "BE"_32(i))$ for $i = 0, 1, 2, …$.

#algorithm("Hash256PRNG", src: "blockchain/stake/lottery.go · CalcHash256PRNGIV, NewHash256PRNGFromIV, Hash256Rand, StateHash")[
  ```python
  SEED_CONST = bytes.fromhex("243f6a8885a308d3")

  class Hash256PRNG:
      def __init__(self, seed: bytes):
          self.seed = BLAKE256(seed + SEED_CONST)   # the IV
          self.last_hash = self.seed
          self.hash_idx = 0      # next 4-byte word of last_hash to use, 0..7
          self.idx = 0           # uint64: number of hashes derived from seed

      def rand32(self) -> uint32:
          i = 4 * self.hash_idx
          r = be32_decode(self.last_hash[i:i + 4])
          self.hash_idx += 1
          if self.hash_idx > 7:
              self.last_hash = BLAKE256(self.seed + be32(uint32(self.idx)))
              self.idx += 1
              self.hash_idx = 0
          if self.idx > 0xffffffff:                 # unreachable in practice
              self.seed = BLAKE256(self.seed)
              self.last_hash = self.seed
              self.idx = 0
          return r

      def state_hash(self) -> bytes:              # 32 bytes
          return BLAKE256(self.last_hash + be32(uint32(self.idx))
                          + bytes([self.hash_idx]))
  ```
] <alg:staking-prng>

Note the order of operations in `rand32`: the word is read first, and the
next hash is computed immediately after the eighth word of a hash has been
read, not lazily before the ninth. This matters for `state_hash`, which
depends on `last_hash`, `idx` and `hash_idx` exactly as they stand after the
last call. The rollover of `idx` past $2^32 - 1$ would require more than
$2^35$ calls and cannot occur in consensus use; it is included for
completeness.

#pitfall[
  Both 32-bit encodings in this generator are *big-endian*, unlike almost every
  other integer in the protocol: the words read from the hash and the counter
  appended to the IV. The counter appended for the first derived hash is 0, so
  the ninth output comes from $"BLAKE256"("IV" || #hex("00000000"))$.
]

=== Uniform integers <sec:staking-uniform>

#algorithm("Uniform random integer in [0, n)", src: "blockchain/stake/lottery.go · UniformRandom")[
  ```python
  def uniform(prng: Hash256PRNG, n: uint32) -> uint32:    # prng.uniform(n)
      if n < 2:
          return 0                         # consumes no output
      if n > 0x80000000:
          lo = uint32(2**32 - n)
      else:
          lo = uint32(0xffffffff - 2 * n + 1) % n
      while True:                          # rejection sampling
          r = prng.rand32()
          if r >= lo:
              return r % n
  ```
] <alg:staking-uniform>

In both branches `lo` equals $2^32 mod n$ (for $n = 2^31$ the expression
$2^32 - 2n$ is 0), so the accepted values $[2^32 mod n, 2^32)$ form a range
whose length is a multiple of $n$ and the result is exactly uniform. Values
below `lo` are discarded and another word is drawn.

#vector[Hash256PRNG and uniform, seed = ASCII "Decred" (#hex("446563726564"))][
  ```
  IV = d48f4175da6800a5e3557cb4205f8be944483480935c0f2f30d7d4eaabd2efcf
  rand32 #0..#11:
    3566158197 3664248997 3814030516  543132649 1145582720 2472283951
     819451114 2882727887 2142381687 1037079434  122677752 3963859140
  (#0..#7 are the words of the IV; #8 = 0x7fb22677 is the first word
   of BLAKE256(IV || 00000000))
  state_hash after 12 calls (idx = 1, hash_idx = 4):
    84b9d4f546995a04697b695feb9497d66e46a23b82c339cfdd03e4282c0d6ce5

  fresh generator, successive calls:
    uniform(1) = 0                (no output consumed)
    uniform(2) = 1                (r = 3566158197, lo = 0)
    uniform(5) = 2                (r = 3664248997, lo = 1)
    uniform(40960) = 40116        (r = 3814030516, lo = 0)
    uniform(2147483649) = 324800302
                                  (lo = 2147483647: r = 543132649 and 1145582720
                                   rejected, r = 2472283951 accepted)
    uniform(4294967295) = 819451114  (lo = 1)

  dcrd TestBasicPRNG: seed = BLAKE256(01), 100000 calls, state_hash =
    e4c445ebe0815aaf9944f94b63d388566132b72e1ee2d3a985fcfbae72cdf124
  ```
]

=== Order of the live ticket pool <sec:staking-pool-order>

dcrd stores the live tickets in a treap keyed by ticket hash, with the
ticket's live height as heap priority. Only the key order matters for
consensus: a winner index $i$ denotes the ticket at position $i$ of the pool
in ascending key order.

#rule("Live pool order", src: ("blockchain/stake/internal/tickettreap/immutable.go · get, Put, GetByIndex", "blockchain/stake/lottery.go · fetchWinners"))[
  The live ticket pool is ordered by ticket hash, ascending, where two hashes
  are compared as 32-byte strings in *internal byte order* (the byte order in
  which the hash is produced by BLAKE-256 and serialized in an outpoint),
  lexicographically from byte 0, each byte as an unsigned value. Position 0 is
  the smallest hash. The heights of the tickets play no part in the order.
] <rule:staking-pool-order>

#pitfall[
  Display-form hashes are byte-reversed (#chref("conventions")). Sorting
  display strings, or sorting hashes interpreted as little-endian 256-bit
  integers, gives a different order. In terms of display strings the
  comparison starts at the _last_ two hexadecimal digits. Any data structure
  may be used; a sorted array of 32-byte keys reproduces dcrd exactly.
]

=== Drawing the winners and the final state <sec:staking-draw>

In the algorithms of this section `fail(reason)` means that the block
cannot be connected. It is distinct from `reject` because dcrd does not
report the condition as a blockchain rule violation (the draw failure is an
untyped error, the others are stake-package errors), so the block is not
marked invalid; it is refused either way.

#algorithm("Winner selection and final state", src: ("blockchain/stake/tickets.go · connectNode", "blockchain/stake/lottery.go · findTicketIdxs, fetchWinners", "internal/blockchain/blockindex.go · lotteryIV"))[
  ```python
  def draw_winners(header_bytes: bytes, pool: list[bytes], k: int):
      # header_bytes: the 180-byte serialized header of the block just connected
      # pool: live ticket hashes after connecting it, sorted as in the pool order rule
      # k: TicketsPerBlock
      prng = Hash256PRNG(header_bytes)
      size = len(pool)
      if size < k:
          fail("cannot draw winners")          # block cannot be connected
      idxs = []
      while len(idxs) < k:
          r = prng.uniform(uint32(size))
          if r not in idxs:                    # draw again on a repeat
              idxs.append(r)
      winners = [pool[i] for i in idxs]        # in draw order, not sorted
      final_state = BLAKE256(b"".join(winners) + prng.state_hash())[0:6]
      return winners, final_state
  ```
] <alg:staking-lottery>

The winners keep the order in which they were drawn; the final state hashes
their concatenation in that order (each hash in internal byte order) followed
by the generator's state hash after the last draw. A pool larger than
$2^32 - 1$ tickets is an error in dcrd and cannot occur. The case
`size < k` is discussed in @sec:staking-early.

#vector[Lottery on a ten-ticket pool (computed with dcrd's `connectNode`)][
  ```
  seed (stands in for a header): ASCII "block one header"
      = 626c6f636b206f6e6520686561646572
  IV = 4295eeba3103039d7adb28dee716bbceb7bce96ee13f5089d43daea53a43c1fd
  pool = { BLAKE256(byte i) : i = 0..9 }, sorted (internal byte order):
    [0] 0ce8d4ef4dd7cd8d62dfded9d4edb0a774ae6a41929a74da23109e8f11139c87  BLAKE256(00)
    [1] 19b7506ad9c189a9f8b063d2aee15953d335f5c88480f8515d7d848e7771c4ae  BLAKE256(06)
    [2] 49af37ab5270015fe25276ea5a3bb159d852943df23919522a202205fb7d175c  BLAKE256(02)
    [3] 4a6c419a1e25c85327115c4ace586decddfe2990ed8f3d4d801871158338501d  BLAKE256(01)
    [4] 4c2231813064f8500edae05b40195416bd543fd3e76c16d6efb10c816d92e8b6  BLAKE256(09)
    [5] 4c6eb9e38415034f4c93d3304d10bef38bf0ad420eefd0f72f940f11c5857786  BLAKE256(04)
    [6] 53d661e71e47a0a7e416591200175122d83f8af31be6a70af7417ad6f54d0038  BLAKE256(07)
    [7] 9bff7982eab6f7883322edf7bdc86a23c87ca1c07906fbb1584f57b197dc6253  BLAKE256(08)
    [8] b706d561742ad3671703c247eb927ee8a386369c79644131cdeb2c5c26bf6c5d  BLAKE256(03)
    [9] bdd15db13448905791a70b68137445e607cca06cc71c7a58b9b2e84a06c54d08  BLAKE256(05)
  k = 5: indexes drawn [4, 7, 8, 6, 5]  (6 draws: idx = 0, hash_idx = 6 afterwards)
  state_hash  = 45a5fba5bbb9c9058645d09514427a53722ec3f2ab4076f650741f06a6bd4229
  final state = 27a0cf022cbd

  next block (seed "block two header"): winners [4] [7] [8] vote, [6] and [5] are
  missed; the pool is now the 5 remaining tickets and all 5 are drawn:
  indexes [3, 1, 0, 4, 2] over the new pool, final state = 27c864c436ea
  ```
]

#vector[Duplicate rejection: seed "Decred", pool size 7, k = 5][
  ```
  rand32 #0..#6 mod 7 = 0 3 2 3 2 4 6   (lo = 2^32 mod 7 = 4; no rejections)
  indexes = [0, 3, 2, 4, 6]             (draws #3 and #4 repeat and are discarded)
  state_hash = 95e00d629ec81c0e67a570021bf081437385ce01db184af466c7773bbdbb1e97
  ```
]

#vector[A real draw: dcrd regression-network test chain, lottery on block 143][
  ```
  header of block 143 (180 bytes):
    000000008379bcce660662c28735988b54d193bd9386c501acae677fe002326c66b10000a1c527ea
    1a1abceb6a145579ba739a0fb0de3ba3594f8717c62e3fc1d88b25fe000000000000000000000000
    000000000000000000000000000000000000000001000000000000000000000080070000f7e4001f
    00004834040000008f0000007e0100006d5cec57306f010000000000000000000000000000000000
    0000000000000000000000000000000000000000
  IV = f680c8ab1cac33b1b9fd72165d34adaeaca23a564bfe16f55976b6953a338e72
  live pool after block 143: 1940 tickets
  indexes [1315, 1193, 1774, 302, 1558]
  winners (internal byte order):
    adad145e4bb898ea4e2e4ab4eac39cad1d628cead91e245df48d1851cc8001ff
    9f2fcb5eb5dd8710c219db9899eb1bd8c60163eaa25abecbfeeca0c5c8df4cc2
    eb97034120808b03bf4155183094e37cd723de0f1d2e470d5b0482adc7e9f530
    2a913dd22f956ab13f9042fd7b307b2d1087d642134a5ce43594a21e02a5d949
    cd615d92df7eb0f042c36899b4dbafa9935b8fc320c32cd689e21054acae63b5
  state_hash = 0ca9f8c7ca073e2f9e4e2303b2a632407975d6c10dcb4e0e106233c671ceb980
  final state = ff00007be270  = FinalState in the header of block 144 (PoolSize 1940)
  ```
]

The fourth winner of the last vector is the ticket spent by the vote shown in
@sec:staking-vote-context (whose display-form hash
#hex("49d9a5021ea29435e45c4a1342d687102d7b307bfd42903fb16a952fd23d912a") is
the reverse of the internal form above).

== The Ticket Database <sec:staking-db>

Every node maintains, for each block, the set of live tickets, the set of
missed tickets and the set of revoked tickets as of that block, together with
the winners drawn on that block and its final state. dcrd calls this
per-block state a *stake node* (#src("blockchain/stake/tickets.go", "Node")).
The state of a block is a function of the state of its parent and of the block
itself; the genesis block's state is empty.

=== Ticket states <sec:staking-states>

#figure(
  caption: [Ticket states. Each ticket is in at most one of the three sets.],
  table(
    columns: (auto, auto, 1fr),
    table.header([State], [Set], [Leaves the state when]),
    [Immature], [none], [Block $p + #param("TicketMaturity")$ is connected:
      the ticket becomes live (if that height is at least
      #param("StakeEnabledHeight")).],
    [Live], [live, with live height $L$], [It is a winner of the parent of the
      block being connected (then voted or missed), or that block's height
      reaches $L + #param("TicketExpiry")$ (then expired).],
    [Voted], [none (removed)], [Final. The vote is the ticket's only spend.],
    [Missed], [missed, flag _expired_ = false], [Revoked.],
    [Expired], [missed, flag _expired_ = true], [Revoked.],
    [Revoked], [revoked], [Final.],
  ),
) <tab:staking-states>

The *live height* $L$ of a ticket is the height of the block whose connection
made it live, $L = p + #param("TicketMaturity")$, not the height of its
purchase. Expired tickets are kept in the missed set; the expired flag only
distinguishes them for reporting. In consensus terms "missed set" always means
missed or expired, not yet revoked.

=== Connecting a block <sec:staking-connect>

#algorithm("Stake state transition when connecting the block at height h", src: ("blockchain/stake/tickets.go · connectNode", "internal/blockchain/stakenode.go · maybeFetchNewTickets, fetchStakeNode", "blockchain/stake/staketx.go · FindSpentTicketsInBlock"))[
  ```python
  def connect(parent: StakeState, block, h: int, params) -> StakeState:
      st = parent.copy()          # live: hash -> L; missed: hash -> (L, expired); revoked
      # Tickets spent in this block, in stake-tree order:
      voted   = [tx.inputs[1].prev.hash for tx in block.stake_txs
                 if is_vote(tx) is not NOT_A_VOTE]
      revoked = [tx.inputs[0].prev.hash for tx in block.stake_txs if is_revocation(tx)]
      if h >= params.StakeEnabledHeight:
          # 1. Every voted ticket must be a winner drawn on the parent.
          for t in voted:
              if t not in parent.winners:
                  fail("unknown ticket spent")
          # 2. Each parent winner is now either voted or missed.
          for w in parent.winners:
              L = st.live.pop(w)                    # must be present
              if w not in voted:
                  st.missed[w] = (L, False)
          # 3. Expire live tickets whose live height is old enough.
          expire_h = h - params.TicketExpiry if h > params.TicketExpiry else 0
          for t, L in list(st.live.items()):
              if L <= expire_h:
                  del st.live[t]
                  st.missed[t] = (L, True)
          # 4. Revocations move tickets from missed to revoked.
          for t in revoked:
              if t not in st.missed:
                  fail("revoked ticket not missed")
              st.revoked[t] = st.missed.pop(t)
          # 5. Tickets bought TicketMaturity blocks ago become live.
          for t in tickets_in(ancestor(block, h - params.TicketMaturity)):
              if t in st.live:
                  fail("duplicate ticket")
              st.live[t] = h                        # live height L = h
      # 6. Draw the winners for block h + 1.
      st.winners, st.final_state = [], bytes(6)
      if h >= params.StakeValidationHeight - 1:
          st.winners, st.final_state = draw_winners(serialize(block.header),
                                                    sorted(st.live),
                                                    params.TicketsPerBlock)
      return st
  ```
] <alg:staking-connect>

Here `tickets_in(B)` is the list of hashes of the stake-tree transactions of
block $B$ that are tickets (@rule:staking-classify), and `ancestor(block, x)`
is the ancestor of `block` at height $x$ on its own chain. The order of steps
1 to 5 is significant: winners are processed before expiry, so a winner whose
expiry height has also arrived becomes voted or missed, never expired; expiry
precedes revocations, which (with #dcp(9)) lets a block revoke a ticket that
expires in that same block; and new tickets are added before the draw, so a
ticket that becomes live at height $h$ can be drawn for block $h + 1$. The
order of tickets within each step affects only dcrd's undo records, not the
resulting sets.

#rule("Stake state transition", src: ("blockchain/stake/tickets.go · connectNode", "internal/blockchain/chain.go · connectBlock"))[
  A block can only be connected if @alg:staking-connect succeeds for it: every
  vote spends a winner drawn on its parent, every revoked ticket is in the
  missed set after steps 2 and 3, no ticket becomes live twice, and, at heights
  $h >= #param("StakeValidationHeight") - 1$, the live pool after step 5
  contains at least #param("TicketsPerBlock") tickets. A block for which it
  fails #MUSTNOT become part of the chain.
] <rule:staking-transition>

#note[
  In dcrd a failure of @alg:staking-connect is reported as an ordinary error
  rather than a rule violation, because in any block that has passed the
  checks of @sec:staking-block the first two conditions are already guaranteed
  (by @rule:staking-redeemers) and the third by unique transaction hashes.
  The pool-size condition is a genuine consensus constraint: a block at
  height $h >= #param("StakeValidationHeight") - 1$ after which the live
  pool would hold fewer than #param("TicketsPerBlock") tickets cannot be
  connected, so a chain whose pool is about to run out cannot be extended
  past that point. Mining software avoids producing such a chain
  (@sec:staking-policy).
]

#vector[State transitions (dcrd's `connectNode` with #param("TicketsPerBlock") $= 2$, #param("StakeEnabledHeight") $= 1$, #param("StakeValidationHeight") $= 2$, #param("TicketExpiry") $= 3$)][
  ```
  Ti = BLAKE256(byte i); hashes abbreviated to their first 4 bytes (internal order).
  Block headers are replaced by the seeds "h1".."h4". Only the ticket database
  transition is exercised; the block-level rules are not applied.

  block 1: T0..T9 become live (L = 1)
    live    T0 0ce8d4ef  T6 19b7506a  T2 49af37ab  T1 4a6c419a  T9 4c223181
            T4 4c6eb9e3  T7 53d661e7  T8 9bff7982  T3 b706d561  T5 bdd15db1
    winners [T6, T1]                      final state 3aced47dce07
  block 2: votes T6; revokes T1 (missed in step 2, revoked in step 4)
    live    T0 T2 T9 T4 T7 T8 T3 T5       revoked T1
    winners [T7, T5]                      final state 95ea5ea60e92
  block 3: votes T7; T5 is missed and not revoked
    live    T0 T2 T9 T4 T8 T3             missed T5     revoked T1
    winners [T4, T9]                      final state 93df9dcae44a
    expiring in block 4 (e = 4 - 3 = 1, winners excluded): T0 T2 T8 T3
  block 4: votes T4; T9 missed (step 2); T0 T2 T8 T3 expire (step 3);
           revokes T9 T0 T2 T8 T3 (step 4); T10 T11 T12 become live (L = 4)
    live    T12 61a3403f  T11 7b527886  T10 e81db4f0
    missed  T5            revoked T0 T2 T1 T9 T8 T3
    winners [T11, T10]                    final state 52c4fe648924
  ```
]

=== Early heights <sec:staking-early>

The two activation parameters divide the chain into three phases.

/ Before #param("StakeEnabledHeight"): Steps 1 to 5 are skipped entirely. No
  ticket becomes live, nothing expires, and no winners exist. Tickets may be
  bought (subject to the price rules) from the first block that can fund them.
/ From #param("StakeEnabledHeight") to #param("StakeValidationHeight") $- 2$:
  Tickets become live and can expire; the parent's winner list is empty, so
  step 2 does nothing. Blocks may not contain votes or revocations
  (@rule:staking-early-header, @rule:staking-early-stake-txs).
/ From #param("StakeValidationHeight") $- 1$: The draw runs after every block.
  The first winners are drawn on block #param("StakeValidationHeight") $- 1$,
  and block #param("StakeValidationHeight") is the first block that must carry
  votes.

#pitfall[
  The block at height $h$ adds the tickets of block $h - #param("TicketMaturity")$
  only when $h >= #param("StakeEnabledHeight")$. A ticket mined in a block
  below $#param("StakeEnabledHeight") - #param("TicketMaturity")$ would
  never enter the live pool and could never be voted or revoked. On all four
  networks #param("StakeEnabledHeight") equals #param("CoinbaseMaturity")
  $+$ #param("TicketMaturity") (256 + 256 on the main network, 16 + 16 on
  the others), and every spendable output descends from a coinbase of block
  1 or later, which cannot be spent before height
  $1 + #param("CoinbaseMaturity")$; so no ticket can be mined that early and
  every ticket does enter the pool. An implementation must nevertheless gate
  step 5 on $h >= #param("StakeEnabledHeight")$ exactly as stated.
]

The header fields `PoolSize` and `FinalState` of block $h$ commit to the
state of block $h - 1$ (@rule:staking-poolsize, @rule:staking-finalstate). For
every block below #param("StakeValidationHeight") the final state is
therefore the all-zero value, matching @rule:staking-early-header; the first
non-zero final state is in the header of block #param("StakeValidationHeight").

=== Tickets expiring in the next block <sec:staking-expiring>

The block-level revocation rules of #dcp(9) need to know, when validating
block $h$, which tickets block $h$ will expire. This set is computed from the
parent's state.

#rule("Tickets expiring in block h", src: "blockchain/stake/tickets.go · ExpiringNextBlock")[
  Let $e = h - #param("TicketExpiry")$ if $h > #param("TicketExpiry")$ and
  $e = 0$ otherwise. The tickets *expiring in block* $h$ are the tickets in
  the parent's live set whose live height equals $e$, excluding the parent's
  winners. (Every live ticket with a smaller live height has already expired,
  so this is the same set that step 3 of @alg:staking-connect expires.)
] <rule:staking-expiring>

=== Disconnecting a block (informative) <sec:staking-disconnect>

A reorganization requires undoing blocks. Since the state of a block is a
function of its parent's state and the block, an implementation may simply
recompute or cache states. dcrd instead records, for every block, the list of
ticket transitions it performed (each with the ticket's live height and its
flags) and applies them in reverse order to restore the parent's live, missed
and revoked sets. The parent's winners are recovered from the transitions
that removed winners (spent ones and missed non-expired ones), restored to
their original draw order, and the parent's final state is recomputed by
re-running the draw on the parent's header. Reverse order matters because,
with #dcp(9), one ticket can be missed (or expired) and revoked in the same
block. None of this affects consensus.

== Block-Level Stake Rules <sec:staking-block>

The rules in this section apply to a whole block. Together with the rules
above they determine which stake transactions a block may contain and tie the
stake fields of the header to the block's contents and to the ticket
database. @tab:staking-header lists the header fields involved; their
serialization is specified in #chref("encoding").

#figure(
  caption: [Stake-related block header fields],
  table(
    columns: (auto, auto, 1fr),
    table.header([Field], [Type], [Must equal]),
    [`VoteBits`], [`uint16`], [`0x0001` below #param("StakeValidationHeight")\;
      afterwards bit 0 must match the majority of the votes
      (@rule:staking-header-votebits). Other bits are unconstrained here.],
    [`FinalState`], [`[6]byte`], [Final state of the lottery drawn on the
      parent (@rule:staking-finalstate).],
    [`Voters`], [`uint16`], [Number of votes in the stake tree
      (@rule:staking-voters).],
    [`FreshStake`], [`uint8`], [Number of tickets in the stake tree
      (@rule:staking-freshstake).],
    [`Revocations`], [`uint8`], [Number of revocations in the stake tree
      (@rule:staking-revocations).],
    [`PoolSize`], [`uint32`], [Number of live tickets after the parent
      (@rule:staking-poolsize).],
    [`SBits`], [`int64`], [Stake difficulty (#chref("difficulty")); minimum
      ticket price (@rule:staking-ticket-price).],
  ),
) <tab:staking-header>

=== Context-free header rules <sec:staking-header-sanity>

#rule("Stake header fields below stake validation height", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  If the header's `Height` is less than #param("StakeValidationHeight"), its
  `Voters` #MUST be 0, its `Revocations` #MUST be 0, its `VoteBits` #MUST equal
  `0x0001`, and its `FinalState` #MUST be six zero bytes.
] <rule:staking-early-header>

#rule("Minimum number of votes", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  If the header's `Height` is at least #param("StakeValidationHeight"), its
  `Voters` #MUST be at least $floor(#param("TicketsPerBlock") \/ 2) + 1$
  (3 on every network, where #param("TicketsPerBlock") $= 5$).
] <rule:staking-min-votes>

#rule("Maximum number of votes", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  The header's `Voters` #MUSTNOT exceed #param("TicketsPerBlock").
] <rule:staking-max-votes>

#rule("Maximum number of ticket purchases", src: "internal/blockchain/validate.go · checkBlockHeaderSanity")[
  The header's `FreshStake` #MUSTNOT exceed #param("MaxFreshStakePerBlock").
] <rule:staking-max-freshstake>

#rule("Ticket purchase count", src: "internal/blockchain/validate.go · checkBlockDataSanity")[
  The header's `FreshStake` #MUST equal the number of transactions in the
  block's stake tree that are tickets.
] <rule:staking-freshstake>

@rule:staking-ticket-price, which checks every ticket in the stake tree
against the header's `SBits` and #param("MinimumStakeDiff"), is also a
context-free block check in dcrd.

=== Header commitments to the ticket database <sec:staking-header-context>

#rule("Pool size commitment", src: "internal/blockchain/validate.go · checkBlockHeaderContext")[
  The header's `PoolSize` #MUST equal the number of tickets in the live set of
  the parent block's stake state (the live pool from which the winners for
  this block were drawn).
] <rule:staking-poolsize>

#rule("Final state commitment", src: "internal/blockchain/validate.go · checkBlockHeaderContext")[
  The header's `FinalState` #MUST equal the final state of the parent block's
  stake state: the value computed by @alg:staking-lottery on the parent, or
  six zero bytes if no draw was made on the parent.
] <rule:staking-finalstate>

#note[
  dcrd skips these two checks, together with the difficulty, stake difficulty
  and stake version checks and the ticket redeemer check of
  @rule:staking-redeemers, when it adds a block that is an ancestor of its
  assumed-valid block or while in bulk-import mode (`BFFastAdd`). That is an
  optimization for blocks presumed valid; the rules hold for every block of
  the chain.
]

=== Stake tree composition <sec:staking-tree>

#rule("Tree membership", src: "internal/blockchain/validate.go · checkBlockContext")[
  Every transaction in a block's regular tree #MUST be of type _regular_
  (@rule:staking-classify), and every transaction in its stake tree #MUSTNOT
  be of type _regular_.
] <rule:staking-tree-membership>

#rule("Allowed stake transaction types", src: "internal/blockchain/validate.go · checkBlockContext")[
  Every transaction in the stake tree #MUST be a ticket, a vote, a revocation,
  or, only if the treasury agenda is active for the block, a treasury add, a
  treasury spend or a treasurybase. A stake-tree transaction classified as a
  treasury type while the treasury agenda is not active makes the block
  invalid.
] <rule:staking-allowed-types>

#rule("No votes or revocations below stake validation height", src: "internal/blockchain/validate.go · checkBlockContext")[
  If the block's height is less than #param("StakeValidationHeight"), every
  transaction in its stake tree #MUST be a ticket, or, if the treasury agenda
  is active, a treasury add or treasurybase. (Votes, revocations and treasury
  spends are excluded.)
] <rule:staking-early-stake-txs>

#rule("Non-empty stake tree", src: "internal/blockchain/validate.go · checkTransactionsAndConnect")[
  If the block's height is at least #param("StakeValidationHeight"), its stake
  tree #MUSTNOT be empty. (This is implied by @rule:staking-min-votes and
  @rule:staking-voters.)
] <rule:staking-nonempty>

#rule("Vote count", src: "internal/blockchain/validate.go · checkBlockContext")[
  The header's `Voters` #MUST equal the number of votes in the stake tree.
] <rule:staking-voters>

#rule("Revocation count and limit", src: "internal/blockchain/validate.go · checkBlockContext")[
  The number of revocations in the stake tree #MUSTNOT exceed 255
  (`maxRevocationsPerBlock`), and the header's `Revocations` #MUST equal that
  number.
] <rule:staking-revocations>

There is no rule on the order of tickets, votes and revocations within the
stake tree. The only positional requirement in the stake tree is that a
treasurybase, when the treasury agenda is active, is its first transaction
(#chref("treasury")). Because stake transactions cannot spend outputs of the
same block (@rule:staking-same-block), their relative order cannot affect the
validity of their inputs.

=== Votes <sec:staking-block-votes>

#rule("Votes vote on the parent", src: "internal/blockchain/validate.go · checkBlockContext")[
  If the block's height $h$ is at least #param("StakeValidationHeight"), the
  block reference of every vote in the stake tree (@tab:staking-vote-ref)
  #MUST name the block's parent: its 32-byte hash #MUST equal the header's
  `PrevBlock` field and its height #MUST equal $h - 1$.
] <rule:staking-vote-parent>

#rule("Parent approval", src: "internal/blockchain/validate.go · checkBlockContext, voteBitsApproveParent")[
  If the block's height is at least #param("StakeValidationHeight"), let $Y$
  be the number of votes in the stake tree whose vote bits have bit 0 set and
  $V$ the total number of votes. The votes *approve* the parent if
  $Y > V - Y$ (a strict majority; a tie disapproves). Bit 0 of the header's
  `VoteBits` #MUST be set if the votes approve the parent and #MUST be clear
  otherwise.
] <rule:staking-header-votebits>

What happens to the parent's regular tree when it is disapproved is specified
in #chref("blocks"): from height 2 on, a block whose header has bit 0 of
`VoteBits` clear undoes the effects of its parent's regular tree before its
own transactions are applied. Below #param("StakeValidationHeight") the header
value is fixed at `0x0001` (approve) by @rule:staking-early-header.

=== Votes and revocations against the ticket database <sec:staking-redeemers>

#algorithm("Ticket redeemer check for the block at height h", src: "internal/blockchain/validate.go · checkTicketRedeemers, checkBlockContext")[
  ```python
  def check_ticket_redeemers(block, h, parent: StakeState, auto_revocations_active):
      # h: height of block; parent: stake state of block h - 1
      vote_tickets = [tx.inputs[1].prev.hash for tx in block.stake_txs
                      if is_vote(tx) is not NOT_A_VOTE]
      revoke_tickets = [tx.inputs[0].prev.hash for tx in block.stake_txs
                        if is_revocation(tx)]
      has_vote = {w: False for w in parent.winners}
      for t in vote_tickets:
          if t not in has_vote:
              reject("vote for ineligible ticket")
          has_vote[t] = True
      newly_missed = {w for w, voted in has_vote.items() if not voted}
      expiring = set(expiring_in_block(parent, h))      # expiring-tickets rule
      revoked = set()
      for t in revoke_tickets:
          eligible = ((auto_revocations_active
                       and (t in newly_missed or t in expiring))
                      or t in parent.missed)
          if not eligible:
              reject("revocation of ineligible ticket")
          revoked.add(t)
      if auto_revocations_active:
          for t in newly_missed:
              if t not in revoked:
                  reject("missing revocation of missed ticket")
          for t in expiring:
              if t not in revoked:
                  reject("missing revocation of expired ticket")
  ```
] <alg:staking-redeemers>

#rule("Votes and revocations spend eligible tickets", src: "internal/blockchain/validate.go · checkTicketRedeemers, checkBlockContext")[
  If the block's height is at least #param("StakeValidationHeight"),
  @alg:staking-redeemers #MUSTNOT reject it. That is:
  + every vote #MUST spend one of the winners drawn on the parent;
  + if the `autorevocations` agenda is not active for the block, every
    revocation #MUST spend a ticket in the parent's missed set;
  + if it is active, every revocation #MUST spend a ticket that is in the
    parent's missed set, or is a winner of the parent without a vote in this
    block, or expires in this block (@rule:staking-expiring); and the block
    #MUST contain a revocation for every winner of the parent that has no vote
    in this block and for every ticket that expires in this block.
] <rule:staking-redeemers>

Duplicate spends of one ticket (two votes, two revocations, or a vote and a
revocation) are excluded by the ordinary double-spend rule, since all of them
spend output 0 of the ticket.

#rationale[
  #dcp(9) makes revocation automatic: as soon as a ticket is missed or
  expires, the block in which that happens must return its funds. Because a
  version-2 revocation needs no signature and its outputs are fully determined
  (@rule:staking-payee-value), the miner can always construct it.
]

#note[
  Tickets that became missed before #dcp(9) activated and were never revoked
  remain in the missed set and may still be revoked at any later height. The
  required revocations of a block number at most
  $floor(#param("TicketsPerBlock") / 2)$ missed winners (a valid block
  carries at least a majority of the votes) plus the tickets that became live together
  #param("TicketExpiry") blocks earlier (at most #param("MaxFreshStakePerBlock")),
  well below the limit of 255.
]

== Vote Bits and Vote Version <sec:staking-votebits>

Each vote carries 16 *vote bits* (bytes 2–3 of output 1, little-endian) and,
optionally, a 32-bit *vote version* (bytes 4–7). At the transaction level only
two things are defined here:

- *Bit 0* (`0x0001`, dcrd `BlockValid`) is the voter's verdict on the regular
  tree of the block voted on: set means approve, clear means disapprove. The
  verdicts of the votes in a block are combined by
  @rule:staking-header-votebits.
- The *vote version* is the little-endian `uint32` at bytes 4–7 of the vote
  bits script if that script is at least 8 bytes long, and 0 otherwise.

#figure(
  caption: [Extraction of the vote fields from vote output 1 (script $s$)],
  table(
    columns: (auto, 1fr),
    table.header([Field], [Value]),
    [vote bits], [$"LE"_16(s[2:4])$],
    [approves parent], [$("vote bits" "AND" "0x0001") != 0$],
    [vote version], [$"LE"_32(s[4:8])$ if $|s| >= 8$, else 0],
    [voted block hash], [$s_0[2:34]$ of output 0 (internal byte order)],
    [voted block height], [$"LE"_32(s_0[34:38])$ of output 0],
  ),
) <tab:staking-vote-fields>

The meaning of bits 1–15 (choices on consensus rule changes, each agenda
occupying a masked group of bits), how the vote version of the votes in a
block feeds the stake version and the rule-change tallies, and which votes are
counted, are specified in #chref("voting"). No stake rule constrains bits 1–15
or the vote version; a vote with any values is valid as far as this chapter is
concerned.

== Non-Consensus Behavior <sec:staking-policy>

The following is policy: it describes what dcrd's mempool, block template
generator and wallets do, not what a block must satisfy. Details are in
#chref("policy").

- *Automatic revocations.* Once #dcp(9) is active, dcrd's block template
  generator creates a version-2, zero-fee revocation for every ticket that the
  block must revoke (#src("blockchain/stake/staketx.go",
  "CreateRevocationFromTicket")), computing outputs with the same return
  amount algorithm.
- *Ticket exhaustion.* The template generator refuses to produce a block
  template whose ticket purchases are too few to keep at least
  #param("TicketsPerBlock") live tickets after the ticket maturity period,
  counting all immature tickets and the votes that will consume tickets
  (#src("internal/blockchain/validate.go", "checkTicketExhaustion")). This is
  not a consensus rule; it prevents miners from producing a chain that
  @rule:staking-transition would make impossible to extend.
- *Fee limits.* The fee limits are chosen by the wallet that builds the
  ticket. The tickets in dcrd's regression-network test data, such as the one
  in the vector of @sec:staking-ticket-inputs, set the revocation fee flag
  with $k_"rev" = 24$ and leave the vote fee flag clear, so their votes pay no
  fee beyond the rounding remainder.
- *Stake tree order.* Apart from the treasurybase, which must come first when
  the treasury agenda is active, the order of stake transactions is left to
  the block producer; no order is required by consensus.

== Error Kinds (informative) <sec:staking-errors>

dcrd reports each violation with an error kind. @tab:staking-errors maps the
error kinds whose subject is a ticket, vote or revocation to the rules of this
chapter, as a cross-check for implementers comparing behavior with dcrd. The
kind reported for an invalid block depends on the order of dcrd's checks and
is not part of consensus.

#figure(
  caption: [Stake-related dcrd error kinds and the rules that cover them],
  table(
    columns: (1fr, 10em),
    table.header([Error kind(s)], [Rule]),
    [`ErrSStxTooManyInputs`, `ErrSStxTooManyOutputs`, `ErrSStxNoOutputs`,
      `ErrSStxInvalidOutputs`, `ErrSStxInOutProportions`],
      [@alg:staking-check-ticket (the transaction is not a ticket)],
    [`ErrSSGenWrongNumInputs`, `ErrSSGenTooManyOutputs`, `ErrSSGenNoOutputs`,
      `ErrSSGenNoStakebase`, `ErrSSGenWrongIndex`, `ErrSSGenWrongTxTree`,
      `ErrSSGenBadGenOuts`, `ErrSSGenNoReference`, `ErrSSGenBadReference`,
      `ErrSSGenNoVotePush`, `ErrSSGenBadVotePush`, `ErrSSGenInvalidTxVersion`],
      [@alg:staking-check-vote (not a vote)],
    [`ErrSSGenInvalidDiscriminatorLength`, `ErrSSGenInvalidNullScript`,
      `ErrSSGenUnknownDiscriminator`, `ErrSSGenInvalidTVLength`,
      `ErrSSGenInvalidTreasuryVote`, `ErrSSGenDuplicateTreasuryVote`],
      [@alg:treasury-vote-parse (not a vote)],
    [`ErrSSRtxWrongNumInputs`, `ErrSSRtxTooManyOutputs`, `ErrSSRtxNoOutputs`,
      `ErrSSRtxBadOuts`, `ErrSSRtxWrongTxTree`, `ErrSSRtxInputHasSigScript`,
      `ErrSSRtxInvalidFee`], [@alg:staking-check-revocation (not a
      revocation)],
    [`ErrStakeTxInRegularTree`, `ErrRegTxInStakeTree`],
      [@rule:staking-tree-membership],
    [`ErrNonstandardStakeTx`], [@rule:staking-allowed-types],
    [`ErrNotEnoughStake`, `ErrStakeBelowMinimum`], [@rule:staking-ticket-price],
    [`ErrTicketInputScript`; `ErrMissingTxOut` for a ticket input],
      [@rule:staking-ticket-inputs],
    [`ErrTicketCommitment`], [@rule:staking-ticket-commitment],
    [`ErrBadStakebaseScriptLen`, `ErrBadStakebaseScrVal`],
      [@rule:staking-stakebase-script],
    [`ErrBadTxInput` (null ticket input)], [@rule:staking-ticket-input-not-null],
    [`ErrInvalidRevocationTxVersion`], [@rule:staking-rev-version],
    [`ErrScriptValidation` (revocation input)], [@rule:staking-rev-scripts],
    [`ErrInvalidVoteInput`, `ErrInvalidRevokeInput`],
      [@rule:staking-ticket-index, @rule:staking-submission-input],
    [`ErrMissingTxOut` for a ticket input of a vote or revocation],
      [@rule:staking-ticket-available],
    [`ErrImmatureTicketSpend`], [@rule:staking-spend-maturity],
    [`ErrBadNumPayees`], [@rule:staking-num-payees,
      @rule:staking-tvote-agenda],
    [`ErrBadPayeeScriptVersion`, `ErrBadPayeeScriptType`,
      `ErrMismatchedPayeeHash`], [@rule:staking-payee-script],
    [`ErrBadPayeeValue`], [@rule:staking-payee-value],
    [`ErrBadStakebaseAmountIn`], [@rule:staking-stakebase-amount],
    [`ErrSSGenSubsidy`, `ErrBadStakebaseValue`], [@rule:staking-stakebase-total],
    [`ErrTxSStxOutSpend`], [@rule:staking-sstx-spend],
    [`ErrImmatureSpend` for a stake-tagged output],
      [@rule:staking-stake-output-maturity],
    [`ErrMissingTxOut` for a same-block spend], [@rule:staking-same-block],
    [`ErrUnknownTicketSpent`, `ErrMissingTicket`, `ErrDuplicateTicket`, and the
      untyped "cannot pick unique ticket indexes" error],
      [@rule:staking-transition],
    [`ErrInvalidEarlyStakeTx`], [@rule:staking-early-header,
      @rule:staking-early-stake-txs],
    [`ErrInvalidEarlyVoteBits`, `ErrInvalidEarlyFinalState`],
      [@rule:staking-early-header],
    [`ErrNotEnoughVotes`], [@rule:staking-min-votes],
    [`ErrTooManyVotes`], [@rule:staking-max-votes],
    [`ErrTooManySStxs`], [@rule:staking-max-freshstake],
    [`ErrFreshStakeMismatch`], [@rule:staking-freshstake],
    [`ErrPoolSize`], [@rule:staking-poolsize],
    [`ErrInvalidFinalState`], [@rule:staking-finalstate],
    [`ErrNoStakeTx`], [@rule:staking-nonempty],
    [`ErrVotesMismatch`], [@rule:staking-voters],
    [`ErrTooManyRevocations`, `ErrRevocationsMismatch`],
      [@rule:staking-revocations],
    [`ErrVotesOnWrongBlock`], [@rule:staking-vote-parent],
    [`ErrIncongruentVotebit`], [@rule:staking-header-votebits],
    [`ErrTicketUnavailable` (ineligible vote), `ErrInvalidSSRtx`,
      `ErrNoMissedTicketRevocation`, `ErrNoExpiredTicketRevocation`],
      [@rule:staking-redeemers],
    [`ErrTicketUnavailable` (in the stakebase total checks)], [Unreachable:
      the ticket output was loaded by the earlier input checks.],
    [`ErrSerializeHeader`], [Unreachable: header serialization cannot fail.],
    [`ErrTicketExhaustion`], [Policy only (@sec:staking-policy).],
    [`ErrSStxBadCommitAmount`, `ErrSStxBadChangeAmts`,
      `ErrSSRtxInvalidTxVersion`, `ErrDatabaseCorrupt`, `ErrMissingDatabaseTx`,
      `ErrMemoryCorruption`], [Not consensus: raised only by helper, wallet,
      mining or database code.],
    [`ErrSStxInvalidInputs`, `ErrSStxVerifyCalcAmts`, `ErrVerSStxAmts`,
      `ErrVerifyInput`, `ErrVerifyOutType`, `ErrVerifyTooMuchFees`,
      `ErrVerifySpendTooMuch`, `ErrVerifyOutputAmt`, `ErrVerifyOutPkhs`,
      `ErrFindTicketIdxs`], [Defined but never raised by dcrd at this commit.],
  ),
) <tab:staking-errors>
