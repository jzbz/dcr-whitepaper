#import "../template.typ": *

// ---------------------------------------------------------------------------
// This file is generated: the tables and values below are produced by a Go
// program that imports dcrd's chaincfg package and dumps every field of
// chaincfg.Params by reflection.  Prose is maintained in the generator's
// template.
// ---------------------------------------------------------------------------

#let pv(main, note: none) = {
  text(font: mono, size: 7.1pt, main)
  if note != none {
    linebreak()
    text(font: sans, size: 6.3pt, fill: palette.muted, note)
  }
}
#let hx(s) = text(size: 7.8pt, hex(s))
#let usetag(u) = box(text(font: sans, size: 6.1pt, weight: "medium", tracking: 0.04em, fill: palette.muted, upper(u)))
#let fname(s) = text(font: mono, size: 7.3pt, weight: "semibold", fill: palette.teal, s)
#let netheads = ([mainnet], [testnet3], [simnet], [regnet])
#let vcol = 22.5mm
#let vinset = (x: 4pt, y: 4.6pt)

// Main parameter table: (field, use, meaning, values); one value spans all
// four networks.
#let ptable(caption, rows) = figure(
  caption: caption,
  table(
    columns: (1fr, vcol, vcol, vcol, vcol),
    inset: vinset,
    table.header([Field and meaning], ..netheads),
    ..rows
      .map(r => {
        let (name, use, meaning, vals) = r
        let first = [#fname(name)#h(0.5em)#usetag(use) \ #text(size: 7.6pt, meaning)]
        if vals.len() == 1 {
          (first, table.cell(colspan: 4, align: center, vals.at(0)))
        } else {
          (first, ..vals)
        }
      })
      .flatten()
  ),
)

// Long values: (field, network, value); consecutive rows of one field are
// merged. Kept on one page.
#let ltable(caption, lbl, rows) = {
  let cells = ()
  let i = 0
  while i < rows.len() {
    let f = rows.at(i).at(0)
    let j = i
    while j < rows.len() and rows.at(j).at(0) == f { j += 1 }
    cells.push(table.cell(rowspan: j - i, fname(f)))
    for k in range(i, j) {
      cells.push(text(font: sans, size: 7.4pt, rows.at(k).at(1)))
      cells.push(rows.at(k).at(2))
    }
    i = j
  }
  block(breakable: false, above: 1.5em, below: 1.5em)[#figure(
    caption: caption,
    table(
      columns: (auto, auto, 1fr),
      table.header([Field], [Network], [Value]),
      ..cells
    ),
  )#label(lbl)]
}

// Address prefixes: (description, field, values).
#let atable(rows) = figure(
  caption: [Address and key prefixes with the leading characters they produce],
  table(
    columns: (1fr, vcol, vcol, vcol, vcol),
    inset: vinset,
    table.header([Encoding and field], ..netheads),
    ..rows.map(r => ([#text(size: 7.6pt, r.at(0)) \ #fname(r.at(1))], ..r.at(2))).flatten()
  ),
)

// Derived quantities: (name, formula, values).
#let dtable(rows) = figure(
  caption: [Derived quantities. Times assume blocks arrive exactly at the target rate.],
  table(
    columns: (1fr, vcol, vcol, vcol, vcol),
    inset: vinset,
    table.header([Quantity and formula], ..netheads),
    ..rows
      .map(r => {
        let first = [#text(size: 7.8pt, r.at(0)) \ #text(size: 7.2pt, r.at(1))]
        let vals = r.at(2)
        if vals.len() == 1 {
          (first, table.cell(colspan: 4, align: center, vals.at(0)))
        } else {
          (first, ..vals)
        }
      })
      .flatten()
  ),
)

// Deployment summary: (agenda id, influences consensus, values).
#let deptable(rows) = figure(
  caption: [Agendas per network: stake version and vote mask, then the voting period, forced choice or default],
  table(
    columns: (1fr, vcol, vcol, vcol, vcol),
    inset: vinset,
    table.header([Agenda], ..netheads),
    ..rows
      .map(r => {
        let first = if r.at(1) { fname(r.at(0)) } else {
          [#fname(r.at(0)) \ #text(size: 6.8pt, fill: palette.muted)[no consensus effect]]
        }
        (first, ..r.at(2))
      })
      .flatten()
  ),
)

// Genesis tables: (field, values). Kept on one page.
#let gtable(caption, lbl, rows) = block(breakable: false, above: 1.5em, below: 1.5em)[#figure(
  caption: caption,
  table(
    columns: (1fr, vcol, vcol, vcol, vcol),
    inset: vinset,
    table.header([Field], ..netheads),
    ..rows
      .map(r => {
        let first = fname(r.at(0))
        let vals = r.at(1)
        if vals.len() == 1 {
          (first, table.cell(colspan: 4, align: center, vals.at(0)))
        } else {
          (first, ..vals)
        }
      })
      .flatten()
  ),
)#label(lbl)]

#let field-count = 85
#let genesis-merkle = (
  ("mainnet", "TxHashFull"),
  ("testnet3", "TxHash"),
  ("simnet", "TxHashFull"),
  ("regnet", "TxHashFull"),
)
#let genesis-pow = (
  ("mainnet", false),
  ("testnet3", false),
  ("simnet", true),
  ("regnet", true),
)
#let genesis-message = (
  ("simnet", "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"),
)
#let ledger = (
  ("mainnet", "3146", "168000000000000", "1680000 DCR", "3146", "0 / 0"),
  ("testnet3", "2", "10000000000000", "100000 DCR", "2", "0 / 0"),
  ("simnet", "3", "30000000000000", "300000 DCR", "3", "0 / 0"),
  ("regnet", "3", "30000000000000", "300000 DCR", "3", "0 / 0"),
)
#let tn-maxdiff-height = "962928"
#let tn-maxdiff-hash = "0000004fd1b267fd39111d456ff557137824538e6f6776168600e56002e23b93"
#let tn-maxdiff-shift = "6"
#let tn-min-target = "00000003ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
#let tn-min-bits = "0x1d03ffff"

= Network Parameters <ch:parameters>

A Decred *network* is an independent chain together with the peers that
relay it: it has its own genesis block, its own consensus constants and its
own encodings for addresses and keys. dcrd defines four networks, and every
constant that differs between them is a field of the structure
`chaincfg.Params`. The rest of this document names such a constant in the
form #param("TicketMaturity") and quotes its main-network value; this chapter
gives every field for every network, the quantities that follow from them,
the genesis blocks, and the few network-specific rules that dcrd hard-codes
outside the parameter structure.

== The Four Networks <sec:parameters-networks>

@tab:parameters-networks summarizes the networks.

- The *main network* (`mainnet`) is the production network that carries the
  DCR currency.
- The *test network*, version 3 (`testnet3`), is a public network for testing
  software against realistic conditions with coins of no value. dcrd
  describes it as the third public iteration of the test network. Its
  predecessors are not defined in the current source; a remark in the
  block-size code notes that the `maxblocksize` vote took place on an earlier
  version of the test network that has since been replaced.
- The *simulation network* (`simnet`) is meant for private use by a group of
  people running full integration tests between applications such as
  wallets, voting service providers, pools and block explorers. It has no
  seeds, so its nodes connect only to peers named explicitly, and its
  parameters make blocks, ticket maturity and voting intervals very short.
- The *regression test network* (`regnet`) is meant for unit tests and RPC
  server tests. dcrd states that its values may change even when the change
  is a hard fork. When started on regnet, dcrd deletes any existing block and
  UTXO databases, so every run begins again from the genesis block.

