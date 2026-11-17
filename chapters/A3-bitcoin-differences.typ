#import "../template.typ": *

= Differences from Bitcoin <ch:bitcoin-differences>

Decred's code base descends from an implementation of Bitcoin, and much of
its structure will be familiar to anyone who knows that protocol. The
familiarity is a hazard: many details differ, and an implementation that
assumes Bitcoin's behavior where this document is silent will be wrong. This
appendix is informative. It lists the differences that most often mislead,
with a pointer to the chapter that specifies each one. It is a guide to the
document, not a substitute for it.

== Consensus Model

#figure(
  caption: [Consensus and governance],
  table(
    columns: (22%, 1fr, 1.25fr),
    table.header([Aspect], [Bitcoin], [Decred]),
    [Block validity], [Proof of work alone.], [Proof of work, and votes from a
      majority of the five tickets drawn for the block
      (#chref("staking")).],
    [Finality of a block's transactions], [Fixed once the block is mined.],
    [The regular transaction tree of a block takes effect only if the votes
      in the next block approve it (#chref("blocks")).],
    [Rule changes], [Activated by miner signaling or by a date or height
      chosen by developers.], [Decided by a stakeholder vote with a 75%
      threshold and a quorum, evaluated by a state machine in the consensus
      rules (#chref("voting")).],
    [Development funding], [None in the protocol.], [10% of every block
      reward accrues to a treasury spent only by stakeholder vote
      (#chref("treasury")).],
    [Target block interval], [10 minutes.], [5 minutes on the main network
      (#chref("parameters")).],
    [Issuance], [Halves every 210000 blocks.], [Multiplied by 100/101 every
      6144 blocks, and divided between miners, voters and the treasury
      (#chref("subsidy")).],
    [Proof-of-work function], [Double SHA-256 of the 80-byte header.],
    [BLAKE-256 of the 180-byte header originally; BLAKE3 since #dcp(11),
      computed separately from the block hash (#chref("difficulty")).],
    [Difficulty adjustment], [Every 2016 blocks, from the time taken by the
      previous 2016.], [Originally every 144 blocks from a weighted average
      over 20 windows; since #dcp(11) recomputed for every block by an
      exponential formula (#chref("difficulty")).],
  ),
)

== Hashes and Identifiers

#figure(
  caption: [Hash functions and identifiers],
  table(
    columns: (22%, 1fr, 1.25fr),
    table.header([Aspect], [Bitcoin], [Decred]),
    [General-purpose hash], [Double SHA-256.], [A single BLAKE-256 with 14
      rounds (#chref("crypto")).],
    [Block identifier], [Double SHA-256 of the header; also the
      proof-of-work hash.], [BLAKE-256 of the header. Since #dcp(11) it is
      distinct from the proof-of-work hash.],
    [Transaction identifier], [Hash of the transaction without witness data
      (since segregated witness).], [BLAKE-256 of the prefix serialization,
      which never included signature scripts (#chref("encoding")).],
    [Merkle tree leaves], [Transaction identifiers, with a separate witness
      commitment in the coinbase.], [Full transaction hashes, which commit to
      prefix and witness together (#chref("encoding")).],
    [`HASH160`], [RIPEMD-160 of SHA-256.], [RIPEMD-160 of BLAKE-256.],
    [`OP_HASH256`], [Double SHA-256.], [Double BLAKE-256. SHA-256 is
      available through `OP_SHA256` (#chref("script")).],
    [Address checksum], [First four bytes of double SHA-256.], [First four
      bytes of double BLAKE-256, over a two-byte version prefix
      (#chref("addresses")).],
    [P2P message checksum], [First four bytes of double SHA-256 (in the
      original, unencrypted transport).], [First
      four bytes of a single BLAKE-256 (#chref("p2p")).],
  ),
)

== Transactions and Blocks

#figure(
  caption: [Structures],
  table(
    columns: (22%, 1fr, 1.25fr),
    table.header([Aspect], [Bitcoin], [Decred]),
    [Block header], [80 bytes, six fields.], [180 bytes, eighteen fields,
      including the vote tally, ticket counts, ticket pool size, ticket
      price and lottery state (#chref("encoding")).],
    [Transactions in a block], [One list.], [Two lists: the regular tree and
      the stake tree (#chref("encoding"), #chref("blocks")).],
    [Transaction version field], [32-bit version.], [16-bit version and
      16-bit serialization type.],
    [Outpoint], [Transaction hash and output index.], [Transaction hash,
      output index and a tree byte.],
    [Input witness], [Signature script, or a witness stack.], [Signature
      script together with the amount, block height and block index of the
      output being spent, which are checked against the ledger
      (#chref("transactions")).],
    [Output], [Amount and script.], [Amount, 16-bit script version and
      script.],
    [Expiry], [None.], [An optional height from which the transaction is no
      longer valid.],
    [Maximum block size], [A weight limit of four million units.],
    [393216 bytes of serialized block on the main network
      (#chref("blocks")).],
    [Coinbase maturity], [100 blocks.], [256 blocks on the main network.],
    [Duplicate transaction check], [Enforced (BIP 30). The check
      is skipped for most blocks since the coinbase began to carry the height
      (BIP 34), which makes duplicates impractical but not impossible.], [Unnecessary from the
      start: every coinbase from height 2 carries the block height
      (#chref("blocks"), #chref("subsidy")).],
  ),
)

== Script

The script language has the same shape as Bitcoin's, a stack machine with no
loops, but differs in limits, in the set of enabled opcodes and in every
detail of signature checking. #chref("script") is the specification and
#chref("opcodes") lists every opcode.

#figure(
  caption: [Script],
  table(
    columns: (22%, 1fr, 1.25fr),
    table.header([Aspect], [Bitcoin], [Decred]),
    [Maximum script size], [10000 bytes.], [16384 bytes.],
    [Maximum pushed element], [520 bytes.], [2048 bytes.],
    [Maximum counted opcodes], [201.], [255.],
    [Maximum stack depth], [1000.], [1024.],
    [`OP_CHECKMULTISIG`], [Pops one extra unused element.], [Pops no extra
      element.],
    [`OP_CODESEPARATOR`], [Affects the signed script.], [Disabled.],
    [Splice, bitwise and arithmetic opcodes disabled in Bitcoin], [Disabled:
      a script containing them is invalid.], [Most are enabled, with 32-bit
      semantics defined in #chref("script")\; rotation opcodes are added.],
    [Signature schemes], [ECDSA, and BIP 340 Schnorr in Taproot outputs.],
    [ECDSA through `OP_CHECKSIG`; Ed25519 and a secp256k1 Schnorr scheme of
      Decred's own definition through `OP_CHECKSIGALT`
      (#chref("crypto")).],
    [Signature and key encoding], [Strict DER is consensus (BIP 66); low-S
      signatures and the rejection of hybrid public keys are relay policy for
      legacy scripts.], [Strict DER, low S and strict public key encoding
      (compressed or uncompressed only) are all consensus: a violation fails
      the script (#chref("script")).],
    [Hash opcodes], [`0xa8` is `OP_SHA256`; `OP_HASH160` and `OP_HASH256`
      are built on SHA-256.], [`0xa8` is `OP_BLAKE256`; `OP_HASH160` and
      `OP_HASH256` are built on BLAKE-256; `OP_SHA256` is `0xc0`, specified by
      #dcp(2) and enabled by the `lnfeatures` vote (#chref("script")).],
    [Bitwise opcodes], [`OP_INVERT`, `OP_AND`, `OP_OR` and `OP_XOR` operated
      on byte strings before they were disabled.], [They operate on 32-bit
      numbers.],
    [Signed messages], [Double SHA-256 of the prefixed message.], [A single
      BLAKE-256 of the prefixed message (#chref("addresses")); not
      consensus.],
    [Signature hash], [Several algorithms depending on output type.], [One
      algorithm, which hashes a prefix digest and a witness digest
      (#chref("script")).],
    [Stake and treasury opcodes], [None.], [Tag opcodes mark outputs that
      only tickets, votes, revocations and treasury transactions may create
      or spend (#chref("staking"), #chref("treasury")).],
    [Script upgrades], [New witness versions and Tapscript leaf versions.],
    [A script version on every output. Versions above those enabled by vote
      are rejected (#chref("voting")).],
    [Lock-time features], [BIP 65, BIP 68, BIP 112 and BIP 113.], [The same
      concepts with Decred-specific encodings and rules
      (#chref("transactions")). `OP_CHECKLOCKTIMEVERIFY` (BIP 65) has been
      enforced since launch; the rest were activated by #dcp(3).],
  ),
)

== Network and Wallets

#figure(
  caption: [Network and wallet conventions],
  table(
    columns: (22%, 1fr, 1.25fr),
    table.header([Aspect], [Bitcoin], [Decred]),
    [Light clients], [Compact block filters (BIP 157 and BIP 158) that
      headers do not commit to.], [Version 2 filters with different
      parameters and contents, committed to by every header since #dcp(5)
      (#chref("filters")).],
    [Unknown P2P messages], [Ignored.], [Treated as misbehavior by the
      reference node (#chref("p2p")).],
    [Hierarchical deterministic keys], [BIP 32.], [The same construction
      with different version bytes and a small number of differences in
      edge cases (#chref("addresses")).],
    [Coin mixing], [Not part of the node.], [A peer-to-peer mixing protocol
      is carried by the node's P2P network (#chref("mixing")).],
  ),
)
