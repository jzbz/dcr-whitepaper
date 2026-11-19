# Decred Technical Whitepaper

A specification of the Decred protocol as deployed on the main network: a
hybrid proof-of-work and proof-of-stake cryptocurrency with on-chain consensus
governance and a self-funding treasury.

The paper describes the protocol completely enough to build an independent
full node from the text: the cryptographic primitives, the serialization of
every consensus-critical structure, the script language, transaction and
block validation, the stake system and its ticket lottery, both difficulty
algorithms, the issuance schedule, the treasury, the voting mechanism for
rule changes with every change activated to date, and the peer-to-peer
protocol.

| | |
| --- | --- |
| Read online | <https://docs.dcr.pw/whitepaper/> |
| PDF | <https://docs.dcr.pw/whitepaper/decred-whitepaper.pdf> |
| Version | 1.0 |
| Reference implementation | [dcrd](https://github.com/decred/dcrd), commit `46e9df48109a` (master, 5 November 2026) |
| Length | about 420 pages |
| Contents | 261 numbered consensus rules, 125 algorithms, 111 test vectors |

dcrd is the specification. Where this document and dcrd disagree, dcrd is
correct and the document is in error.

## Building

The paper is written in [Typst](https://typst.app) (0.15). Nothing else is
needed: the fonts are in `fonts/` or built into Typst, system fonts are
ignored, and no external packages are used, so the build works offline and
produces the same result on any machine.

```sh
./build.sh              # the whole paper  -> decred-whitepaper.pdf
./build.sh 08           # one chapter      -> ch08.pdf
./build.sh -o out.pdf   # write to a specific file
./build.sh -w           # rebuild on every change
```

A chapter is selected by the prefix of its file name (`01` to `19`, `A1` to
`A3`). Output is written outside the source tree: to `$WHITEPAPER_OUT` if it
is set, otherwise to `../../artifacts/dcr-whitepaper/build` if
`../../artifacts` exists, otherwise to `./build`.

## Contents

| Part | Chapter | File |
| --- | --- | --- |
| Foundations | 1 Introduction | `chapters/01-introduction.typ` |
| | 2 Conventions and Notation | `chapters/02-conventions.typ` |
| | 3 Cryptographic Primitives | `chapters/03-cryptography.typ` |
| | 4 Data Encoding and Structures | `chapters/04-encoding.typ` |
| | 5 Keys and Addresses | `chapters/05-addresses.typ` |
| Scripts and Transactions | 6 The Script System | `chapters/06-script.typ` |
| | 7 Transactions | `chapters/07-transactions.typ` |
| Consensus | 8 The Stake System | `chapters/08-staking.typ` |
| | 9 Proof of Work and Difficulty | `chapters/09-difficulty.typ` |
| | 10 Blocks and Chain Selection | `chapters/10-blocks.typ` |
| | 11 Issuance and Block Subsidy | `chapters/11-subsidy.typ` |
| | 12 The Decentralized Treasury | `chapters/12-treasury.typ` |
| | 13 Consensus Rule Changes | `chapters/13-voting.typ` |
| | 14 Network Parameters | `chapters/14-parameters.typ` |
| Network | 15 The Peer-to-Peer Protocol | `chapters/15-p2p.typ` |
| | 16 Compact Filters and Light Clients | `chapters/16-filters.typ` |
| | 17 Relay Policy and Mining | `chapters/17-policy.typ` |
| | 18 StakeShuffle Mixing | `chapters/18-mixing.typ` |
| | 19 Governance and Ecosystem | `chapters/19-ecosystem.typ` |
| Appendices | A Opcode Reference | `chapters/A1-opcodes.typ` |
| | B Index of Consensus Rules | `chapters/A2-rule-index.typ` |
| | C Differences from Bitcoin | `chapters/A3-bitcoin-differences.typ` |

Chapters 1 and 19 and appendix C are informative. Chapters 15, 17 and 18
describe behavior that is not part of consensus but that an interoperating
node or wallet needs. Appendix B is generated from the rule boxes of the
other chapters when the paper is built.

## Layout of the source

| Path | Purpose |
| --- | --- |
| `main.typ` | Title page, abstract, parts, chapter order and bibliography |
| `template.typ` | Page design and the helpers the chapters use |
| `chapters/` | One file per chapter |
| `refs.yml` | Bibliography |
| `fonts/` | IBM Plex Sans and IBM Plex Mono |
| `build.sh` | Build script |

## Writing conventions

Chapter 2 of the paper defines the notation. In the source, the main helpers
from `template.typ` are:

- `#rule("Title", src: "path/file.go · function")[...] <rule:key-name>` for a
  numbered, normative consensus rule. Every consensus check has one.
- `#algorithm("Title", src: ...)[...]` for pseudocode, and `#vector[Title][...]`
  for a test vector.
- `#note`, `#rationale`, `#history` and `#pitfall` for remarks.
- `#chref("staking")` to refer to another chapter, `#dcp(11)` for a Decred
  Change Proposal, `#param("TicketMaturity")` for a network parameter,
  `#const("MaxAmount")` for a network-independent constant, and
  `#hex("ab12...")` for hexadecimal data.
- `#MUST`, `#MUSTNOT`, `#SHOULD`, `#SHOULDNOT` and `#MAY` for the RFC 2119
  key words.

Two Typst pitfalls are worth knowing. A semicolon directly after one of these
helpers is consumed by Typst, so write `#chref("blocks")\;` when the sentence
needs one. A source line that begins with a number and a full stop is set as
a numbered-list item, so do not let a line of prose start with "52." or
"2022.".

Every number, comparison and formula in a rule is taken from the dcrd source
at the reference commit, not from its comments, the DCPs or other
documentation. Test vectors are produced by running dcrd's own code.

## Fonts

IBM Plex Sans and IBM Plex Mono are distributed under the SIL Open Font
License 1.1; see `fonts/IBM-Plex-LICENSE.txt`. The text face (Libertinus
Serif), the mathematics face (New Computer Modern Math) and the fallback
monospace face (DejaVu Sans Mono) are the ones built into Typst.