#figure(
  caption: [The networks at a glance],
  table(
    columns: (auto, 1fr, 1fr, 1fr, 1fr),
    table.header([], ..netheads),
    [#param("Name")], pv("mainnet"), pv("testnet3"), pv("simnet"), pv("regnet"),
    [Magic (#param("Net"))], pv("0xd9b400f9"), pv("0xb194aa75"), pv("0x12141c16"), pv("0xdab500fa"),
    [P2P port (#param("DefaultPort"))], pv("9108"), pv("19108"), pv("18555"), pv("18655"),
    [RPC port (not in `chaincfg`)], pv("9109"), pv("19109"), pv("19556"), pv("18656"),
    [Address prefix (#param("NetworkAddressPrefix"))], pv("D"), pv("T"), pv("S"), pv("R"),
    [Target block time], pv("5 min"), pv("2 min"), pv("1 s"), pv("1 s"),
    [Genesis timestamp (UTC)], pv("2016-02-08"), pv("2018-08-06"), pv("2014-05-28"), pv("2018-10-03"),
  ),
) <tab:parameters-networks>

Nodes of different networks are kept apart at three levels.

/ Network magic: Every peer-to-peer message begins with the 4-byte network
  magic #param("Net"), a `uint32` serialized little-endian. A node reading a
  message whose magic differs from its own network's treats the message as
  coming from another network and fails the read (#chref("p2p")).
/ Genesis block: Each network has its own genesis block
  (@sec:parameters-genesis), so no block of one network can extend the chain
  of another: every chain is anchored to its network's genesis hash.
/ Encodings: Addresses, WIF private keys and extended keys carry
  network-specific version bytes (@tab:parameters-encoding), so that a string
  produced for one network fails to decode on another and funds are not sent
  to an address on the wrong network by mistake.

The RPC ports in @tab:parameters-networks are defined by the dcrd
application rather than by `chaincfg`. Like the peer-to-peer port, they are
defaults that an operator may change. Source: #src("params.go").

== Reading the Parameter Tables <sec:parameters-reading>

`chaincfg.Params` has #field-count fields at the reference commit, including
the unexported field `seeders`. Each appears exactly once in
@tab:parameters-identity to @tab:parameters-encoding, grouped by theme, with
its dcrd field name, a one-line meaning and its value on each network. A value
that is the same on all four networks is printed once across the four value
columns. Values too long for a column (hashes, scripts, keys, 256-bit
integers) are given in separate tables referenced from the cell. The tables
were produced by a program that imports dcrd's `chaincfg` package and walks
the structure by reflection, refusing to run if any field is not covered; no
value was transcribed by hand.

Beside each field name a tag says how dcrd uses it:

/ consensus: read by the validation code; an implementation #MUST use the
  value exactly.
/ node: used for networking, synchronization or RPC; not part of consensus.
/ policy: a default for mempool and relay policy (#chref("policy")).
/ encoding: used to encode and decode addresses and keys
  (#chref("addresses")).
/ unused: not read anywhere in dcrd at the reference commit.

Durations are given in seconds, with the equivalent in larger units below;
amounts are in atoms with the DCR equivalent below. Compact difficulty values
("bits", #chref("difficulty")) are given in hexadecimal.

#pitfall[
  Several doc comments in `chaincfg/params.go` do not match how the field is
  used, and a field's "deprecated" marking does not mean it is unused. In
  particular: #param("WorkRewardProportion"), #param("StakeRewardProportion")
  and #param("BlockTaxProportion") are marked deprecated but define the
  original subsidy split, which still governs every block before the
  DCP-0010 agenda activated, and the treasury share in every era is still
  #param("BlockTaxProportion") divided by the sum of the three
  (#chref("subsidy")); #param("BlockTaxProportion") is documented as an
  inverse percentage but is used as a proportion (1 of a total of 10); the
  `V2` proportions are not read at all; #param("WorkDiffWindowSize") is
  documented as a number of windows but is the number of blocks per window;
  and #param("ReduceMinDifficulty") is deprecated but still consensus-critical
  on testnet3. The tags in the tables reflect use, not comments.
]

== Parameter Tables <sec:parameters-tables>

=== Identity, Peer-to-Peer and Policy

#ptable([Identity, peer-to-peer and policy parameters], (
  ("Name", "node", [Human-readable identifier of the network.], (pv("mainnet"), pv("testnet3"), pv("simnet"), pv("regnet"),)),
  ("Net", "node", [Network magic: the `uint32` that begins every peer-to-peer message header, serialized little-endian (byte order shown below the value). Consensus code also uses it to identify the network for the hard-coded exceptions of @sec:parameters-exceptions.], (pv("0xd9b400f9", note: "wire: f9 00 b4 d9"), pv("0xb194aa75", note: "wire: 75 aa 94 b1"), pv("0x12141c16", note: "wire: 16 1c 14 12"), pv("0xdab500fa", note: "wire: fa 00 b5 da"),)),
  ("DefaultPort", "node", [Default TCP port for peer-to-peer connections.], (pv("9108"), pv("19108"), pv("18555"), pv("18655"),)),
  ("DNSSeeds", "unused", [Deprecated list of DNS seed host names (with a flag for service-flag filtering support); dcrd no longer reads it. Listed in @tab:parameters-seeds.], (pv("3 entries"), pv("3 entries"), pv("0 entries"), pv("0 entries"),)),
  ("seeders", "node", [Unexported list of HTTPS seeder host names that dcrd queries for peer addresses (accessor `Seeders()`). Listed in @tab:parameters-seeds.], (pv("4 entries"), pv("3 entries"), pv("0 entries"), pv("0 entries"),)),
  ("GenerateSupported", "node", [Whether the node's built-in CPU mining RPC is permitted.], (pv("false"), pv("true"), pv("true"), pv("true"),)),
  ("AcceptNonStdTxs", "policy", [Default for the mempool option to accept and relay non-standard transactions.], (pv("false"), pv("true"), pv("true"), pv("true"),)),
)) <tab:parameters-identity>

#ltable([DNS seeds and HTTPS seeders], "tab:parameters-seeds", (
  ("DNSSeeds", "mainnet", [#raw("mainnet-seed.decred.mindcry.org") (HasFiltering: true)]),
  ("DNSSeeds", "mainnet", [#raw("mainnet-seed.decred.netpurgatory.com") (HasFiltering: true)]),
  ("DNSSeeds", "mainnet", [#raw("mainnet-seed.decred.org") (HasFiltering: true)]),
  ("DNSSeeds", "testnet3", [#raw("testnet-seed.decred.mindcry.org") (HasFiltering: true)]),
  ("DNSSeeds", "testnet3", [#raw("testnet-seed.decred.netpurgatory.com") (HasFiltering: true)]),
  ("DNSSeeds", "testnet3", [#raw("testnet-seed.decred.org") (HasFiltering: true)]),
  ("DNSSeeds", "simnet", [none]),
  ("DNSSeeds", "regnet", [none]),
  ("seeders", "mainnet", raw("mainnet-seed-1.decred.org")),
  ("seeders", "mainnet", raw("mainnet-seed-2.decred.org")),
  ("seeders", "mainnet", raw("mainnet-seed.jholdstock.uk")),
  ("seeders", "mainnet", raw("dcr-seed.jz.bz")),
  ("seeders", "testnet3", raw("testnet-seed-1.decred.org")),
  ("seeders", "testnet3", raw("testnet-seed-2.decred.org")),
  ("seeders", "testnet3", raw("testnet-seed.jholdstock.uk")),
  ("seeders", "simnet", [none]),
  ("seeders", "regnet", [none]),
))

The seed host names are informative: they are how dcrd bootstraps peer
discovery, not part of the protocol. The `DNSSeeds` list is retained in the
structure for compatibility only.

=== Genesis

#ptable([Genesis parameters], (
  ("GenesisBlock", "consensus", [The block at height 0. Specified field by field in @sec:parameters-genesis.], ([see @sec:parameters-genesis],)),
  ("GenesisHash", "consensus", [Hash of the genesis block header (display form in @tab:parameters-genesis-hashes).], ([see @tab:parameters-genesis-hashes],)),
)) <tab:parameters-genesis>

=== Block Limits and Proof of Work

#ptable([Block limits and proof-of-work parameters], (
  ("MaximumBlockSizes", "consensus", [Maximum serialized block size in bytes. The first entry applies by default; the second, where present, applies once the `maxblocksize` agenda is active.], (pv("393216"), pv("1310720"), pv("1000000, 1310720"), pv("1000000, 1310720"),)),
  ("MaxTxSize", "consensus", [Maximum serialized transaction size in bytes.], (pv("393216"), pv("1000000"), pv("1000000"), pv("1000000"),)),
  ("TargetTimePerBlock", "consensus", [Target interval between blocks.], (pv("300 s", note: "5 min"), pv("120 s", note: "2 min"), pv("1 s"), pv("1 s"),)),
  ("PowLimit", "consensus", [Highest permitted proof-of-work target, as a 256-bit integer (full hexadecimal in @tab:parameters-pow-long).], (pv("2^224 - 1"), pv("2^232 - 1"), pv("2^255 - 1"), pv("2^255 - 1"),)),
  ("PowLimitBits", "consensus", [#param("PowLimit") in compact form; because of the compact format's limited precision it is not exactly equal to #param("PowLimit") (expanded value in @tab:parameters-pow-long).], (pv("0x1d00ffff"), pv("0x1e00ffff"), pv("0x207fffff"), pv("0x207fffff"),)),
  ("ReduceMinDifficulty", "consensus", [Deprecated. Whether the minimum-difficulty reduction of test networks applies (testnet3 only, and only below a hard-coded height; see @sec:parameters-exceptions).], (pv("false"), pv("true"), pv("false"), pv("false"),)),
  ("MinDiffReductionTime", "consensus", [Deprecated. Time without a block after which the minimum-difficulty reduction applies, when #param("ReduceMinDifficulty") is set.], (pv("0 s"), pv("600 s", note: "10 min"), pv("0 s"), pv("0 s"),)),
  ("WorkDiffAlpha", "consensus", [Version 1 (BLAKE-256) difficulty algorithm: smoothing value of the weighted average.], (pv("1"),)),
  ("WorkDiffWindowSize", "consensus", [Version 1 algorithm: number of blocks in one window, which is also the retarget interval. (The doc comment in dcrd wrongly calls it a number of windows.)], (pv("144"), pv("144"), pv("8"), pv("8"),)),
  ("WorkDiffWindows", "consensus", [Version 1 algorithm: number of windows in the weighted average.], (pv("20"), pv("20"), pv("4"), pv("4"),)),
  ("TargetTimespan", "consensus", [Version 1 algorithm: target duration of one window, equal to #param("WorkDiffWindowSize") times #param("TargetTimePerBlock").], (pv("43200 s", note: "12 h"), pv("17280 s", note: "288 min"), pv("8 s"), pv("8 s"),)),
  ("RetargetAdjustmentFactor", "consensus", [Version 1 algorithm: bound on the factor by which the difficulty may change at one retarget. The original (version 1) stake difficulty algorithm uses the same bound.], (pv("4"),)),
  ("WorkDiffV2Blake3StartBits", "consensus", [Version 2 (ASERT, BLAKE3) algorithm: target, in compact form, used at the start of BLAKE3 proof of work.], (pv("0x1b00a5a6"), pv("0x1e00ffff"), pv("0x207fffff"), pv("0x207fffff"),)),
  ("WorkDiffV2HalfLifeSecs", "consensus", [Version 2 algorithm: half-life in seconds; the difficulty halves or doubles for every multiple of this time the chain is behind or ahead of schedule.], (pv("43200", note: "12 h"), pv("720", note: "12 min"), pv("6"), pv("6"),)),
)) <tab:parameters-pow>

#ltable([#param("PowLimit"), and the compact values #param("PowLimitBits") and #param("WorkDiffV2Blake3StartBits") expanded, as 256-bit integers in big-endian hexadecimal], "tab:parameters-pow-long", (
  ("PowLimit", "mainnet", hx("00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff")),
  ("PowLimit", "testnet3", hx("000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")),
  ("PowLimit", "simnet", hx("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")),
  ("PowLimit", "regnet", hx("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")),
  ("PowLimitBits", "mainnet", hx("00000000ffff0000000000000000000000000000000000000000000000000000")),
  ("PowLimitBits", "testnet3", hx("000000ffff000000000000000000000000000000000000000000000000000000")),
  ("PowLimitBits", "simnet", hx("7fffff0000000000000000000000000000000000000000000000000000000000")),
  ("PowLimitBits", "regnet", hx("7fffff0000000000000000000000000000000000000000000000000000000000")),
  ("WorkDiffV2Blake3StartBits", "mainnet", hx("000000000000a5a6000000000000000000000000000000000000000000000000")),
  ("WorkDiffV2Blake3StartBits", "testnet3", hx("000000ffff000000000000000000000000000000000000000000000000000000")),
  ("WorkDiffV2Blake3StartBits", "simnet", hx("7fffff0000000000000000000000000000000000000000000000000000000000")),
  ("WorkDiffV2Blake3StartBits", "regnet", hx("7fffff0000000000000000000000000000000000000000000000000000000000")),
))

#param("MaximumBlockSizes") has a second entry only on simnet and regnet.
dcrd selects the second entry for a block when the `maxblocksize` agenda is
active for it and the list has more than one entry, and the first entry
otherwise (#src("internal/blockchain/chain.go", "maxBlockSize")). Since an
agenda that has no deployment on a network other than mainnet is treated as
always active (@sec:parameters-voting), testnet3 would select a second entry
if it had one; it does not, so its limit is always 1310720 bytes. The
proof-of-work algorithms that use these parameters are specified in
#chref("difficulty").

=== Subsidy

#ptable([Subsidy and organization parameters], (
  ("BaseSubsidy", "consensus", [Block subsidy, in atoms, before any reduction.], (pv("3119582664", note: "31.19582664 DCR"), pv("2500000000", note: "25 DCR"), pv("50000000000", note: "500 DCR"), pv("50000000000", note: "500 DCR"),)),
  ("MulSubsidy", "consensus", [Multiplier applied to the subsidy at each reduction.], (pv("100"),)),
  ("DivSubsidy", "consensus", [Divisor applied to the subsidy at each reduction (after the multiplication).], (pv("101"),)),
  ("SubsidyReductionInterval", "consensus", [Number of blocks between subsidy reductions.], (pv("6144"), pv("2048"), pv("128"), pv("128"),)),
  ("WorkRewardProportion", "consensus", [Proof-of-work share of the original subsidy split, as a proportion of the sum #param("WorkRewardProportion") + #param("StakeRewardProportion") + #param("BlockTaxProportion"). Marked deprecated in dcrd but still read by the original split.], (pv("6"),)),
  ("StakeRewardProportion", "consensus", [Proof-of-stake (all votes of a block together) share of the original split, as a proportion of the same sum.], (pv("3"),)),
  ("BlockTaxProportion", "consensus", [Treasury share, as a proportion of the same sum, in every era: the later splits change only the proof-of-work and proof-of-stake shares. (The doc comment in dcrd describes it as an inverse percentage, which does not match its use.)], (pv("1"),)),
  ("WorkRewardProportionV2", "unused", [Proof-of-work proportion of the DCP-0010 split. Not read: the DCP-0010 and DCP-0012 splits are hard-coded in the subsidy code (#chref("subsidy")).], (pv("1"),)),
  ("StakeRewardProportionV2", "unused", [Proof-of-stake proportion of the DCP-0010 split. Not read, as for #param("WorkRewardProportionV2").], (pv("8"),)),
  ("OrganizationPkScript", "consensus", [Output script that the treasury share of the coinbase must pay before the treasury agenda (DCP-0006) is active (@tab:parameters-subsidy-long).], ([see @tab:parameters-subsidy-long],)),
  ("OrganizationPkScriptVersion", "consensus", [Script version required on that coinbase output.], (pv("0"),)),
  ("BlockOneLedger", "consensus", [Outputs (script version, script, amount) that the coinbase of block 1 must pay exactly. Contents in #chref("subsidy")\; count and total in @sec:parameters-ledger.], (pv("3146 outputs"), pv("2 outputs"), pv("3 outputs"), pv("3 outputs"),)),
)) <tab:parameters-subsidy>

#ltable([Organization (pre-treasury) output script], "tab:parameters-subsidy-long", (
  ("OrganizationPkScript", "mainnet", [#hx("a914f5916158e3e2c4551c1796708db8367207ed13bb87") \ #text(size: 7pt)[OP\_HASH160 #hex("f5916158e3e2c4551c1796708db8367207ed13bb") OP\_EQUAL] \ address #raw("Dcur2mcGjmENx4DhNqDctW5wJCVyT3Qeqkx")]),
  ("OrganizationPkScript", "testnet3", [#hx("a914d585cd7426d25b4ea5faf1e6987aacfeda3db94287") \ #text(size: 7pt)[OP\_HASH160 #hex("d585cd7426d25b4ea5faf1e6987aacfeda3db942") OP\_EQUAL] \ address #raw("TcrypGAcGCRVXrES7hWqVZb5oLJKCZEtoL1")]),
  ("OrganizationPkScript", "simnet", [#hx("a914cbb08d6ca783b533b2c7d24a51fbca92d937bf9987") \ #text(size: 7pt)[OP\_HASH160 #hex("cbb08d6ca783b533b2c7d24a51fbca92d937bf99") OP\_EQUAL] \ address #raw("ScuQxvveKGfpG1ypt6u27F99Anf7EW3cqhq")]),
  ("OrganizationPkScript", "regnet", [#hx("a9146913bcc838bd0087fb3f6b3c868423d5e300078d87") \ #text(size: 7pt)[OP\_HASH160 #hex("6913bcc838bd0087fb3f6b3c868423d5e300078d") OP\_EQUAL] \ address #raw("RcQR65gasxuzf7mUeBXeAux6Z37joPuUwUN")]),
))

The organization script is the pay-to-script-hash output to which the
treasury share of every coinbase was paid before the decentralized treasury
(DCP-0006, #chref("treasury")) replaced it with a treasury base. How the
subsidy parameters are combined is specified in #chref("subsidy").

=== Proof of Stake

#ptable([Proof-of-stake parameters], (
  ("MinimumStakeDiff", "consensus", [Minimum ticket price (stake difficulty) in atoms.], (pv("200000000", note: "2 DCR"), pv("20000000", note: "0.2 DCR"), pv("20000", note: "0.0002 DCR"), pv("20000", note: "0.0002 DCR"),)),
  ("TicketPoolSize", "consensus", [Ticket pool size in units of blocks: the stake difficulty algorithms target a live pool of #param("TicketPoolSize") times #param("TicketsPerBlock") tickets.], (pv("8192"), pv("1024"), pv("64"), pv("64"),)),
  ("TicketsPerBlock", "consensus", [Number of tickets selected to vote on each block, which is also the maximum number of votes a block may contain.], (pv("5"),)),
  ("TicketMaturity", "consensus", [Number of blocks for a ticket to mature after the block that includes it (exact semantics in #chref("staking")).], (pv("256"), pv("16"), pv("16"), pv("16"),)),
  ("TicketExpiry", "consensus", [Number of blocks after maturity after which a ticket that has not been selected expires.], (pv("40960"), pv("6144"), pv("384"), pv("384"),)),
  ("CoinbaseMaturity", "consensus", [Maturity depth, in blocks, for spending coinbase outputs; also the depth for vote and revocation outputs once the treasury agenda is active, and for treasury balance changes (#chref("transactions"), #chref("treasury")).], (pv("256"), pv("16"), pv("16"), pv("16"),)),
  ("SStxChangeMaturity", "consensus", [Maturity depth for ticket change outputs, and for vote and revocation outputs before the treasury agenda is active.], (pv("1"),)),
  ("TicketPoolSizeWeight", "consensus", [Weight applied to the pool-size deviation in version 1 of the stake difficulty algorithm; not read by version 2.], (pv("4"),)),
  ("StakeDiffAlpha", "consensus", [Smoothing value of the original (version 1) stake difficulty algorithm.], (pv("1"),)),
  ("StakeDiffWindowSize", "consensus", [Number of blocks in one stake difficulty window; the ticket price changes only at multiples of this height.], (pv("144"), pv("144"), pv("8"), pv("8"),)),
  ("StakeDiffWindows", "consensus", [Number of windows in the weighted average of version 1 of the stake difficulty algorithm; not read by version 2.], (pv("20"), pv("20"), pv("8"), pv("8"),)),
  ("MaxFreshStakePerBlock", "consensus", [Maximum number of ticket purchases a block may contain.], (pv("20"),)),
  ("StakeEnabledHeight", "consensus", [First height at which a ticket can be live (the earliest possible maturity).], (pv("512"), pv("32"), pv("32"), pv("32"),)),
  ("StakeValidationHeight", "consensus", [First height whose block must contain votes (at least a majority of #param("TicketsPerBlock")). Those votes are on the block one below, which is the first block voted on and the first on which the ticket lottery runs. (The doc comment in dcrd says the block at this height contains no votes, which does not match the code.)], (pv("4096"), pv("768"), pv("144"), pv("144"),)),
  ("StakeBaseSigScript", "consensus", [Required signature script of the stakebase input of every vote.], (pv("0000"), pv("0000"), pv("0000"), pv("7357"),)),
)) <tab:parameters-stake>

The stake system that these parameters configure is specified in
#chref("staking")\; the two stake difficulty algorithms are in
#chref("difficulty"). Regnet's #param("StakeBaseSigScript") is `7357`, unlike
the `0000` of the other networks; a vote on regnet #MUST carry exactly those
two bytes.

=== Voting, Versions and Upgrades <sec:parameters-voting>

#ptable([Voting, version and upgrade parameters], (
  ("StakeVersionInterval", "consensus", [Number of blocks in a stake version interval.], (pv("2016"), pv("2016"), pv("112"), pv("112"),)),
  ("StakeMajorityMultiplier", "consensus", [Numerator of the stake-version majority fraction.], (pv("3"),)),
  ("StakeMajorityDivisor", "consensus", [Denominator of the stake-version majority fraction.], (pv("4"),)),
  ("RuleChangeActivationQuorum", "consensus", [Minimum number of non-abstaining votes in a rule change interval for an agenda vote to count.], (pv("4032"), pv("2520"), pv("160"), pv("160"),)),
  ("RuleChangeActivationMultiplier", "consensus", [Numerator of the fraction of non-abstaining votes a choice needs to win.], (pv("3"),)),
  ("RuleChangeActivationDivisor", "consensus", [Denominator of that fraction.], (pv("4"),)),
  ("RuleChangeActivationInterval", "consensus", [Number of blocks in a rule change interval.], (pv("8064"), pv("5040"), pv("320"), pv("320"),)),
  ("Deployments", "consensus", [Agendas keyed by stake version. Summary in @tab:parameters-deployments; full definitions in #chref("voting").], (pv("13 agendas"), pv("12 agendas"), pv("13 agendas"), pv("13 agendas"),)),
  ("BlockEnforceNumRequired", "consensus", [Legacy block-version upgrade: number of recent blocks at a version needed to enforce rules of that version.], (pv("750"), pv("51"), pv("51"), pv("51"),)),
  ("BlockRejectNumRequired", "consensus", [Legacy block-version upgrade: number of recent blocks at a higher version needed to reject older block versions.], (pv("950"), pv("75"), pv("75"), pv("75"),)),
  ("BlockUpgradeNumToCheck", "consensus", [Legacy block-version upgrade: number of most recent blocks examined.], (pv("1000"), pv("100"), pv("100"), pv("100"),)),
)) <tab:parameters-voting>

@tab:parameters-deployments summarizes #param("Deployments"). Each cell gives
the stake version under which the agenda is defined and its vote mask, and
below it either the median-time voting period (start and expiry dates, UTC),
the forced choice, or "start 0, never expires" for agendas that are always
open for voting. The agenda definitions in full (descriptions, choices and
bits), the voting rules, and the outcome of every vote are owned by
#chref("voting").

#deptable((
  ("maxblocksize", true, (pv("absent", note: "never active"), pv("absent", note: "always active"), pv("v4 0x0006", note: "forced: yes"), pv("v4 0x0006", note: "start 0, never expires"))),
  ("sdiffalgorithm", true, (pv("v4 0x0006", note: "2017-04-26 to 2018-04-26"), pv("v5 0x0006", note: "forced: yes"), pv("v5 0x0006", note: "forced: yes"), pv("v5 0x0006", note: "start 0, never expires"))),
  ("lnsupport", false, (pv("v4 0x0018", note: "2017-04-26 to 2017-10-26"), pv("absent"), pv("absent"), pv("absent"))),
  ("lnfeatures", true, (pv("v5 0x0006", note: "2017-09-13 to 2018-09-13"), pv("v6 0x0006", note: "forced: yes"), pv("v6 0x0006", note: "forced: yes"), pv("v6 0x0006", note: "start 0, never expires"))),
  ("fixlnseqlocks", true, (pv("v6 0x0006", note: "2019-01-28 to 2020-01-28"), pv("v7 0x0006", note: "2019-01-28 to 2020-01-28"), pv("v7 0x0006", note: "forced: yes"), pv("v7 0x0006", note: "start 0, never expires"))),
  ("headercommitments", true, (pv("v7 0x0006", note: "2019-09-05 to 2020-09-05"), pv("v8 0x0006", note: "2019-09-05 to 2020-09-05"), pv("v8 0x0006", note: "forced: yes"), pv("v8 0x0006", note: "start 0, never expires"))),
  ("treasury", true, (pv("v8 0x0006", note: "2020-08-01 to 2021-08-01"), pv("v9 0x0006", note: "2020-08-01 to 2021-08-01"), pv("v9 0x0006", note: "forced: yes"), pv("v9 0x0006", note: "start 0, never expires"))),
  ("reverttreasurypolicy", true, (pv("v9 0x0006", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0006", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0006", note: "forced: yes"), pv("v10 0x0006", note: "start 0, never expires"))),
  ("explicitverupgrades", true, (pv("v9 0x0018", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0018", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0018", note: "forced: yes"), pv("v10 0x0018", note: "start 0, never expires"))),
  ("autorevocations", true, (pv("v9 0x0060", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0060", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0060", note: "forced: yes"), pv("v10 0x0060", note: "start 0, never expires"))),
  ("changesubsidysplit", true, (pv("v9 0x0180", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0180", note: "2021-09-16 to 2023-09-16"), pv("v10 0x0180", note: "forced: yes"), pv("v10 0x0180", note: "start 0, never expires"))),
  ("blake3pow", true, (pv("v10 0x0006", note: "2023-04-24 to 2025-04-24"), pv("v11 0x0006", note: "2023-04-24 to 2025-04-24"), pv("v11 0x0006", note: "forced: yes"), pv("v11 0x0006", note: "start 0, never expires"))),
  ("changesubsidysplitr2", true, (pv("v10 0x0060", note: "2023-04-24 to 2025-04-24"), pv("v11 0x0060", note: "2023-04-24 to 2025-04-24"), pv("v11 0x0060", note: "forced: yes"), pv("v11 0x0060", note: "start 0, never expires"))),
  ("maxtreasuryspend", true, (pv("v11 0x0006", note: "2025-11-13 to 2027-11-13"), pv("v12 0x0006", note: "2025-11-13 to 2027-11-13"), pv("v12 0x0006", note: "forced: yes"), pv("v12 0x0006", note: "start 0, never expires"))),
)) <tab:parameters-deployments>

dcrd maintains a list of the agenda identifiers that influence consensus
(every row except `lnsupport`, whose vote only requested development work).
When such an agenda has no deployment in a network's parameters, dcrd creates
a default one that is never active on the main network and always active on
every other network; these are the cells marked "absent" with "never active"
or "always active" (#src("internal/blockchain/agendas.go",
"requiredAgendaIDs")). A forced choice makes the agenda behave as if that
choice had won, without a vote; simnet uses this for every agenda and testnet3 for its two oldest, to activate
rules that mainnet adopted by vote. Regnet defines every agenda without a
forced choice, so on regnet each rule change is put to an actual vote.

#note[
  On mainnet and testnet3 dcrd also records the outcome of past votes as
  historical facts (the block at which each agenda's activation was
  determined), which lets it decide activation without re-tallying votes.
  This list lives in #src("internal/blockchain/agendas.go",
  "makeHistoricalAgendas") rather than in `chaincfg` and is described in
  #chref("voting").
]

=== Treasury

#ptable([Treasury parameters], (
  ("PiKeys", "consensus", [Public keys authorized to sign treasury spends (@tab:parameters-pikeys).], (pv("2 keys"),)),
  ("TreasuryVoteInterval", "consensus", [Treasury vote interval (TVI) in blocks: treasury spends may only be included at heights that are non-zero multiples of it.], (pv("288"), pv("60"), pv("48"), pv("4"),)),
  ("TreasuryVoteIntervalMultiplier", "consensus", [Number of TVIs in a treasury spend voting window.], (pv("12"), pv("4"), pv("3"), pv("3"),)),
  ("TreasuryVoteQuorumMultiplier", "consensus", [Numerator of the treasury spend quorum, as a fraction of the votes possible in the voting window.], (pv("1"),)),
  ("TreasuryVoteQuorumDivisor", "consensus", [Denominator of that quorum.], (pv("5"),)),
  ("TreasuryVoteRequiredMultiplier", "consensus", [Numerator of the fraction of yes votes a treasury spend requires.], (pv("3"),)),
  ("TreasuryVoteRequiredDivisor", "consensus", [Denominator of that fraction.], (pv("5"),)),
  ("TreasuryExpenditureWindow", "consensus", [Number of voting windows (TVI times multiplier) in one expenditure policy window.], (pv("2"), pv("4"), pv("4"), pv("4"),)),
  ("TreasuryExpenditurePolicy", "consensus", [Original (DCP-0006) policy only: number of earlier expenditure windows averaged.], (pv("6"), pv("3"), pv("3"), pv("3"),)),
  ("TreasuryExpenditureBootstrap", "consensus", [Original (DCP-0006) policy only: average expenditure, in atoms, assumed when none of those windows contains a treasury spend.], (pv("1600000000000", note: "16000 DCR"), pv("1000000000000", note: "10000 DCR"), pv("10000000000", note: "100 DCR"), pv("10000000000", note: "100 DCR"),)),
)) <tab:parameters-treasury>

#ltable([Sanctioned Politeia keys (compressed secp256k1 public keys)], "tab:parameters-pikeys", (
  ("PiKeys[0]", "mainnet", hx("03f6e7041f1cf51ee10e0a01cd2b0385ce3cd9debaabb2296f7e9dee9329da946c")),
  ("PiKeys[1]", "mainnet", hx("0319a37405cb4d1691971847d7719cfce70857c0f6e97d7c9174a3998cf0ab86dd")),
  ("PiKeys[0]", "testnet3", hx("03beca9bbd227ca6bb5a58e03a36ba2b52fff09093bd7a50aee1193bccd257fb8a")),
  ("PiKeys[1]", "testnet3", hx("03e647c014f55265da506781f0b2d67674c35cb59b873d9926d483c4ced9a7bbd3")),
  ("PiKeys[0]", "simnet", hx("02a36b785d584555696b69d1b2bbeff4010332b301e3edd316d79438554cacb3e7")),
  ("PiKeys[1]", "simnet", hx("02b2c110e7b560aa9e1545dd18dd9f7e74a3ba036297a696050c0256f1f69479d7")),
  ("PiKeys[0]", "regnet", hx("03b459ccf3ce4935a676414fd9ec93ecf7c9dad081a52ed6993bf073c627499388")),
  ("PiKeys[1]", "regnet", hx("02e3af1209f4d39dd8b448ef0a5375befa85bbc50be0aa0936379d67444184a2c3")),
))

The treasury rules are specified in #chref("treasury"). All three
expenditure policies measure spending over a policy window whose length in
blocks is the product of #param("TreasuryVoteInterval"),
#param("TreasuryVoteIntervalMultiplier") and
#param("TreasuryExpenditureWindow"). Of the remaining parameters, only the
original DCP-0006 policy uses #param("TreasuryExpenditurePolicy") and
#param("TreasuryExpenditureBootstrap")\; the DCP-0007 policy uses neither; the
DCP-0013 policy has no parameters of its own in `chaincfg` and derives a floor
for its limit from #param("BaseSubsidy") (@tab:parameters-derived). For simnet and regnet, the private keys belonging to
the two Pi keys are published in the dcrd source, so anyone can sign treasury
spends on those networks.

=== Checkpoints and Synchronization

#ptable([Checkpoint and synchronization parameters], (
  ("Checkpoints", "unused", [Deprecated. Formerly the manual checkpoints; empty on every network and not read.], (pv("empty"),)),
  ("AssumeValid", "node", [Hash of an externally verified block; some checks are skipped for its ancestors, and it anchors the rejection of old forks (#chref("blocks")). The fork rejection decides which blocks a node accepts, so an implementation that omits it accepts side-chain blocks that dcrd rejects; the check uses this hard-coded value, not an operator's override, and `--allowoldforks` disables it. All zero means not set.], ([see @tab:parameters-sync-long], [see @tab:parameters-sync-long], pv("zero (unset)"), pv("zero (unset)"),)),
  ("MinKnownChainWork", "node", [Minimum total chain work known at release time, used during initial synchronization. Unset on simnet and regnet.], ([see @tab:parameters-sync-long], [see @tab:parameters-sync-long], pv("nil (unset)"), pv("nil (unset)"),)),
)) <tab:parameters-sync>

#ltable([Assume-valid block (display form) and minimum known chain work (hexadecimal)], "tab:parameters-sync-long", (
  ("AssumeValid", "mainnet", hx("458d6a8e11c916d4149ca8bc5c7aaaaf16cc61971b0c20764c07edf85df44eb6")),
  ("AssumeValid", "testnet3", hx("e5d29f04aa33d19dfe4935ca2e70d8f640a7263b653f57ce600b6829d6f2cf48")),
  ("MinKnownChainWork", "mainnet", hx("000000000000000000000000000000000000000000243868232c14b8224643b6")),
  ("MinKnownChainWork", "testnet3", hx("000000000000000000000000000000000000000000000000f377240e146195df")),
))

None of the networks has manual checkpoints any longer. The assume-valid
block and the minimum known chain work are refreshed with dcrd releases and
are not consensus rules in themselves; how the assume-valid block anchors the
rejection of old forks, and that this rejection is disabled when
#param("AssumeValid") is zero (simnet and regnet), is specified in
#chref("blocks").

#pitfall[
  Since the `blake3pow` agenda (DCP-0011) the proof of work is checked
  against a BLAKE3 hash of the header, while the block hash that identifies a
  block is still the BLAKE-256 hash (#chref("difficulty")). Block hashes of
  blocks mined since then in general do not begin with zeros, as the
  assume-valid hashes in @tab:parameters-sync-long show. An implementation
  that sanity-checks block hashes for leading zeros rejects the current
  chain.
]

=== Address and Key Encoding

#ptable([Address and key encoding parameters], (
  ("NetworkAddressPrefix", "encoding", [First character of every address on the network. Not read by dcrd itself; the character follows from the address prefixes.], (pv("D"), pv("T"), pv("S"), pv("R"),)),
  ("PubKeyAddrID", "encoding", [Two-byte prefix of pay-to-pubkey addresses (all three signature types).], (pv("0x1386"), pv("0x28f7"), pv("0x276f"), pv("0x25e5"),)),
  ("PubKeyHashAddrID", "encoding", [Prefix of pay-to-pubkey-hash addresses, secp256k1 ECDSA.], (pv("0x073f"), pv("0x0f21"), pv("0x0e91"), pv("0x0e00"),)),
  ("PKHEdwardsAddrID", "encoding", [Prefix of pay-to-pubkey-hash addresses, Ed25519.], (pv("0x071f"), pv("0x0f01"), pv("0x0e71"), pv("0x0de0"),)),
  ("PKHSchnorrAddrID", "encoding", [Prefix of pay-to-pubkey-hash addresses, secp256k1 Schnorr.], (pv("0x0701"), pv("0x0ee3"), pv("0x0e53"), pv("0x0dc2"),)),
  ("ScriptHashAddrID", "encoding", [Prefix of pay-to-script-hash addresses.], (pv("0x071a"), pv("0x0efc"), pv("0x0e6c"), pv("0x0ddb"),)),
  ("PrivateKeyID", "encoding", [Prefix of WIF-encoded private keys.], (pv("0x22de"), pv("0x230e"), pv("0x2307"), pv("0x22fe"),)),
  ("HDPrivateKeyID", "encoding", [Version bytes of serialized extended private keys.], (pv("0x02fda4e8"), pv("0x04358397"), pv("0x0420b903"), pv("0xeab40448"),)),
  ("HDPublicKeyID", "encoding", [Version bytes of serialized extended public keys.], (pv("0x02fda926"), pv("0x043587d1"), pv("0x0420bd3d"), pv("0xeab4f987"),)),
  ("SLIP0044CoinType", "encoding", [SLIP-0044 coin type used in hierarchical deterministic derivation paths. Read by wallets, not by dcrd.], (pv("42"), pv("1"), pv("1"), pv("1"),)),
  ("LegacyCoinType", "encoding", [Coin type used by older wallets, kept for backwards compatibility. Read by wallets, not by dcrd.], (pv("20"), pv("11"), pv("115"), pv("1"),)),
)) <tab:parameters-encoding>

@tab:parameters-addresses shows the leading characters that each prefix
produces. They were computed by Base58-encoding the prefix followed by an
all-zero and by an all-`0xff` payload and checksum of the correct length and
keeping the characters common to both, so every valid string of that type
begins with them; the encoded length is given in parentheses. The payload is
20 bytes for the hash-based addresses, 33 bytes (a type byte and a 32-byte
coordinate or key) for pay-to-pubkey addresses and WIF keys, and 74 bytes
after the 4-byte version for extended keys. The encodings themselves are
specified in #chref("addresses").

#atable((
  ([Pay-to-pubkey (33-byte payload)], "PubKeyAddrID", (pv("0x1386", note: "Dk... (53 chars)"), pv("0x28f7", note: "Tk... (53 chars)"), pv("0x276f", note: "Sk... (53 chars)"), pv("0x25e5", note: "Rk... (53 chars)"))),
  ([P2PKH, secp256k1 ECDSA], "PubKeyHashAddrID", (pv("0x073f", note: "Ds... (35 chars)"), pv("0x0f21", note: "Ts... (35 chars)"), pv("0x0e91", note: "Ss... (35 chars)"), pv("0x0e00", note: "Rs... (35 chars)"))),
  ([P2PKH, Ed25519], "PKHEdwardsAddrID", (pv("0x071f", note: "De... (35 chars)"), pv("0x0f01", note: "Te... (35 chars)"), pv("0x0e71", note: "Se... (35 chars)"), pv("0x0de0", note: "Re... (35 chars)"))),
  ([P2PKH, secp256k1 Schnorr], "PKHSchnorrAddrID", (pv("0x0701", note: "DS... (35 chars)"), pv("0x0ee3", note: "TS... (35 chars)"), pv("0x0e53", note: "SS... (35 chars)"), pv("0x0dc2", note: "RS... (35 chars)"))),
  ([Pay-to-script-hash], "ScriptHashAddrID", (pv("0x071a", note: "Dc... (35 chars)"), pv("0x0efc", note: "Tc... (35 chars)"), pv("0x0e6c", note: "Sc... (35 chars)"), pv("0x0ddb", note: "Rc... (35 chars)"))),
  ([WIF private key (type byte + 32-byte key)], "PrivateKeyID", (pv("0x22de", note: "Pm... (53 chars)"), pv("0x230e", note: "Pt... (53 chars)"), pv("0x2307", note: "Ps... (53 chars)"), pv("0x22fe", note: "Pr... (53 chars)"))),
  ([Extended private key], "HDPrivateKeyID", (pv("0x02fda4e8", note: "dprv... (111 chars)"), pv("0x04358397", note: "tprv... (111 chars)"), pv("0x0420b903", note: "sprv... (111 chars)"), pv("0xeab40448", note: "rprv1... (112 chars)"))),
  ([Extended public key], "HDPublicKeyID", (pv("0x02fda926", note: "dpub... (111 chars)"), pv("0x043587d1", note: "tpub... (111 chars)"), pv("0x0420bd3d", note: "spub... (111 chars)"), pv("0xeab4f987", note: "rpub1... (112 chars)"))),
)) <tab:parameters-addresses>

== Derived Quantities <sec:parameters-derived>

@tab:parameters-derived lists quantities that follow arithmetically from the
parameters and that implementers frequently need. $T$ is
#param("TargetTimePerBlock") in seconds. The two rows marked "Check" verify
relations that the dcrd comments state between parameters. The treasury rows
follow the computations in #src("internal/blockchain/treasury.go",
"checkTSpendHasVotes") and #src("internal/blockchain/chain.go", "New"): a
treasury spend voting window spans #param("TreasuryVoteInterval") $times$
#param("TreasuryVoteIntervalMultiplier") blocks, the number of votes possible
in it is that times #param("TicketsPerBlock"), and the DCP-0013 floor on the
spending limit is $floor("BaseSubsidy" \/ 10)$ times the window length. The
exact use of each quantity is specified in the chapter that owns it.

#dtable((
  ([Blocks per day], [$86400 \/ T$], (pv("288"), pv("720"), pv("86400"), pv("86400"),)),
  ([Expected blocks in two weeks], [$floor(14 dot 86400 \/ T)$], (pv("4032", note: "14 d"), pv("10080", note: "14 d"), pv("1209600", note: "14 d"), pv("1209600", note: "14 d"),)),
  ([Check: #param("TargetTimespan")], [$=$ #param("WorkDiffWindowSize") $dot T$], (pv("true"),)),
  ([V1 PoW retarget interval], [#param("WorkDiffWindowSize")], (pv("144", note: "12 h"), pv("144", note: "4.8 h"), pv("8", note: "8 s"), pv("8", note: "8 s"),)),
  ([V1 PoW averaging span], [#param("WorkDiffWindowSize") $times$ #param("WorkDiffWindows")], (pv("2880", note: "10 d"), pv("2880", note: "4 d"), pv("32", note: "32 s"), pv("32", note: "32 s"),)),
  ([ASERT half-life in blocks], [#param("WorkDiffV2HalfLifeSecs") $\/ T$], (pv("144"), pv("6"), pv("6"), pv("6"),)),
  ([Subsidy reduction interval], [#param("SubsidyReductionInterval")], (pv("6144", note: "21.33 d"), pv("2048", note: "2.84 d"), pv("128", note: "2.13 min"), pv("128", note: "2.13 min"),)),
  ([Original split PoW / PoS / treasury], [proportions over their sum], (pv("6/3/1 of 10"),)),
  ([Target live ticket pool], [#param("TicketPoolSize") $times$ #param("TicketsPerBlock")], (pv("40960"), pv("5120"), pv("320"), pv("320"),)),
  ([Ticket price window], [#param("StakeDiffWindowSize")], (pv("144", note: "12 h"), pv("144", note: "4.8 h"), pv("8", note: "8 s"), pv("8", note: "8 s"),)),
  ([Ticket price averaging span (version 1 algorithm only)], [#param("StakeDiffWindowSize") $times$ #param("StakeDiffWindows")], (pv("2880", note: "10 d"), pv("2880", note: "4 d"), pv("64", note: "1.07 min"), pv("64", note: "1.07 min"),)),
  ([Ticket maturity], [#param("TicketMaturity")], (pv("256", note: "21.33 h"), pv("16", note: "32 min"), pv("16", note: "16 s"), pv("16", note: "16 s"),)),
  ([Ticket expiry], [#param("TicketExpiry")], (pv("40960", note: "142.22 d"), pv("6144", note: "8.53 d"), pv("384", note: "6.4 min"), pv("384", note: "6.4 min"),)),
  ([Check: #param("TicketExpiry") $>=$], [#param("StakeEnabledHeight") $+$ #param("StakeValidationHeight")], (pv("true"),)),
  ([Coinbase maturity], [#param("CoinbaseMaturity")], (pv("256", note: "21.33 h"), pv("16", note: "32 min"), pv("16", note: "16 s"), pv("16", note: "16 s"),)),
  ([Stake enabled height], [#param("StakeEnabledHeight")], (pv("512", note: "1.78 d"), pv("32", note: "1.07 h"), pv("32", note: "32 s"), pv("32", note: "32 s"),)),
  ([Stake validation height], [#param("StakeValidationHeight")], (pv("4096", note: "14.22 d"), pv("768", note: "1.07 d"), pv("144", note: "2.4 min"), pv("144", note: "2.4 min"),)),
  ([Stake version interval], [#param("StakeVersionInterval")], (pv("2016", note: "7 d"), pv("2016", note: "2.8 d"), pv("112", note: "1.87 min"), pv("112", note: "1.87 min"),)),
  ([Rule change interval], [#param("RuleChangeActivationInterval")], (pv("8064", note: "28 d"), pv("5040", note: "7 d"), pv("320", note: "5.33 min"), pv("320", note: "5.33 min"),)),
  ([Votes possible per rule change interval], [#param("RuleChangeActivationInterval") $times$ #param("TicketsPerBlock")], (pv("40320"), pv("25200"), pv("1600"), pv("1600"),)),
  ([Rule change quorum as a share of those], [#param("RuleChangeActivationQuorum") $\/$ previous row], (pv("10 %"),)),
  ([Treasury vote interval (TVI)], [#param("TreasuryVoteInterval")], (pv("288", note: "1 d"), pv("60", note: "2 h"), pv("48", note: "48 s"), pv("4", note: "4 s"),)),
  ([Treasury spend voting window], [TVI $times$ #param("TreasuryVoteIntervalMultiplier")], (pv("3456", note: "12 d"), pv("240", note: "8 h"), pv("144", note: "2.4 min"), pv("12", note: "12 s"),)),
  ([Votes possible in a voting window], [window $times$ #param("TicketsPerBlock")], (pv("17280"), pv("1200"), pv("720"), pv("60"),)),
  ([Treasury spend quorum (votes)], [possible votes $times$ #param("TreasuryVoteQuorumMultiplier") $\/$ #param("TreasuryVoteQuorumDivisor"), rounded down], (pv("3456"), pv("240"), pv("144"), pv("12"),)),
  ([Treasury spend yes fraction], [#param("TreasuryVoteRequiredMultiplier") $\/$ #param("TreasuryVoteRequiredDivisor")], (pv("60 %"),)),
  ([Expenditure policy window], [voting window $times$ #param("TreasuryExpenditureWindow")], (pv("6912", note: "24 d"), pv("960", note: "1.33 d"), pv("576", note: "9.6 min"), pv("48", note: "48 s"),)),
  ([DCP-0006 averaging span], [policy window $times$ #param("TreasuryExpenditurePolicy")], (pv("41472", note: "144 d"), pv("2880", note: "4 d"), pv("1728", note: "28.8 min"), pv("144", note: "2.4 min"),)),
  ([DCP-0013 spend limit floor (atoms)], [#param("BaseSubsidy") $\/ 10$ (rounded down) $times$ voting window], (pv("1078127767296", note: "10781.27767296 DCR"), pv("60000000000", note: "600 DCR"), pv("720000000000", note: "7200 DCR"), pv("60000000000", note: "600 DCR"),)),
  ([Block-one ledger total], [sum of the #param("BlockOneLedger") amounts], (pv("1680000 DCR", note: "168000000000000 atoms"), pv("100000 DCR", note: "10000000000000 atoms"), pv("300000 DCR", note: "30000000000000 atoms"), pv("300000 DCR", note: "30000000000000 atoms"),)),
)) <tab:parameters-derived>

== Network-Specific Rules Outside the Parameters <sec:parameters-exceptions>

A few consensus rules depend on the network but are not expressed through
`chaincfg.Params`. dcrd selects them by comparing #param("Net") with the
magic of a particular network. They are listed here so that an implementation
supporting several networks does not miss them; each is specified in the
chapter given.

#figure(
  caption: [Hard-coded network-specific rules],
  table(
    columns: (auto, 1fr, auto),
    table.header([Network], [Rule], [Specified in]),
    [testnet3],
    [The minimum-difficulty reduction of #param("ReduceMinDifficulty") applies
      only to blocks below height #tn-maxdiff-height. From that height a
      maximum difficulty applies: the target is never allowed below
      #param("PowLimit") shifted right by #tn-maxdiff-shift bits, i.e.
      #hx(tn-min-target), compact #raw(tn-min-bits), and blocks at that
      maximum difficulty must be at least one minute apart. The block at
      height #tn-maxdiff-height #MUST have hash #hx(tn-maxdiff-hash)
      (display form); any other block at that height is rejected.],
    [#chref("difficulty")],

    [mainnet, testnet3],
    [Exemptions from the DCP-0005 block-version check for blocks that were
      accepted in violation of it: five specific version-6 blocks on mainnet
      (heights 413762 to 430191), and every version-7 block up to height
      323282 on testnet3.],
    [#chref("voting")],

    [mainnet; others],
    [The latest block version below which blocks become rejectable by
      majority is 11 on mainnet and 12 on every other network.],
    [#chref("voting")],

    [mainnet; others],
    [The lowest block version for which dcrd's header-stage difficulty check
      considers the ASERT result before the agenda state is known is 10 on
      mainnet and 11 on every other network. This is not itself a consensus
      rule: the proof-of-work rules of #chref("difficulty") do not depend on
      the block version.],
    [#chref("difficulty")],

    [mainnet, testnet3],
    [A list of specific outputs (six on mainnet, one on testnet3) that were
      spent by a stake transaction in the same block under rules that were
      later tightened, and that remain acceptable.],
    [#chref("transactions")],

    [mainnet],
    [A deployment with a forced choice is refused on the main network
      (`ErrForcedMainNetChoice`).],
    [#chref("voting")],

    [mainnet, testnet3],
    [Historical agenda activation anchors (@sec:parameters-voting).],
    [#chref("voting")],
  ),
) <tab:parameters-exceptions>

== Genesis Blocks <sec:parameters-genesis>

The genesis block is the block at height 0. It has no parent and is not
produced by mining: each network's genesis block is a constant of the
protocol, written out field by field in `chaincfg` and given here in full.

#rule("Genesis block", src: ("internal/blockchain/chainio.go · createChainState", "internal/blockchain/validate.go · checkBlockHeaderPositional, checkBlockPositional"))[
  The block at height 0 of a network #MUST be exactly the genesis block given
  in this section for that network, whose serialization is given at the end of this section. The genesis block is valid by definition:
  none of the validation rules of #chref("blocks") or #chref("transactions")
  is applied to it, including proof of work, Merkle root and size checks. A
  block at height 1 #MUST name the genesis block's hash as its previous
  block.
] <rule:parameters-genesis>

#rule("Genesis outputs are not spendable", src: ("internal/blockchain/chainio.go · createChainState", "internal/blockchain/utxoviewpoint.go · FetchUtxoView"))[
  The transactions of the genesis block are never connected: the UTXO set of
  a chain whose tip is the genesis block is empty. An input that references
  an output of the genesis coinbase therefore references an output that does
  not exist, and the transaction containing it #MUST be rejected as for any
  missing input (#chref("transactions")).
] <rule:parameters-genesis-unspendable>

Besides serving as the parent of block 1, the genesis header's values that
matter to later blocks are its timestamp, which is the median time of the
chain while the genesis block is the tip, and its difficulty bits, which are
the starting point of the proof-of-work difficulty computation
(#chref("difficulty")). Agendas are never active for the genesis block. The
version 2 compact filter of the genesis block is computed by the ordinary
algorithm with no spent scripts and contains one item (#chref("filters")).

@tab:parameters-genesis-header lists every header field
(#chref("encoding") specifies the header layout) and
@tab:parameters-genesis-tx every field of the single coinbase transaction.
No genesis block has stake transactions.

#gtable([Genesis block headers], "tab:parameters-genesis-header", (
  ("Version", (pv("1"), pv("6"), pv("1"), pv("1"),)),
  ("PrevBlock", (pv("zero"),)),
  ("MerkleRoot", (pv("66aa7491...", note: "full value below"), pv("e7dfbcea...", note: "full value below"), pv("5c9488e2...", note: "full value below"), pv("66aa7491...", note: "full value below"),)),
  ("StakeRoot", (pv("zero"),)),
  ("VoteBits", (pv("0"),)),
  ("FinalState", (pv("000000000000"),)),
  ("Voters", (pv("0"),)),
  ("FreshStake", (pv("0"),)),
  ("Revocations", (pv("0"),)),
  ("PoolSize", (pv("0"),)),
  ("Bits", (pv("0x1b01ffff"), pv("0x1e00ffff"), pv("0x207fffff"), pv("0x207fffff"),)),
  ("SBits", (pv("200000000", note: "2 DCR"), pv("20000000", note: "0.2 DCR"), pv("0", note: "0 DCR"), pv("0", note: "0 DCR"),)),
  ("Height", (pv("0"),)),
  ("Size", (pv("0"),)),
  ("Timestamp", (pv("1454954400", note: "2016-02-08 18:00:00 UTC"), pv("1533513600", note: "2018-08-06 00:00:00 UTC"), pv("1401292357", note: "2014-05-28 15:52:37 UTC"), pv("1538524800", note: "2018-10-03 00:00:00 UTC"),)),
  ("Nonce", (pv("0x00000000"), pv("0x18aea41a"), pv("0x00000000"), pv("0x00000000"),)),
  ("ExtraData", (pv("zero"),)),
  ("StakeVersion", (pv("0"), pv("6"), pv("0"), pv("0"),)),
))

#gtable([Genesis coinbase transactions], "tab:parameters-genesis-tx", (
  ("SerType", (pv("0", note: "full"),)),
  ("Version", (pv("1"),)),
  ("inputs", (pv("1"),)),
  ("in: PreviousOutPoint.Hash", (pv("zero"),)),
  ("in: PreviousOutPoint.Index", (pv("0xffffffff"),)),
  ("in: PreviousOutPoint.Tree", (pv("0"),)),
  ("in: Sequence", (pv("0xffffffff"),)),
  ("in: ValueIn", (pv("-1"), pv("-1"), pv("0"), pv("-1"),)),
  ("in: BlockHeight", (pv("0x00000000"),)),
  ("in: BlockIndex", (pv("0xffffffff"), pv("0xffffffff"), pv("0x00000000"), pv("0xffffffff"),)),
  ("in: SignatureScript", (pv("0000", note: "2 bytes"), pv("0000", note: "2 bytes"), pv("77 bytes", note: "full value below"), pv("0000", note: "2 bytes"),)),
  ("outputs", (pv("1"),)),
  ("out: Value", (pv("0"),)),
  ("out: Version", (pv("0"),)),
  ("out: PkScript", (pv("32 bytes", note: "full value below"), pv("32 bytes", note: "full value below"), pv("67 bytes", note: "full value below"), pv("32 bytes", note: "full value below"),)),
  ("LockTime", (pv("0"),)),
  ("Expiry", (pv("0"),)),
))

#ltable([Genesis coinbase scripts (hexadecimal and dcrd disassembly)], "tab:parameters-genesis-scripts", (
  ("SignatureScript", "mainnet", [#hx("0000") \ #text(size: 7pt)[0 0]]),
  ("SignatureScript", "testnet3", [#hx("0000") \ #text(size: 7pt)[0 0]]),
  ("SignatureScript", "simnet", [#hx("04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73") \ #text(size: 7pt)[ffff001d 04 #hex("5468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73")]]),
  ("SignatureScript", "regnet", [#hx("0000") \ #text(size: 7pt)[0 0]]),
  ("PkScript", "mainnet", [#hx("801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9") \ #text(size: 7pt)[OP\_LEFT #hex("79e98561ada96caec2949a5d41c4cab3851eb740d951") OP\_TADD \[error\] (parse failure: opcode OP\_DATA\_14 requires 15 bytes, but script only has 7 remaining)] \ #text(size: 7pt)[class: nonstandard]]),
  ("PkScript", "testnet3", [#hx("801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9") \ #text(size: 7pt)[OP\_LEFT #hex("79e98561ada96caec2949a5d41c4cab3851eb740d951") OP\_TADD \[error\] (parse failure: opcode OP\_DATA\_14 requires 15 bytes, but script only has 7 remaining)] \ #text(size: 7pt)[class: nonstandard]]),
  ("PkScript", "simnet", [#hx("4104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac") \ #text(size: 7pt)[#hex("04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f") OP\_CHECKSIG] \ #text(size: 7pt)[class: pubkey]]),
  ("PkScript", "regnet", [#hx("801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9") \ #text(size: 7pt)[OP\_LEFT #hex("79e98561ada96caec2949a5d41c4cab3851eb740d951") OP\_TADD \[error\] (parse failure: opcode OP\_DATA\_14 requires 15 bytes, but script only has 7 remaining)] \ #text(size: 7pt)[class: nonstandard]]),
))

#ltable([Genesis block hashes (display form)], "tab:parameters-genesis-hashes", (
  ("block hash", "mainnet", hx("298e5cc3d985bfe7f81dc135f360abe089edd4396b86d2de66b0cef42b21d980")),
  ("block hash", "testnet3", hx("a649dce53918caf422e9c711c858837e08d626ecfcd198969b24f7b634a49bac")),
  ("block hash", "simnet", hx("6bef82c645999585f7255cb02672921ac2f5492820090cd635fe3a59d16b4f87")),
  ("block hash", "regnet", hx("2ced94b4ae95bba344cfa043268732d230649c640f92dce2d9518823d3057cb0")),
  ("MerkleRoot", "mainnet", hx("66aa7491b9adce110585ccab7e3fb5fe280de174530cca10eba2c6c3df01c10d")),
  ("MerkleRoot", "testnet3", hx("e7dfbceac9fccd6025c70a1dfa9302b3e7b5aa22fa51c98a69164ad403d60a2c")),
  ("MerkleRoot", "simnet", hx("5c9488e2f3425de9951ee31f4ad5803c4487a8f4a2719d60c3bf2b58c5295692")),
  ("MerkleRoot", "regnet", hx("66aa7491b9adce110585ccab7e3fb5fe280de174530cca10eba2c6c3df01c10d")),
  ("coinbase TxHash", "mainnet", hx("e7dfbceac9fccd6025c70a1dfa9302b3e7b5aa22fa51c98a69164ad403d60a2c")),
  ("coinbase TxHash", "testnet3", hx("e7dfbceac9fccd6025c70a1dfa9302b3e7b5aa22fa51c98a69164ad403d60a2c")),
  ("coinbase TxHash", "simnet", hx("a216ea043f0d481a072424af646787794c32bcefd3ed181a090319bbf8a37105")),
  ("coinbase TxHash", "regnet", hx("e7dfbceac9fccd6025c70a1dfa9302b3e7b5aa22fa51c98a69164ad403d60a2c")),
  ("coinbase TxHashFull", "mainnet", hx("66aa7491b9adce110585ccab7e3fb5fe280de174530cca10eba2c6c3df01c10d")),
  ("coinbase TxHashFull", "testnet3", hx("66aa7491b9adce110585ccab7e3fb5fe280de174530cca10eba2c6c3df01c10d")),
  ("coinbase TxHashFull", "simnet", hx("5c9488e2f3425de9951ee31f4ad5803c4487a8f4a2719d60c3bf2b58c5295692")),
  ("coinbase TxHashFull", "regnet", hx("66aa7491b9adce110585ccab7e3fb5fe280de174530cca10eba2c6c3df01c10d")),
))

#figure(
  caption: [Genesis Merkle root provenance and proof of work],
  table(
    columns: (1fr, vcol, vcol, vcol, vcol),
    inset: vinset,
    table.header([Property], ..netheads),
    [Merkle root field equals coinbase], ..genesis-merkle.map(r => pv(r.at(1))),
    [Block hash $<=$ target of its own #raw("Bits")], ..genesis-pow.map(r => pv(if r.at(1) { "yes" } else { "no" })),
  ),
) <tab:parameters-genesis-props>

Several properties of the genesis blocks are unusual and follow from their
being constants rather than validated blocks.

- *The mainnet, testnet3 and regnet coinbases are the same transaction.*
  Its single input has the null outpoint (zero hash, index `0xffffffff`,
  tree 0) and the null witness values (value in $-1$, block height 0, block
  index `0xffffffff`); its signature script is the two bytes `0000`. Its
  single output has value 0 and version 0, and its 32-byte output script does
  not even parse: after `OP_LEFT`, a 22-byte push and `OP_TADD`, a 14-byte
  push runs past the end of the script. It is not a standard script of any
  kind and could never be satisfied.
- *The simnet coinbase is different.* Its signature script pushes the bytes
  `ffff001d`, the byte `04`, and the ASCII text
  “#genesis-message.at(0).at(1)”, the coinbase message of
  Bitcoin's genesis block; its output is a 65-byte uncompressed public key
  followed by `OP_CHECKSIG`, again with value 0. Its input witness leaves the
  value in and block index at zero instead of the null values.
- *Merkle root.* The Merkle root of a block with a single regular
  transaction is that transaction's full hash (#chref("encoding")). The
  testnet3 genesis header instead carries the transaction's prefix hash
  (`TxHash`); the dcrd source acknowledges this as a mistake that cannot be
  corrected without changing the testnet3 genesis hash, and notes that the
  field is not validated. Mainnet and regnet share a Merkle root because
  they share the coinbase.
- *Header fields.* The `Size` field is 0 although each block is larger, and
  the stake root is zero. On mainnet and testnet3 the block hash does not
  satisfy the target encoded in the block's own `Bits`; on simnet and regnet,
  whose targets admit about half of all hashes, it happens to.
- *Stake fields.* The testnet3 genesis header has block version 6 and stake
  version 6, unlike the version 1 and stake version 0 of the other networks,
  and its `SBits` equals #param("MinimumStakeDiff") as on mainnet. Simnet and
  regnet have `SBits` 0.

The serialized blocks below were produced by serializing the
`chaincfg` genesis blocks with dcrd's `wire` package, checked by
deserializing them again, and hashed with dcrd; the hashes match
#param("GenesisHash"). The first 180 bytes of each are the block header, whose
BLAKE-256 hash is the block hash (#chref("crypto")).

#vector[mainnet genesis block: serialized (300 bytes; the first 180 are the header)][
  #hx("0100000000000000000000000000000000000000000000000000000000000000000000000dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb99174aa66000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffff011b00c2eb0b000000000000000000000000a0d7b856000000000000000000000000000000000000000000000000000000000000000000000000000000000101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff010000000000000000000020801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9000000000000000001ffffffffffffffff00000000ffffffff02000000")
]
#vector[testnet3 genesis block: serialized (300 bytes; the first 180 are the header)][
  #hx("0600000000000000000000000000000000000000000000000000000000000000000000002c0ad603d44a16698ac951fa22aab5e7b30293fa1d0ac72560cdfcc9eabcdfe7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffff001e002d3101000000000000000000000000808f675b1aa4ae180000000000000000000000000000000000000000000000000000000000000000060000000101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff010000000000000000000020801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9000000000000000001ffffffffffffffff00000000ffffffff02000000")
]
#vector[simnet genesis block: serialized (410 bytes; the first 180 are the header)][
  #hx("010000000000000000000000000000000000000000000000000000000000000000000000925629c5582bbfc3609d71a2f4a887443c80d54a1fe31e95e95d42f3e288945c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffff7f200000000000000000000000000000000045068653000000000000000000000000000000000000000000000000000000000000000000000000000000000101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff0100000000000000000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac000000000000000001000000000000000000000000000000004d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b7300")
]
#vector[regnet genesis block: serialized (300 bytes; the first 180 are the header)][
  #hx("0100000000000000000000000000000000000000000000000000000000000000000000000dc101dfc3c6a2eb10ca0c5374e10d28feb53f7eabcc850511ceadb99174aa66000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffff7f20000000000000000000000000000000008006b45b000000000000000000000000000000000000000000000000000000000000000000000000000000000101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff00ffffffff010000000000000000000020801679e98561ada96caec2949a5d41c4cab3851eb740d951c10ecbcf265c1fd9000000000000000001ffffffffffffffff00000000ffffffff02000000")
]

== Block-One Ledger <sec:parameters-ledger>

The coinbase of the block at height 1 does not pay the ordinary subsidy;
instead it must pay exactly the outputs listed in #param("BlockOneLedger")
(the premine on mainnet). @tab:parameters-ledger gives the number of outputs
and their total for each network. The outputs themselves, and the rules that
enforce them, are given in #chref("subsidy").

#figure(
  caption: [Block-one ledger summary],
  table(
    columns: (auto, auto, auto, auto, 1fr),
    table.header([Network], [Outputs], [Total (atoms)], [Total], [Script types]),
    ..ledger
      .map(r => (
        pv(r.at(0)),
        pv(r.at(1)),
        pv(r.at(2)),
        pv(r.at(3)),
        if r.at(5) == "0 / 0" { [all P2PKH (secp256k1 ECDSA), script version 0] } else { pv(r.at(4) + " P2PKH, " + r.at(5) + " P2SH/other") },
      ))
      .flatten()
  ),
) <tab:parameters-ledger>
