#import "../template.typ": *

= Governance and Ecosystem <ch:ecosystem>

The preceding chapters specify the consensus protocol. This chapter describes,
at overview level, the systems built around it that give Decred its character:
the governance process that decides what the treasury pays for and which rule
changes are proposed, the voting service providers that let ticket holders
vote without running servers, the wallet and its light-client mode, payment
channels, atomic swaps and the decentralized exchange, and the timestamping
service that anchors off-chain data in the chain.

#note[
  This chapter is informative. Nothing in it affects the validity of any block
  or transaction. Where a system relies on a consensus rule, the rule is
  specified in the chapter referenced; where a system has its own parameters
  (Politeia vote thresholds, VSP fees, DEX epochs), those are properties of
  that software, chosen by its operators, and can change without any change to
  the consensus rules.
]

Facts in this chapter are taken from the Decred documentation @dcrdocs, the
DCPs, dcrd, and the source and documentation of the software concerned
(@politeia, @vspd, @dcrwallet, @dcrdex, and the `dcrlnd` and `dcrtime`
repositories). The documentation is in places older than the software; where
the two disagree, the software is followed and the difference is noted.

== The Governance Model <sec:ecosystem-model>

Decred's governance rests on a single credential: the ticket
(#chref("staking")). A stakeholder time-locks coins to buy a ticket, and the
ticket confers a vote. That vote is exercised in four places, which differ in
whether the outcome is enforced by consensus.

/ Block approval: Each block includes votes from the tickets the lottery
  selected for it. Of the #param("TicketsPerBlock") $= 5$ tickets selected, a
  block at or above the stake validation height must contain votes from at
  least $floor(5 slash 2) + 1 = 3$, and the
  votes decide whether the regular
  transaction tree of the previous block, including its proof-of-work
  subsidy, stands: it is approved only if a strict majority of the included
  votes approve it (#chref("blocks")). This is the check stakeholders hold over
  miners.
/ Consensus rule changes: Votes also carry the ticket holder's preference on
  each open _agenda_, a dormant rule change shipped in node software and
  specified by a DCP. Agendas are tallied over rule change intervals of
  #param("RuleChangeActivationInterval") $= 8064$ blocks; an agenda locks in
  when at least #param("RuleChangeActivationQuorum") $= 4032$ non-abstaining
  votes are cast in an interval and at least
  #param("RuleChangeActivationMultiplier")/#param("RuleChangeActivationDivisor")
  $= 3 slash 4$ of them choose it, and the new rules become active one interval
  later (#chref("voting")).
/ Treasury spends: Since #dcp(6) the treasury is an account that can be debited
  only by a _treasury spend_ (tspend) transaction. A tspend is authored and
  signed by the holder of one of the well-known Politeia keys
  (#param("PiKeys")), but it is valid only after enough ticket votes approve
  it on chain (#chref("treasury")).
/ Proposals: Decisions about the direction of the project, and in particular
  which work the treasury should fund, are made by off-chain ticket votes on
  proposals submitted to Politeia (@sec:ecosystem-politeia). These votes are
  cryptographically verifiable but are not enforced by the consensus rules.

The first three are part of the consensus protocol; the fourth is a social
process that culminates in the third. @tab:ecosystem-votes compares them, and
@fig:ecosystem-flows shows how a funding proposal and a consensus change each
travel from idea to effect.

#figure(
  caption: [The four uses of a ticket vote. Values are main-network values.],
  table(
    columns: (auto, 1fr, 1fr, 1fr, 1fr),
    table.header([], [Block approval], [Rule change agenda], [Treasury spend], [Politeia proposal]),
    [Where], [Vote transaction, every block], [Vote bits in vote transactions], [Treasury vote data in vote transactions], [Signed message to Politeia server],
    [Who votes], [The (at most 5) tickets selected for the block], [Every ticket that votes in the interval], [Every ticket that votes in the window], [Every ticket live in the snapshot],
    [Duration], [One block], [8064 blocks per interval], [$288 times 12 = 3456$ blocks], [2016 to 4032 blocks],
    [Quorum], [At least 3 votes in the block], [4032 non-abstaining votes], [$1 slash 5$ of the maximum votes in the window], [20% of eligible tickets (by convention)],
    [Threshold], [Strict majority approve], [75% of non-abstaining votes, in integer arithmetic (#chref("voting"))], [60% yes, with votes still possible counted as no], [60% of votes cast (by convention)],
    [Enforced by], [Consensus], [Consensus], [Consensus], [Not enforced; signals intent],
  ),
) <tab:ecosystem-votes>

#let flowbox(body, chain: false) = rect(
  width: 100%,
  inset: (x: 6pt, y: 4.5pt),
  radius: 2pt,
  fill: if chain { palette.wash-teal } else { palette.wash },
  stroke: 0.6pt + (if chain { palette.teal } else { palette.hairline }),
  {
    set par(justify: false, leading: 0.45em)
    set text(size: 7.8pt)
    body
  },
)
#let flowarrow = align(center, block(above: 1.5pt, below: 1.5pt, text(size: 8pt, fill: palette.muted, sym.arrow.b)))
#let flowhead(body) = align(center, text(font: sans, size: 8.4pt, weight: "semibold", fill: palette.ink, body))
#let flow(..steps) = stack(dir: ttb, ..steps.pos().map(s => (s, flowarrow)).flatten().slice(0, -1))

#figure(
  caption: [How a funding proposal (left) and a consensus rule change (right)
    take effect. Shaded steps are enforced by the consensus rules; the rest are
    off-chain processes.],
  {
    grid(
      columns: (1fr, 1fr),
      column-gutter: 9mm,
      row-gutter: 3mm,
      flowhead[Proposal to treasury payout], flowhead[DCP to activation],
      flow(
        flowbox[*Submission* to Politeia; fee paid; server returns a signed censorship record.],
        flowbox[*Discussion*; author may edit. Content anchored hourly in the chain via dcrtime.],
        flowbox[*Author authorizes* the vote; an admin starts it. Eligible tickets: the live pool 256 blocks below the tip.],
        flowbox[*Ticket vote*, 2016 to 4032 blocks; ballots signed with each ticket's commitment-address key.],
        flowbox[*Approved* (quorum 20%, 60% yes): work proceeds; contractor invoices billed against the budget.],
        flowbox(chain: true)[*Treasury spend* signed with a Pi key, broadcast to the mempool.],
        flowbox(chain: true)[*On-chain tspend vote* over 3456 blocks: quorum 1/5, 60% yes.],
        flowbox(chain: true)[*Tspend mined* in a block on a treasury vote interval; outputs pay recipients.],
      ),
      flow(
        flowbox[*DCP* written, specifying the change and its agenda.],
        flowbox[*Node software* released with the agenda dormant.],
        flowbox(chain: true)[*Network upgrade*: block and stake versions reach their thresholds (#chref("voting")).],
        flowbox(chain: true)[*Voting* over 8064-block rule change intervals; ticket votes carry vote bits.],
        flowbox(chain: true)[*Locked in*: quorum 4032 non-abstaining votes, 75% yes. (75% no: failed.)],
        flowbox(chain: true)[*Active* one interval (8064 blocks) later; every node enforces the new rules.],
      ),
    )
  },
) <fig:ecosystem-flows>

#history[
  Before #dcp(6) activated, the treasury share of each block subsidy was paid
  to a fixed multisignature address held by Decred Holdings Group LLC (DHG),
  and contractor invoices were paid by DHG by hand; DCP-0006 describes this
  process and replaces it with stakeholder-approved treasury spends. The
  documentation's description of Politeia still refers to payment by DHG
  (#link("https://docs.decred.org/governance/politeia/overview/")[Politeia
  overview]); that text predates DCP-0006.
]

== Politeia <sec:ecosystem-politeia>

Politeia is the system in which proposals are submitted, discussed and voted
on. Its README describes it as a store of off-chain data that is versioned and
timestamped, "git plus timestamping" @politeia: rather than putting governance
data on chain, Politeia keeps it off chain and anchors commitments to it in the
Decred chain. Proposals are of two kinds: those that seek stakeholder support
for a course of action or a policy, and those that request treasury funding
for a budget that the proposer draws down against as work is delivered.

=== Components and identities

The server side consists of `politeiad`, the data layer, and `politeiawww`, the
user-facing web backend; `politeiad` relies on a `dcrtime` server
(@sec:ecosystem-dcrtime) for anchoring. Functionality is organized as plugins:
general-purpose plugins such as `comments` and `ticketvote`, and an
application plugin (`pi` for the proposal system) that adds behaviour specific
to the application.

Every Politeia user has an Ed25519 key pair, generated in the browser at
registration. The user signs every submission (proposal, edit, comment,
comment up/down vote, vote authorization) with it, and the server returns a
_receipt_, its own Ed25519 signature over the user's signature. Each side can
therefore prove what the other said.

=== Censorship resistance

Administrators can censor submissions, for spam or for content the system
cannot host, but only transparently. When a record is submitted the server
returns a _censorship record_ consisting of a random token identifying the
record, the Merkle root (SHA-256) of the record's files, and the server's
signature over the Merkle root and token. A user whose proposal is censored
can publish the censorship record and the files: the server's signature proves
that the server received exactly that content, and the anchoring described
next proves when. Censored proposals remain visible to their author with the
reason given. The `politeiaverify` tool checks censorship records, receipts,
user signatures and timestamps from the bundles Politeia offers for download.

=== Anchoring in the chain

The current backend stores each record in an append-only, Merkle-tree-backed
log (a Trillian log, replacing the original git backend in 2021). At minute 56
of every hour, `politeiad` collects every log that has leaves not yet anchored
and submits a SHA-256 digest of each log's current root to `dcrtime`. `dcrtime`
aggregates the digests it receives into a single Merkle root and publishes it
in a transaction (@sec:ecosystem-dcrtime). `politeiad` considers the anchor
complete once `dcrtime` reports the block timestamp of the anchoring
transaction, which it does only after the transaction has 6 confirmations, and
then appends an anchor leaf to each anchored log. The result is a chain of
evidence from any piece of Politeia data to a block: a Merkle inclusion proof
into the log root, a Merkle path from the log root's digest to the `dcrtime`
root, and the transaction that carries that root.

#note[
  The documentation describes the earlier git backend, in which data was
  committed to a public git repository and each commit hash was anchored
  hourly (@dcrdocs, "dcrtime" and "Navigating Politeia Data"). The principle
  is unchanged; only the data structure differs.
]

=== Proposal lifecycle

+ *Registration and submission.* Creating an account and submitting a proposal
  each require a payment in DCR to an address the server provides (a
  registration "paywall" and per-proposal credits). The documentation gives
  both fees as 0.1 DCR, subject to change if they fail to deter spam or the
  price of DCR changes significantly. A funding proposal states the amount
  requested (in US cents), start and end dates, and a domain.
+ *Review.* An administrator reviews the proposal and either makes it public
  or censors it.
+ *Discussion.* A public proposal can be discussed and its author can publish
  new versions in response. Comment up/down votes are public and only affect
  display order. An administrator may mark an inactive proposal _abandoned_
  until the author authorizes voting.
+ *Authorization and start.* The author authorizes the vote by signing the
  proposal token, version and action; after this the proposal can no longer be
  edited. An administrator then starts the vote by signing the vote
  parameters: duration in blocks, quorum percentage, pass percentage and the
  vote options (`yes` and `no` with their bits).
+ *Voting.* Ticket holders vote from their wallets (Decrediton or the
  `politeiavoter` tool) for the duration of the vote.
+ *Outcome.* When the end height is reached the proposal is _approved_ or
  _rejected_. An approved funding proposal becomes _active_, is billed against
  as work is delivered, and is finally marked _completed_, or _closed_ by an
  administrator if the author fails to deliver.

A second vote type, the _runoff_, lets several proposals submitted in response
to a request for proposals compete: each is voted on normally, and the one
that meets quorum and pass requirements with the most net yes votes wins.

=== Ticket voting

When an administrator starts a vote, the server takes a snapshot of the live
ticket pool at height $h - #param("TicketMaturity")$, where $h$ is the best
block height and #param("TicketMaturity") $= 256$ on the main network; the
code's comment explains the offset as moving the snapshot into territory that
will not be reorganized. The snapshot block's height and hash become the vote's
start, the list of ticket hashes in the pool at that block is recorded as the
eligible set, and the end height is the snapshot height plus the duration plus
#param("TicketMaturity"). On the main network the duration must lie between
2016 and 4032 blocks; at the 5-minute target block time, 2016 blocks is one
week. A ticket bought after the snapshot cannot vote, and a ticket that is
called to vote on chain during the vote can still vote on the proposal until
the end.

A vote, called a ballot entry, names the proposal token, the ticket hash and
the chosen vote bit, and carries a signature over the concatenation
`token || ticket || votebit` (each as its hex string). The signature is a
Decred signed message (a compact, public-key-recoverable secp256k1 ECDSA
signature over the BLAKE-256 hash of the length-prefixed string
`"Decred Signed Message:\n"` followed by the length-prefixed message) made with
the
key of the ticket's _largest commitment address_: the address, among the
ticket's reward commitments, that committed the largest amount
(#chref("staking")). The server verifies that the ticket is in the eligible
set and has not already voted, looks up the commitment address from the
ticket transaction, verifies the signature, and returns a receipt.

The commitment address, not the voting address, signs because the commitment
address belongs to the owner of the funds. A ticket whose on-chain voting
rights are delegated to a voting service provider (@sec:ecosystem-vsp) is
still voted on Politeia by its owner.

Results are verifiable by anyone. The vote parameters, the eligible ticket
list and every signed ballot are public; each ballot can be checked against
the ticket's commitment address taken from the chain, each ticket against the
snapshot block, and all of it against the anchors. The approval rule is that
the number of votes cast is at least the quorum percentage of the eligible
tickets and the `yes` votes are at least the pass percentage of the votes
cast. The percentages are parameters of each vote; the documentation and the
Decred constitution give them as 20% quorum and 60% approval, with a default
duration of 2016 blocks. To reduce timing correlation between a voter's
tickets, `politeiavoter` can trickle votes over the voting period, which is
effective only when it connects through Tor.

=== What is and is not binding

A Politeia vote changes no consensus state. Its force comes from the people
who act on it: approved funding proposals are paid by treasury spends, which
the Pi key holders author and which ticket holders must then approve on chain
(@sec:ecosystem-model). Stakeholders therefore vote on funding twice, once
on the proposal and again on each tspend, and the second vote is the binding
one. Policy proposals, including amendments to the Decred constitution, bind
only by convention. Consensus rule changes are not decided on Politeia; they
are decided by agenda votes (#chref("voting")), although a proposal may be
used to gauge support before a DCP is written.

=== Contractor management

Most treasury spending pays contractors: individuals and companies who work
on the project at agreed rates and invoice monthly in US dollars, converted to
DCR at the previous month's average rate. Since April 2019 contractors have
submitted invoices through the Contractor Management System (CMS), a separate
application built on Politeia, where administrators approve, dispute or reject
them. A stakeholder-approved proposal (the Decred Contractor Clearance) defines
how new contractors are admitted, by agreement of established contractors in
the relevant domain, with disputes escalating to a vote of all contractors and
ultimately to stakeholders. The constitution states that contractors are
autonomous: stakeholders approve or reject programs of work through Politeia
but cannot direct individual contractors. The first payment to contractors by
treasury spend was made in December 2021.

== Voting Service Providers <sec:ecosystem-vsp>

=== Why they exist

A ticket earns its reward only if a vote for it appears in the block in which
it is selected. The wallet holding the ticket's voting key must therefore be
online, unlocked and connected to a full node at an unpredictable moment, and
must broadcast the vote quickly enough for the next block to include it; a
ticket whose vote is not included is _missed_ (#chref("staking")). A voting
service provider (VSP) runs always-online voting wallets on behalf of ticket
holders who do not want to.

=== Delegation without custody

The ticket's output structure is what makes delegation safe. Output 0, tagged
`OP_SSTX`, is the _voting rights_ output: its script (pay-to-pubkey-hash or
pay-to-script-hash) is the script that must be satisfied to vote. The
following outputs are _reward commitments_: each commits to an address and the
amount contributed, and the consensus rules require every vote and revocation
spending the ticket to pay the original amounts plus any reward to exactly
those commitment addresses (#chref("staking")). Control of the voting key is
thus control over how and whether the ticket votes, and nothing else. A holder
of the voting key cannot redirect the funds or the reward.

Since #dcp(9), a missed or expired ticket is revoked automatically: every block
must contain revocations for the tickets that become missed or expired in it,
and those revocations have empty signature scripts, pay no fee, and pay the
commitment addresses. A ticket whose voter fails therefore returns its locked
funds to the owner without any action by the owner or the VSP, losing only the
vote reward.

=== vspd

The current VSP software, `vspd` @vspd, released in 2020, accepts any ticket:
the ticket needs no VSP-specific outputs, and the VSP fee is paid by a separate
ordinary transaction. Registration over vspd's HTTP API proceeds as follows.

+ The client fetches the VSP's information, including its fee percentage and
  its Ed25519 public key, with which the VSP signs every response.
+ The client requests a fee for a specific ticket, sending the ticket and its
  parent transaction. The ticket must be in the mempool, immature or live. The
  VSP replies with a fee amount, valid for one hour, and a fee address unique
  to that ticket,
  derived from an extended public key of a separate fee wallet.
+ The client sends a signed transaction paying that fee to that address,
  together with the private key of the ticket's voting address and its voting
  preferences: choices for each consensus agenda, and yes or no for individual
  treasury spends (by hash) or for all tspends signed by a given Pi key.
+ The VSP holds the fee transaction until the ticket has 6 confirmations, then
  broadcasts it; once the fee transaction itself has 6 confirmations, the VSP
  imports the voting key into each of its voting wallets.

Every client request that names a ticket carries a signature by the ticket's
commitment address (or an alternate signing address registered once for the
ticket), and every response carries the VSP's signature. This _two-way
accountability_ lets either side prove the other's statements: a user can show
that the VSP acknowledged a paid fee and the preferences it was given, and the
VSP can show the preferences the user actually set.

The fee is computed by the wallet library's stake pool fee function from the
VSP's fee percentage $p$, the current ticket price $v$, a fixed relay fee
$z = 10^4$ atoms and an estimate $s$ of the vote subsidy when the ticket is
likely to vote: the current per-vote subsidy reduced by the factor
$100 slash 101$ once for each of $ceil(#param("TicketPoolSize") slash
#param("SubsidyReductionInterval"))$ subsidy reductions (2 on the main
network). The fee is
$ f = floor((p s (v + z)) / (s + v)) $
evaluated in integer arithmetic with $p$ truncated to hundredths of a percent.
It is the share $p$ of the expected reward, scaled by the ticket's
contribution.

A vspd deployment consists of a front-end server and at least three voting
servers, each running `dcrwallet` against its own `dcrd` (SPV is not
supported for voting), ideally in different locations. The voting wallets run
with manual ticket management so that only tickets registered and paid for
through vspd are voted.

=== Trust model and failure modes

A VSP cannot spend a ticket's funds or redirect its reward, and it cannot make
a ticket more or less likely to be selected; the lottery is not influenced by
which wallet holds the voting key. Pooling at a VSP is therefore not pooling of
rewards, and the number of tickets a VSP holds does not change how often any
of them votes. What the user does trust the VSP to do is:

- *Vote at all.* If every voting wallet of the VSP is unavailable, the ticket
  is missed and later revoked automatically; the owner recovers the ticket
  price but not the reward. Some misses are caused not by the VSP but by
  miners: a block found very shortly after its parent may be mined before
  votes for it have propagated.
- *Vote as instructed.* The VSP could vote delegated tickets against their
  owners' preferences. Two-way accountability makes this provable, and the
  documentation recommends spreading tickets across smaller VSPs to limit the
  influence of any one of them.

Because the owner's wallet keeps the voting key, the owner can vote the ticket
directly if a VSP disappears.

#history[
  Before vspd, VSPs ran `dcrstakepool`, where the user and VSP created a
  1-of-2 multisignature _redeem script_ that held the ticket's voting rights,
  and tickets were purchased with dedicated outputs for paying the VSP fee. A user who
  lost the redeem script while the VSP was unavailable could neither vote nor
  revoke; automatic revocations (#dcp(9)) were motivated in part by recovering
  those funds.
]

=== Solo staking

A ticket holder can instead vote alone: buy tickets whose voting address
belongs to one or more always-online "hot" voting wallets, while the funds and
the reward commitments stay with a separate wallet that need not be online.
Running several voting wallets from the same seed on servers in different
places gives redundancy; this is safe because voting creates no new addresses.
Solo staking avoids the VSP fee and the trust in the VSP at the cost of
operating the servers.

== Wallets and Light Clients <sec:ecosystem-wallets>

`dcrwallet` @dcrwallet is the reference wallet daemon; the graphical wallet
Decrediton and other official wallets use it underneath. It holds keys,
builds and signs transactions, buys tickets, votes, mixes, and talks to VSPs,
and is controlled over JSON-RPC and gRPC interfaces. Private keys are derived
hierarchically by BIP-32 @bip32 along BIP-44 paths
`m/44'/coin_type'/account'/branch/index` @bip44 and are never written to disk
unencrypted (#chref("addresses")).

=== Two ways to follow the chain

By default the wallet relies on a trusted `dcrd` over RPC. Alternatively, in
SPV mode it connects directly to peers of the peer-to-peer network and uses
the version 2 committed compact filters (#chref("filters")):

+ It downloads and validates the header chain, including proof of work.
+ For each block it downloads the block's filter together with an inclusion
  proof, and checks the filter against the commitment root in the block header
  introduced by #dcp(5). For blocks before that commitment existed, it checks
  the whole set of filters against a hash built into the wallet.
+ It matches the filters locally against its own scripts and downloads only
  the blocks that match, from which it extracts its transactions.

No address or extended public key leaves the wallet, unlike light wallets that
query a server, and because the filters are committed in proof-of-work
protected headers, a peer cannot hide a transaction by serving a false filter.
An observer sees only which blocks the wallet fetches, which can be spread
across peers. An SPV wallet cannot vote, because a vote approves or
disapproves the previous block's regular transactions and only a fully
validating node can judge them; SPV users delegate voting to a VSP or to their
own full-node voting wallets.

=== Accounts and privacy

Funds are organized in BIP-44 accounts. When mixing is enabled the wallet uses
dedicated accounts: a _mixed_ account (and branch) to which mixed outputs and
voting rewards are paid, a _change_ account that receives unmixed change, which
can itself be mixed into the mixed account, and a _voting_ account from which
voting addresses are derived. Mixing uses the StakeShuffle protocol, whose
messages full nodes relay over the peer-to-peer network
(#chref("mixing")). The protocol breaks the link between inputs and outputs
of equal value but does not hide amounts, so the wallet mixes fixed
denominations and keeps change away from mixed funds.

Mixing is integrated with staking. When buying tickets with mixing enabled,
the wallet funds them through a _mixed split_: it joins a mix whose outputs
are each exactly the amount needed for one ticket, so that the ticket
purchases that follow cannot be linked to the coins that paid for them.
Because every ticket in the same price window costs the same, ticket purchases
form a natural anonymity set.

== Payment Channels and the Lightning Network <sec:ecosystem-lightning>

The Lightning Network @lightning moves payments off chain. Two parties lock
funds in a 2-of-2 multisignature _funding_ output and then exchange signed but
unbroadcast _commitment transactions_ that spend it, each reflecting the
current division of the channel balance and any in-flight payments. Either
party can close the channel by broadcasting the latest commitment transaction.
Broadcasting an older, revoked state is a _breach_, which the other party
punishes with a _justice transaction_ that takes the whole channel balance,
provided it notices within the time allowed. Payments are routed across chains
of channels using hash time-locked contracts (HTLCs): each hop can claim its
incoming payment only by revealing a preimage of the payment hash, and each
hop's timeout is shorter than the one before it.

=== Base-protocol support

Lightning needs four things from the base protocol, all of which Decred
provides.

/ Stable transaction identifiers: Commitment transactions are signed before
  the funding transaction is broadcast and refer to the funding output by its
  transaction hash. In Bitcoin before segregated witness, a third party could
  re-encode a signature, changing the transaction hash and invalidating every
  pre-signed child. Decred separates every transaction into a _prefix_ (inputs'
  outpoints and sequence numbers, outputs, lock time and expiry) and a
  _witness_ (each input's value, block height, block index and signature
  script; the documentation describes the first three as fraud-proof data),
  and the transaction hash used in outpoints is the BLAKE-256 hash of the
  prefix serialization alone (#chref("encoding")). Nothing in the
  signature scripts can change it, and changing the prefix invalidates the
  signatures, which commit to the prefix (#chref("script")). Decred has had
  this property since its launch. The block Merkle tree commits to the full
  transaction by hashing the prefix hash together with the witness hash.
/ Relative time locks: Revocable commitment outputs must be spendable by
  their owner only after a delay counted from when the commitment transaction
  is mined, so that the counterparty has time to react to a breach. #dcp(3)
  gives transaction-input sequence numbers consensus meaning as relative lock
  times (in blocks, or in units of 512 seconds) for transactions of version 2
  or later, and introduces `OP_CHECKSEQUENCEVERIFY` (`0xb2`), which lets a
  script require such a delay (#chref("transactions"), #chref("script")).
  #dcp(4) later corrected the set of outputs visible to the sequence-lock
  check so that the feature is fully usable.
/ Absolute time locks: HTLC timeouts use `OP_CHECKLOCKTIMEVERIFY` (`0xb1`),
  enforced since launch. The opcode compares its operand with the
  transaction's lock time; #dcp(3) changed the rule that decides when a
  time-based lock time has passed, which now uses the median time of the
  previous 11 blocks (#chref("transactions")).
/ Hash locks compatible with other chains: Decred's `OP_HASH160` computes
  RIPEMD-160 of BLAKE-256, not of SHA-256 as in Bitcoin. #dcp(2) adds
  `OP_SHA256` (`0xc0`) so that Decred scripts can commit to the same SHA-256
  hashes as other chains, which cross-chain swaps and interoperable payment
  hashes require.

#dcp(2) and #dcp(3) were deployed together under the `lnfeatures` agenda,
active on the main network from block 189568; `dcrd` enables
`OP_CHECKSEQUENCEVERIFY` and `OP_SHA256` in script validation for blocks for
which the agenda is active (#chref("voting")). #dcp(4) (agenda `fixlnseqlocks`) became active at
block 342784.

=== dcrlnd

`dcrlnd` @dcrlnd
is a port of the `lnd` implementation, changed for Decred's transaction
serialization, witness format and signature process, and aiming at
compliance with the Lightning specifications (BOLTs) @bolts. Its HTLC scripts use
`OP_SHA256 OP_RIPEMD160` where Bitcoin's use `OP_HASH160`, reproducing
Bitcoin's RIPEMD-160-of-SHA-256 payment-hash commitment, and its delayed
outputs use `OP_CHECKSEQUENCEVERIFY`. Nodes that cannot stay online can use
watchtowers, services that watch the chain for breaches and broadcast justice
transactions on their behalf; the documentation notes that watchtowers can
recover only funds already committed in the channel, not in-flight payments.

== Atomic Swaps and DCRDEX <sec:ecosystem-dex>

=== Hash time-locked contracts

An atomic swap exchanges coins on two chains without a trusted
intermediary; Decred's command-line tools for it are in the `atomicswap` repository
@atomicswap.
The initiator chooses a secret, and both parties lock their coins in contracts
on their respective chains that pay the other party on presentation of the
secret, or refund the funder after a timeout. When the initiator redeems the
participant's contract, the secret appears in the redeeming transaction's
signature script, and the participant uses it to redeem the initiator's
contract. The initiator's timeout is the longer, so the participant always has
time to redeem after the secret is revealed. Both chains must support
branching scripts, a common hash function, signature checks and a time lock;
the shared hash is the reason for `OP_SHA256`.

@tab:ecosystem-htlc shows the contract DCRDEX uses on Decred, paid to by
pay-to-script-hash. It is #dcp(2)'s example HTLC with an added check that the
secret is exactly 32 bytes. Each opcode is listed with its value in dcrd's
script engine (#chref("opcodes")).

#figure(
  caption: [Atomic swap contract on Decred, as constructed by DCRDEX
    (`dex/networks/dcr/script.go`, `MakeContract`).],
  table(
    columns: (auto, auto, 1fr),
    table.header([Script], [Bytes], [Effect]),
    [`OP_IF`], [`63`], [Redeem branch if the top stack item is true.],
    [`OP_SIZE 32 OP_EQUALVERIFY`], [`82 01 20 88`], [The secret is exactly 32 bytes.],
    [`OP_SHA256 <secret hash> OP_EQUALVERIFY`], [`c0 20 ... 88`], [SHA-256 of the secret equals the committed 32-byte hash.],
    [`OP_DUP OP_HASH160 <recipient PKH>`], [`76 a9 14 ...`], [Push the recipient's 20-byte public key hash for the check below.],
    [`OP_ELSE`], [`67`], [Refund branch.],
    [`<lock time> OP_CHECKLOCKTIMEVERIFY OP_DROP`], [`... b1 75`], [The spending transaction's lock time has reached the contract's.],
    [`OP_DUP OP_HASH160 <sender PKH>`], [`76 a9 14 ...`], [Push the sender's public key hash.],
    [`OP_ENDIF`], [`68`], [],
    [`OP_EQUALVERIFY OP_CHECKSIG`], [`88 ac`], [The supplied public key hashes to the selected hash and the signature is valid.],
  ),
) <tab:ecosystem-htlc>

The recipient redeems with the signature script
`<sig> <pubkey> <secret> 1 <contract>`; the sender refunds after the lock time
with `<sig> <pubkey> 0 <contract>`. The last push in each is the serialized
contract, which pay-to-script-hash checks against the output's script hash and
then executes (#chref("script")).

=== DCRDEX

DCRDEX @dcrdex is a non-custodial exchange in which a server matches orders
but never holds funds; settlement is by atomic swaps directly between the two
traders' wallets, each swap consisting of four on-chain transactions (two
contracts and two redemptions).

- *Matching in epochs.* Orders are not processed as they arrive. Each order
  carries a commitment, the BLAKE-256 hash of a random 32-byte preimage chosen
  by the client. Orders received during an epoch of fixed length (set per
  market) are collected; at the end of the epoch clients reveal their
  preimages, and the server seeds a pseudorandom generator with the BLAKE-256
  hash of the concatenated preimages (in order-ID order) and shuffles the
  orders before matching them one by one against the book. The preimages,
  seed and a checksum of the commitments are published so that clients can
  check that no order was omitted or reordered. The aim is to deny any client
  a deterministic latency advantage, and the server any undetectable
  discretion over matching.
- *Settlement.* The maker initiates: it creates the secret and broadcasts its
  contract first, with the longer lock time (20 hours in the specification's
  example, against 8 hours for the taker). The taker checks the maker's
  contract and its lock time, then broadcasts its own contract with the same
  secret hash. The maker redeems the taker's contract, revealing the secret,
  and the taker redeems the maker's. The server relays swap details and
  monitors compliance but never controls the funds: a contract that is not
  redeemed is refunded to its funder after its lock time.
- *Fees and accountability.* DCRDEX collects no trading fees, so there is no
  exchange token and no fee transaction; traders pay only the on-chain
  transaction fees, at a minimum rate set by the operator. Instead, a client
  must lock funds in a time-locked _fidelity bond_ to trade, and a client that
  breaks the rules of conduct (failing to settle a match, excessive
  cancellations) loses trading privileges. On Decred a bond is an output
  paying to the following script, spendable by its owner only after the lock
  time:
  ```
  <lock time> OP_CHECKLOCKTIMEVERIFY OP_DROP
  OP_DUP OP_HASH160 <pubkey hash> OP_EQUALVERIFY OP_CHECKSIG
  ```

#note[
  The DCRDEX README calls the bond requirement a one-time registration fee in
  one place and bonds in another; the specification describes bonds. The
  README also describes Tatanka Mesh, a peer-to-peer successor in development
  in which a network of nodes, rather than a central server, maintains order
  books and reputation.
]

== Timestamping with dcrtime <sec:ecosystem-dcrtime>

`dcrtime` @dcrtime
is a timestamping service, inspired by OpenTimestamps, that proves that data
existed at a given time by anchoring its hash in the Decred chain. It was
written for Politeia and is also offered as a free public service.

A client submits 32-byte SHA-256 digests. The server collects them for one
hour; shortly after each hour it computes a SHA-256 Merkle root over the
digests collected and has a wallet publish a transaction with an output
`OP_RETURN <root>`. Once the transaction is mined, the server can return, for
any digest, the Merkle path from the digest to the root, the transaction hash
and the block time (the chain timestamp). A verifier recomputes the root from
the digest and the path, finds the transaction in the chain and reads the
root from its null-data output; the `dcrtime` client verifies the path, and a
separate tool checks anchors against the chain. Any number of digests costs a
single transaction per hour. The proof shows only that the data existed no
later than the block containing the anchor; the collection time the server
reports is the server's claim.

The deployment separates a proxy, which faces the internet, from the backend,
which holds the wallet credentials and builds the anchoring transaction, so
that the process with access to funds is not directly exposed.

== Dependence on the Consensus Protocol <sec:ecosystem-dependence>

None of these systems adds consensus rules, but each relies on guarantees the
rest of this document specifies:

- *Ticket structure and the lottery* (#chref("staking")). Non-custodial VSPs
  exist because the voting-rights output and the reward commitments are
  separate and votes and revocations must pay the commitments. Politeia's
  eligibility rule depends on the live ticket set being a well-defined
  function of the chain, and its vote signatures on the commitment addresses
  recorded in each ticket. Automatic revocation (#dcp(9)) bounds the damage a
  failed VSP can do.
- *Stake votes and the treasury* (#chref("blocks"), #chref("voting"),
  #chref("treasury")). The proposal process has binding force only because
  the treasury can be debited solely by tspends that ticket holders approve in
  their vote transactions, and Pi keys are fixed in the network parameters.
- *Header commitments and compact filters* (#chref("filters")). SPV wallets
  can trust filters because #dcp(5) commits to them in proof-of-work protected
  headers.
- *Transaction hashing and script* (#chref("encoding"), #chref("script"),
  #chref("transactions")). Payment channels and swaps depend on transaction
  hashes that exclude signature scripts, on `OP_CHECKSEQUENCEVERIFY` and
  relative lock times (#dcp(3), #dcp(4)), on `OP_CHECKLOCKTIMEVERIFY`, and on
  `OP_SHA256` (#dcp(2)).
- *Chain permanence.* Timestamps from `dcrtime`, Politeia's anchors and its
  ticket snapshot are only as durable as the blocks that contain them, which
  is why Politeia treats an anchor as final only once the anchoring
  transaction has 6 confirmations and takes its ticket snapshot #param("TicketMaturity") blocks below the tip.
  The proof-of-work and proof-of-stake rules that make deep reorganizations
  costly (#chref("difficulty"), #chref("blocks")) underpin all of them.
