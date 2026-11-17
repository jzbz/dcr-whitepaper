#import "../template.typ": *

= Introduction <ch:intro>

Decred is a cryptocurrency that has been in continuous operation since its
genesis block of 8 February 2016. It descends from Bitcoin @bitcoin, from
which it inherits the unspent-output ledger, the script-guarded transaction
model, and a chain of blocks secured by proof of work. Its distinguishing
feature is who has the final say. In Decred that is the holders of the
currency, acting through an on-chain mechanism that lets them approve or
reject each block that miners produce, vote on changes to the consensus rules,
and authorize every payment from a common treasury.

This chapter is informative. It describes the system as a whole so that the
normative chapters that follow can be read in context, and it ends with a
guide to the rest of the document.

== Motivation <sec:intro-motivation>

A pure proof-of-work currency places two distinct powers in the same hands.
Miners order transactions, which is the job proof of work was designed for,
but they also hold an effective veto over changes to the rules, because a rule
change only takes hold if the blocks that follow it are mined. Those who hold
the currency and bear the consequences of a rule change have no formal voice.
In practice, contested changes are settled by informal negotiation between
developers, miners, exchanges and users, with no agreed procedure and no
agreed way of telling when a decision has been made.

A second difficulty is funding. A decentralized currency has no owner to pay
for its development. Projects have relied on donations, on companies whose
interests may diverge from the network's, or on a founders' allocation that is
eventually spent.

Decred addresses both with one construction. Earlier proposals had shown how
proof of stake could be layered on proof of work so that stakeholders
participate in block production @poa @memcoin2, and Decred's original design
@dtb001 adopted a scheme of that kind. Coins are time-locked in exchange for
_tickets_; tickets are called at random to vote; and a block is only valid if
a majority of the tickets called for it have voted. Once every block carries
stakeholder votes, the same votes can carry other decisions, and Decred uses
them for three things:

+ *Block approval.* Each vote states whether the previous block's ordinary
  transactions should stand. A block that is voted down keeps its place in the
  chain, but its ordinary transactions are undone and its miner is not paid.
