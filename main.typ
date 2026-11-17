#import "template.typ": *

// Build a single chapter with `--input only=08` (the file-name prefix).
#let only = sys.inputs.at("only", default: none)
#let chapter(file) = if only == none or file.starts-with(only) {
  include "chapters/" + file + ".typ"
}
#let divider(..args) = if only == none { part(..args) }

#show: whitepaper.with(
  title: [Decred],
  subtitle: [A hybrid proof-of-work and proof-of-stake cryptocurrency with on-chain consensus governance and a self-funding treasury],
  version: [1.0],
  date: [16 November 2026],
  commit: [dcrd, commit #raw("46e9df48109a") (master, 5 November 2026)],
  front-matter: only == none,
  abstract: [
    Decred is a cryptocurrency whose consensus rules are enforced, and
    amended, by the people who hold it. Blocks are produced by proof-of-work
    miners, but a block only becomes part of the chain once a pseudorandomly
    selected quorum of stakeholders, who have time-locked funds to buy
    _tickets_, has voted to approve it. The same tickets vote on changes to
    the consensus rules themselves and on every expenditure from a treasury
    that is funded by a fixed share of each block reward.

    This paper specifies the complete protocol as deployed on the Decred main
    network: the cryptographic primitives, the serialization of every
    consensus-critical structure, the script language, the transaction and
    block validation rules, the stake system and its ticket lottery, both
    difficulty adjustment algorithms, the issuance schedule, the decentralized
    treasury, the on-chain voting mechanism for rule changes together with
    every change activated to date, and the peer-to-peer protocol. It is
    written so that an independent implementation built from this document
    alone accepts and rejects exactly the same blocks as the reference
    implementation.
  ],
)

#divider([Foundations], summary: [
  What Decred is, how this document is written, and the primitives every
  later chapter relies on: hash functions, signature schemes, serialization
  and addresses.
])
#chapter("01-introduction")
#chapter("02-conventions")
#chapter("03-cryptography")
#chapter("04-encoding")
#chapter("05-addresses")

#divider([Scripts and Transactions], summary: [
  The stack machine that guards every output, and the rules a transaction
  must satisfy before it may spend one.
])
#chapter("06-script")
#chapter("07-transactions")

#divider([Consensus], summary: [
  Tickets and votes, proof of work, the two difficulty algorithms, block
  validation and chain selection, issuance, the treasury, and the process by
  which stakeholders change the rules.
])
#chapter("08-staking")
#chapter("09-difficulty")
#chapter("10-blocks")
#chapter("11-subsidy")
#chapter("12-treasury")
#chapter("13-voting")
#chapter("14-parameters")

#divider([Network], summary: [
  How nodes find each other, exchange blocks and transactions, serve light
  clients, decide what to relay and mine, and mix coins.
])
#chapter("15-p2p")
#chapter("16-filters")
#chapter("17-policy")
#chapter("18-mixing")
#chapter("19-ecosystem")

#show: appendices
#divider([Appendices])
#chapter("A1-opcodes")
#chapter("A2-rule-index")
#chapter("A3-bitcoin-differences")

#if only == none {
  {
    // The IEEE style leaves two spaces where an entry has no month.
    show regex("[ \u{00a0}]{2,}"): [ ]
    bibliography("refs.yml", title: [References], style: "ieee")
  }
} else {
  // Partial builds still resolve citations, without printing the list.
  show bibliography: none
  bibliography("refs.yml")
}