+ *Consensus rule changes.* New rules are deployed in software in a dormant
  state and take effect only if a supermajority of votes over a fixed period
  approve them (#chref("voting")).
+ *Treasury expenditure.* A fixed share of every block reward accrues to a
  treasury. Since the activation of #dcp(6) the treasury exists only as a
  balance in the consensus state and can be spent only by a transaction that
  a supermajority of votes has approved (#chref("treasury")); before that,
  the share was paid to a fixed script controlled by the project's
  developers.

== The System at a Glance <sec:intro-overview>

Four roles interact through the protocol.

/ Miners: assemble transactions and votes into blocks and expend computation
  to find a block header whose hash meets the proof-of-work target
  (#chref("difficulty")). The hash function has been BLAKE3 since a 2023 rule
  change; before that it was BLAKE-256.
/ Stakeholders: lock funds to buy tickets, and vote when their tickets are
  called (#chref("staking")). A ticket holder may delegate the act of voting
  to an always-online service without giving up custody of the funds
  (#chref("ecosystem")).
/ Full nodes: verify every block against every rule in this document and
  relay valid blocks and transactions to their peers (#chref("p2p")). A full
  node trusts no one: it accepts only what it has verified.
/ Light clients: verify block headers only and use compact filters, to which
  every header since #dcp(5) commits, to find the transactions that concern them without
  revealing which those are (#chref("filters")).

The ledger itself is a set of unspent transaction outputs. Each output holds
an amount and a script; a transaction consumes existing outputs by satisfying
their scripts and creates new ones (#chref("script"), #chref("transactions")).
Every block contains two separate lists of transactions. The *regular tree*
holds ordinary payments and the miner's reward. The *stake tree* holds ticket
purchases, votes, ticket revocations and treasury transactions. The split
exists because the two are treated differently when a block is voted down:
the stake tree always stands, while the regular tree is subject to the
approval of the next block's voters.

== The Life of a Block <sec:intro-lifecycle>

The target interval between blocks on the main network is five minutes.
@fig:intro-lifecycle shows how proof of work and proof of stake alternate.

#let stage(title, body) = box(
  width: 100%,
  stroke: 0.6pt + palette.ink,
  radius: 3pt,
  inset: (x: 7pt, y: 7pt),
  {
    set par(justify: false, leading: 0.5em)
    set align(left)
    text(font: sans, size: 8.4pt, weight: "semibold", fill: palette.ink, title)
    v(0.45em, weak: true)
    text(font: sans, size: 7.4pt, fill: palette.text, body)
  },
)
#let arrow = text(size: 13pt, fill: palette.teal, sym.arrow.r)

#figure(
  caption: [One step of the chain. Block $N$ cannot be built until a majority
    of the tickets drawn by block $N-1$ have voted on block $N-1$.],
  grid(
    columns: (1fr, auto, 1fr, auto, 1fr),
    column-gutter: 5pt,
    align: horizon,
    stage([Block $N-1$ is mined], [Its header seeds a lottery that draws five
      tickets from the pool of live tickets.]),
    arrow,
    stage([Tickets vote], [Each drawn ticket publishes a vote transaction
      that approves or disapproves the regular tree of block $N-1$.]),
    arrow,
    stage([Block $N$ is mined], [It includes at least three of the five
      votes, commits to their verdict, and draws the tickets for block $N+1$.]),
  ),
) <fig:intro-lifecycle>

In more detail:

+ When a block is connected to the chain, a deterministic pseudorandom
  generator seeded with the block's header selects #param("TicketsPerBlock")
  $= 5$ winning tickets from the pool of live tickets. Every node computes the
  same winners.
+ The holders of the winning tickets validate the block and broadcast a vote
  for it. A vote is a transaction that spends the ticket. It names the block
  being voted on, carries a bit approving or disapproving that block's regular
  tree, carries the holder's choices on any rule changes being voted, and pays
  the holder back the ticket price plus a share of the block reward.
+ A miner collects the votes and builds the next block on top of the block
  voted on. The new block is valid only if it contains votes from more than
  half of the winning tickets, that is at least three. The miner's own reward
  shrinks in proportion to any votes left out, so miners have reason to
  include all five.
+ Unless more of the included votes approve than disapprove, the previous block's
  regular tree is treated as though it had never been mined: its transactions
  return to the pool of unconfirmed transactions and its miner's reward is
  never created. The chain nevertheless continues on top of it.

The effect is that miners cannot extend the chain alone. A miner with a large
share of the hash power who withholds blocks, mines empty blocks, or censors
transactions can be denied the reward by the stakeholders, and a chain built
in secret cannot be extended without the cooperation of tickets that its
author does not control. Conversely, stakeholders cannot produce blocks
without proof of work.

== Tickets <sec:intro-tickets>

A ticket is bought by a transaction that locks the *ticket price* in an
output that only a vote or a revocation can spend. The minimum price is the same
for every ticket bought in a given block and is recomputed every
#param("StakeDiffWindowSize") $= 144$ blocks by an algorithm that steers the
number of live tickets toward a target of
#param("TicketPoolSize") $times$ #param("TicketsPerBlock") $= 40960$
(#chref("difficulty")). At most #param("MaxFreshStakePerBlock") $= 20$ tickets
may be bought per block.

A ticket then passes through the following stages.

/ Immature: for #param("TicketMaturity") $= 256$ blocks after purchase the
  ticket cannot be drawn.
/ Live: the ticket is in the pool and is drawn with equal probability to
  every other live ticket. With the pool at its target size a ticket waits
  8192 blocks, about 28 days, on average.
/ Voted: when drawn, the ticket votes; the price is returned together with
  the reward.
/ Missed: if the ticket is drawn and its vote is not included in a block, it
  loses the reward for that drawing and can never vote.
/ Expired: a ticket that has not been drawn within #param("TicketExpiry")
  $= 40960$ blocks, about 142 days, leaves the pool. With the pool at target
  this happens to fewer than one ticket in a hundred.
/ Revoked: a missed or expired ticket is revoked, returning the ticket price
  to its buyer without a reward. Since 2022 revocations are created
  automatically by the block that causes them.

Because the funds are locked for an unpredictable period, and are returned
without reward if the holder fails to vote, tickets represent a real and
recurring commitment to the network by those who hold its currency.

== Issuance <sec:intro-issuance>

New coins are created by each block. The reward began at 31.19582664 DCR per
block and is multiplied by $100 \/ 101$ every
#param("SubsidyReductionInterval") $= 6144$ blocks, about every 21 days, which
produces a smooth decline in place of Bitcoin's abrupt halvings. Total
issuance converges on approximately 21 million DCR. The first block after
genesis additionally created a fixed allocation that was divided between the
original developers and an airdrop to early participants
(#chref("subsidy")).

Each block's reward is divided between the miner, the voters and the
treasury. The division has been changed twice by stakeholder vote, as
@tab:intro-split shows.

#figure(
  caption: [Division of the block reward],
  table(
    columns: (1fr, auto, auto, auto),
    align: (left, right, right, right),
    table.header([Period], [Proof of work], [Proof of stake], [Treasury]),
    [From launch], [60%], [30%], [10%],
    [After #dcp(10) (2022)], [10%], [80%], [10%],
    [After #dcp(12) (2023)], [1%], [89%], [10%],
  ),
) <tab:intro-split>

== Governance <sec:intro-governance>

The consensus rules of a blockchain are whatever its full nodes enforce, so
changing them requires that nodes change in step. Decred makes that
coordination explicit and puts the decision to a vote.

A proposed change is specified in a Decred Change Proposal and implemented in
the node software, where it lies dormant. Once enough miners and voters have
upgraded, the change is put to the tickets as an _agenda_. Voting runs in
fixed intervals of #param("RuleChangeActivationInterval") $= 8064$ blocks,
about four weeks. If, in one interval, the yes votes are at least 75% of the
votes that expressed a preference (in the integer arithmetic of
#chref("voting")), and enough such votes were cast to meet quorum,
the change is locked in; it activates exactly one interval later, giving the
remaining nodes four weeks to upgrade. The state of every agenda is a
function of the chain alone, so all nodes agree on precisely which rules
apply to each block. #chref("voting") specifies the mechanism.

@tab:intro-dcps lists the rule changes adopted in this way. Each is described
in full in the chapter concerned, and because a node must validate the whole
chain from its first block, each remains part of the specification in both
its before and after forms.

#figure(
  caption: [Consensus changes adopted by stakeholder vote],
  table(
    columns: (auto, auto, 1fr),
    table.header([Proposal], [Agenda], [Change]),
    [#dcp(1)], [`sdiffalgorithm`], [New ticket price algorithm],
    [#dcp(2), #dcp(3)], [`lnfeatures`], [`OP_SHA256` and relative lock times, in support of payment channels],
    [#dcp(4)], [`fixlnseqlocks`], [Correction to the evaluation of relative lock times],
    [#dcp(5)], [`headercommitments`], [Block headers commit to compact filters for light clients],
    [#dcp(6)], [`treasury`], [Decentralized treasury controlled by stakeholder vote],
    [#dcp(7)], [`reverttreasurypolicy`], [Revised limit on treasury expenditure],
    [#dcp(8)], [`explicitverupgrades`], [New transaction and script versions must be enabled by vote],
    [#dcp(9)], [`autorevocations`], [Automatic revocation of missed and expired tickets],
    [#dcp(10)], [`changesubsidysplit`], [Block reward division changed to 10/80/10],
    [#dcp(11)], [`blake3pow`], [Proof of work changed to BLAKE3; new difficulty algorithm],
    [#dcp(12)], [`changesubsidysplitr2`], [Block reward division changed to 1/89/10],
    [#dcp(13)], [`maxtreasuryspend`], [New limit on treasury expenditure],
  ),
) <tab:intro-dcps>

Treasury spending follows a parallel path. A treasury spend transaction is
published in advance and voted on by the tickets over a window of blocks; it
is valid in a block only if it gathered the required quorum and at least 60%
approval, and only if it keeps total expenditure within a limit set by the
consensus rules (#chref("treasury")). What to fund is debated off-chain in a
proposal system described in #chref("ecosystem").

== Design Properties <sec:intro-properties>

Several properties of the design are worth stating before the detail.

/ Transaction identifiers cannot be altered by third parties: a transaction's
  identifier is computed over its inputs' references and its outputs, and
  excludes the signatures (#chref("encoding")). Protocols that build chains
  of unconfirmed transactions, such as payment channels, rely on this.
/ Signatures are not limited to one scheme: scripts can verify ECDSA and
  Schnorr signatures over secp256k1 and Ed25519 signatures
  (#chref("crypto"), #chref("script")).
/ Scripts are versioned: every output carries a script version, so new script
  languages can be introduced without disturbing existing outputs.
/ Transactions can expire: a transaction may name a height from which it can
  no longer be mined, so its fate is settled within a known time.
/ Headers are self-describing: each header records the ticket pool size, the
  number of votes, tickets and revocations in the block, the ticket price,
  and the outcome of the lottery, which lets header-only clients follow the
  stake system.

Readers who know Bitcoin's protocol will find a summary of the differences in
#chref("bitcoin-differences").

== Scope and Structure of this Document <sec:intro-scope>

The document specifies the protocol: what is valid, and how nodes
communicate. It does not describe how the reference implementation is
organized, how it stores the chain on disk, or its remote procedure call
interface, none of which another implementation need share.

- *Part I* lays the foundations: the conventions used throughout
  (#chref("conventions")), the cryptographic primitives (#chref("crypto")),
  the serialization of transactions and blocks (#chref("encoding")), and keys
  and addresses (#chref("addresses")).
- *Part II* specifies the script language (#chref("script")) and the rules
  for individual transactions (#chref("transactions")).
- *Part III* specifies consensus: tickets and votes (#chref("staking")),
  proof of work and both difficulty algorithms (#chref("difficulty")), block
  validation and chain selection (#chref("blocks")), issuance
  (#chref("subsidy")), the treasury (#chref("treasury")), rule changes
  (#chref("voting")), and the parameters of each network
  (#chref("parameters")).
- *Part IV* covers the network: the peer-to-peer protocol (#chref("p2p")),
  compact filters and light clients (#chref("filters")), relay and mining
  policy (#chref("policy")), coin mixing (#chref("mixing")), and the systems
  built around the chain (#chref("ecosystem")).
- The *appendices* give the complete opcode table (#chref("opcodes")), an
  index of every consensus rule (#chref("rule-index")), and a comparison with
  Bitcoin (#chref("bitcoin-differences")).

Consensus rules are confined to Parts II and III and to the parts of
#chref("crypto"), #chref("encoding") and #chref("filters") on which they
depend. An implementation that follows those chapters exactly will agree with
the network on every block. The remaining chapters describe conventions that
a node must follow to be useful to its peers and its users, but on which the
validity of the chain does not depend.
