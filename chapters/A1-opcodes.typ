#import "../template.typ": *

= Opcode Reference <ch:opcodes>

This appendix accounts for every one of the 256 possible opcode bytes of
script version 0. It is a summary: the normative definitions are the rules of
#chref("script"), referenced below, and where this table and those rules
differ, the rules govern. The table describes the operation performed when an
opcode is *executed*, that is, when it is reached by the program counter in an
executing branch; @tab:opcodes-classes describes how each class of opcode
behaves when it is reached in an unexecuted branch and whether it counts
toward the limit of 255 operations per script.

== Conventions

Stack effects are written `[inputs] → [outputs]`, listing only the elements
an opcode consumes and produces, bottom to top, with the top element last. In
the arithmetic, bitwise and comparison opcodes, letters denote numeric
operands, which must be minimally encoded script numbers of at most 4 bytes
(at most 5 bytes for the lock-time operands, at most 1 byte for the signature
type of `OP_CHECKSIGALT`); see #xref("sec:script-numbers"). Booleans are
pushed as `01` (true) and the empty string (false), and `ε` denotes the empty
string. An opcode that needs more elements than the stack holds fails with
`ErrInvalidStackOperation`. Flag values refer to #xref("tab:script-flags").

The *processing* steps common to all opcodes (the checks for disabled and
always-illegal opcodes, the operation count, the element size limit and the
minimal-push rule) are given in #xref("rule:script-opcode-processing"). Every
executed push must be minimal (#xref("rule:script-minimal-push")).

#figure(
  caption: [Opcode classes],
  table(
    columns: (auto, 1fr, 1fr, auto),
    table.header([Class], [When executed], [When reached in an unexecuted branch], [Counts as op]),
    [P #h(0.3em) push], [Pushes its value; must be minimal.], [No effect, but data longer than 2048 bytes still fails.], [no],
    [C #h(0.3em) conditional], [Opens, toggles or closes a block.], [Still processed: `OP_IF`/`OP_NOTIF` open a block without popping; `OP_ELSE` and `OP_ENDIF` act as specified.], [yes],
    [A #h(0.3em) active], [Performs its operation.], [No effect.], [yes],
    [G #h(0.3em) flag-gated], [With its flag: as listed. Without: as class U.], [No effect.], [yes],
    [N #h(0.3em) no-op], [No effect, under all flags.], [No effect.], [yes],
    [U #h(0.3em) upgradable no-op], [No effect; fails only under the policy flag `0x01`.], [No effect.], [yes],
    [R #h(0.3em) reserved], [Fails (`ErrReservedOpcode`).], [No effect.], [yes, except `0x50`],
    [I #h(0.3em) always illegal], [Fails (`ErrReservedOpcode`).], [Fails.], [n/a (fails first)],
    [D #h(0.3em) disabled], [Fails (`ErrDisabledOpcode`).], [Fails.], [n/a (fails first)],
  ),
) <tab:opcodes-classes>

The rule that decides whether an opcode counts toward the operation limit is
purely numeric: every opcode whose byte value is greater than `0x60` counts,
every other opcode does not. In addition, an executed
`OP_CHECKMULTISIG(VERIFY)` adds its key count $n$.

== Map of Byte Values

@tab:opcodes-map shows the class of every byte value at a glance. There are 96
push opcodes, 4 conditional opcodes, 70 active opcodes, 6 flag-gated opcodes,
7 no-operations, 61 upgradable no-operations, 9 reserved opcodes, 2 always
illegal opcodes and 1 disabled opcode.

#figure(
  caption: [Class of every byte value (row: high nibble, column: low nibble)],
  table(
    columns: (auto,) + (1fr,) * 16,
    align: center,
    table.header([], [`0`], [`1`], [`2`], [`3`], [`4`], [`5`], [`6`], [`7`], [`8`], [`9`], [`a`], [`b`], [`c`], [`d`], [`e`], [`f`]),
    [`0`], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P],
    [`1`], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P],
    [`2`], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P],
    [`3`], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P],
    [`4`], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P],
    [`5`], [R], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P], [P],
    [`6`], [P], [N], [R], [C], [C], [I], [I], [C], [C], [A], [A], [A], [A], [A], [A], [A],
    [`7`], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A],
    [`8`], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [N], [N], [A],
    [`9`], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A],
    [`a`], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [A], [D], [A], [A], [A], [A],
    [`b`], [U], [G], [G], [U], [U], [U], [U], [U], [U], [U], [N], [N], [N], [N], [A], [A],
    [`c`], [G], [G], [G], [G], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U],
    [`d`], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U],
    [`e`], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U], [U],
    [`f`], [U], [U], [U], [U], [U], [U], [U], [U], [U], [R], [R], [R], [R], [R], [R], [R],
  ),
) <tab:opcodes-map>

== Opcode Table

Ranges of consecutive bytes with identical behaviour are given in a single
row; together the rows of @tab:opcodes-all cover all 256 values.

#figure(
  caption: [All opcode values],
  table(
    columns: (auto, 23%, auto, 21%, 1fr),
    align: (left, left, center, left, left),
    table.header([Byte], [Name], [Class], [Stack effect], [Semantics when executed]),
    [`0x00`], [`OP_0`], [P], [`[] → [ε]`], [Push the empty string (`OP_FALSE`).],
    [`0x01`–`0x4b`], [`OP_DATA_1` … `OP_DATA_75`], [P], [`[] → [d]`], [Push the next $n$ = byte value data bytes. Minimal unless the data is a single byte #box[`01`–`10`] or `81`.],
    [`0x4c`], [`OP_PUSHDATA1`], [P], [`[] → [d]`], [1-byte length $n$ follows, then $n$ data bytes; push them. Minimal only for 76–255 bytes.],
    [`0x4d`], [`OP_PUSHDATA2`], [P], [`[] → [d]`], [2-byte LE length $n$ follows, then $n$ bytes; push them. Minimal only for 256–65535 bytes.],
    [`0x4e`], [`OP_PUSHDATA4`], [P], [`[] → [d]`], [4-byte LE length $n$ follows, then $n$ bytes. Never minimal: always fails when executed.],
    [`0x4f`], [`OP_1NEGATE`], [P], [`[] → [-1]`], [Push `81`.],
    [`0x50`], [`OP_RESERVED`], [R], [—], [Fails if executed (`ErrReservedOpcode`). Not counted as an operation. Counts as push-only.],
    [`0x51`–`0x60`], [`OP_1` … `OP_16`], [P], [`[] → [n]`], [Push the number $n$ = byte $-$ `0x50`. `OP_1` is also `OP_TRUE`.],
    [`0x61`], [`OP_NOP`], [N], [`[] → []`], [No operation; never discouraged.],
    [`0x62`], [`OP_VER`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0x63`], [`OP_IF`], [C], [`[x] → []`], [Pop $x$ if executing; open a block, disabled if $x$ is false (#xref("rule:script-conditionals")).],
    [`0x64`], [`OP_NOTIF`], [C], [`[x] → []`], [As `OP_IF` with the condition inverted.],
    [`0x65`], [`OP_VERIF`], [I], [—], [Fails whenever reached, even unexecuted (`ErrReservedOpcode`).],
    [`0x66`], [`OP_VERNOTIF`], [I], [—], [Fails whenever reached, even unexecuted (`ErrReservedOpcode`).],
    [`0x67`], [`OP_ELSE`], [C], [`[] → []`], [Toggle execution of the innermost block; fails if no block is open.],
    [`0x68`], [`OP_ENDIF`], [C], [`[] → []`], [Close the innermost block; fails if no block is open.],
    [`0x69`], [`OP_VERIFY`], [A], [`[x] → []`], [Fail (`ErrVerify`) if $x$ is false.],
    [`0x6a`], [`OP_RETURN`], [A], [—], [Fail (`ErrEarlyReturn`).],
    [`0x6b`], [`OP_TOALTSTACK`], [A], [`[x] → []`], [Move $x$ to the alternate stack.],
    [`0x6c`], [`OP_FROMALTSTACK`], [A], [`[] → [x]`], [Move the top of the alternate stack to the data stack; fails if empty.],
    [`0x6d`], [`OP_2DROP`], [A], [`[a b] → []`], [Drop two.],
    [`0x6e`], [`OP_2DUP`], [A], [`[a b] → [a b a b]`], [Duplicate two.],
    [`0x6f`], [`OP_3DUP`], [A], [`[a b c] → [a b c a b c]`], [Duplicate three.],
    [`0x70`], [`OP_2OVER`], [A], [`[a b c d] → [a b c d a b]`], [Copy the pair below the top pair.],
    [`0x71`], [`OP_2ROT`], [A], [`[a b c d e f] → [c d e f a b]`], [Rotate three pairs.],
    [`0x72`], [`OP_2SWAP`], [A], [`[a b c d] → [c d a b]`], [Swap two pairs.],
    [`0x73`], [`OP_IFDUP`], [A], [`[x] → [x x]` / `[x]`], [Duplicate $x$ if it is true.],
    [`0x74`], [`OP_DEPTH`], [A], [`[] → [n]`], [Push the data stack depth (before the push).],
    [`0x75`], [`OP_DROP`], [A], [`[x] → []`], [Drop.],
    [`0x76`], [`OP_DUP`], [A], [`[x] → [x x]`], [Duplicate.],
    [`0x77`], [`OP_NIP`], [A], [`[a b] → [b]`], [Remove the second element.],
    [`0x78`], [`OP_OVER`], [A], [`[a b] → [a b a]`], [Copy the second element.],
    [`0x79`], [`OP_PICK`], [A], [`[… n] → [… xₙ]`], [Pop $n$ (4 bytes); copy the element $n$ below the top; $0 ≤ n <$ depth.],
    [`0x7a`], [`OP_ROLL`], [A], [`[… n] → [… xₙ]`], [Pop $n$ (4 bytes); move the element $n$ below the top to the top.],
    [`0x7b`], [`OP_ROT`], [A], [`[a b c] → [b c a]`], [Rotate three.],
    [`0x7c`], [`OP_SWAP`], [A], [`[a b] → [b a]`], [Swap.],
    [`0x7d`], [`OP_TUCK`], [A], [`[a b] → [b a b]`], [Copy the top below the second.],
    [`0x7e`], [`OP_CAT`], [A], [`[a b] → [a‖b]`], [Concatenate; result $≤ 2048$ bytes (`ErrElementTooBig`).],
    [`0x7f`], [`OP_SUBSTR`], [A], [`[s e b] → [s[b:e]]`], [Substring; start index on top; empty $s$ gives empty; otherwise $0 ≤ b ≤ e ≤ |s|$ (#xref("rule:script-substr")).],
    [`0x80`], [`OP_LEFT`], [A], [`[s n] → [s[0:n]]`], [Left part; $0 ≤ n ≤ |s|$ unless $s$ empty.],
    [`0x81`], [`OP_RIGHT`], [A], [`[s n] → [s[n:]]`], [Right part; $0 ≤ n ≤ |s|$ unless $s$ empty.],
    [`0x82`], [`OP_SIZE`], [A], [`[x] → [x n]`], [Push $|x|$; $x$ kept.],
    [`0x83`], [`OP_INVERT`], [A], [`[a] → [~a]`], [Bitwise NOT of `int32` $a$.],
    [`0x84`], [`OP_AND`], [A], [`[a b] → [a&b]`], [Bitwise AND of `int32` values.],
    [`0x85`], [`OP_OR`], [A], [`[a b] → [a|b]`], [Bitwise OR of `int32` values.],
    [`0x86`], [`OP_XOR`], [A], [`[a b] → [a^b]`], [Bitwise XOR of `int32` values.],
    [`0x87`], [`OP_EQUAL`], [A], [`[a b] → [bool]`], [Byte-string equality.],
    [`0x88`], [`OP_EQUALVERIFY`], [A], [`[a b] → []`], [`OP_EQUAL` then verify (`ErrEqualVerify`).],
    [`0x89`], [`OP_ROTR`], [A], [`[v c] → [r]`], [Rotate `uint32(v)` right by $c ∈ [0, 31]$, result as `int32`.],
    [`0x8a`], [`OP_ROTL`], [A], [`[v c] → [r]`], [Rotate `uint32(v)` left by $c ∈ [0, 31]$, result as `int32`.],
    [`0x8b`], [`OP_1ADD`], [A], [`[a] → [a+1]`], [Increment (exact).],
    [`0x8c`], [`OP_1SUB`], [A], [`[a] → [a-1]`], [Decrement (exact).],
    [`0x8d`], [`OP_2MUL`], [N], [`[] → []`], [No operation (not a multiplication); never discouraged.],
    [`0x8e`], [`OP_2DIV`], [N], [`[] → []`], [No operation (not a division); never discouraged.],
    [`0x8f`], [`OP_NEGATE`], [A], [`[a] → [-a]`], [Negate.],
    [`0x90`], [`OP_ABS`], [A], [`[a] → [|a|]`], [Absolute value.],
    [`0x91`], [`OP_NOT`], [A], [`[a] → [a=0]`], [1 if $a = 0$ else 0 (numeric operand).],
    [`0x92`], [`OP_0NOTEQUAL`], [A], [`[a] → [a≠0]`], [0 if $a = 0$ else 1.],
    [`0x93`], [`OP_ADD`], [A], [`[a b] → [a+b]`], [Add (exact).],
    [`0x94`], [`OP_SUB`], [A], [`[a b] → [a-b]`], [Subtract (exact).],
    [`0x95`], [`OP_MUL`], [A], [`[a b] → [a·b]`], [Multiply, wrapping to `int32`.],
    [`0x96`], [`OP_DIV`], [A], [`[a b] → [a/b]`], [Truncating division; $b = 0$ fails (`ErrDivideByZero`).],
    [`0x97`], [`OP_MOD`], [A], [`[a b] → [a%b]`], [Truncating remainder (sign of $a$); $b = 0$ fails.],
    [`0x98`], [`OP_LSHIFT`], [A], [`[v c] → [v<<c]`], [`int32` left shift, $c ∈ [0, 32]$; $c = 32$ gives 0.],
    [`0x99`], [`OP_RSHIFT`], [A], [`[v c] → [v>>c]`], [`int32` arithmetic right shift, $c ∈ [0, 32]$.],
    [`0x9a`], [`OP_BOOLAND`], [A], [`[a b] → [bool]`], [1 if $a ≠ 0$ and $b ≠ 0$.],
    [`0x9b`], [`OP_BOOLOR`], [A], [`[a b] → [bool]`], [1 if $a ≠ 0$ or $b ≠ 0$.],
    [`0x9c`], [`OP_NUMEQUAL`], [A], [`[a b] → [bool]`], [1 if $a = b$.],
    [`0x9d`], [`OP_NUMEQUALVERIFY`], [A], [`[a b] → []`], [`OP_NUMEQUAL` then verify (`ErrNumEqualVerify`).],
    [`0x9e`], [`OP_NUMNOTEQUAL`], [A], [`[a b] → [bool]`], [1 if $a ≠ b$.],
    [`0x9f`], [`OP_LESSTHAN`], [A], [`[a b] → [bool]`], [1 if $a < b$.],
    [`0xa0`], [`OP_GREATERTHAN`], [A], [`[a b] → [bool]`], [1 if $a > b$.],
    [`0xa1`], [`OP_LESSTHANOREQUAL`], [A], [`[a b] → [bool]`], [1 if $a ≤ b$.],
    [`0xa2`], [`OP_GREATERTHANOREQUAL`], [A], [`[a b] → [bool]`], [1 if $a ≥ b$.],
    [`0xa3`], [`OP_MIN`], [A], [`[a b] → [min]`], [Smaller of $a$, $b$.],
    [`0xa4`], [`OP_MAX`], [A], [`[a b] → [max]`], [Larger of $a$, $b$.],
    [`0xa5`], [`OP_WITHIN`], [A], [`[x lo hi] → [bool]`], [1 if $"lo" ≤ x < "hi"$.],
    [`0xa6`], [`OP_RIPEMD160`], [A], [`[x] → [h]`], [RIPEMD-160.],
    [`0xa7`], [`OP_SHA1`], [A], [`[x] → [h]`], [SHA-1.],
    [`0xa8`], [`OP_BLAKE256`], [A], [`[x] → [h]`], [BLAKE-256.],
    [`0xa9`], [`OP_HASH160`], [A], [`[x] → [h]`], [RIPEMD-160(BLAKE-256(x)).],
    [`0xaa`], [`OP_HASH256`], [A], [`[x] → [h]`], [BLAKE-256(BLAKE-256(x)).],
    [`0xab`], [`OP_CODESEPARATOR`], [D], [—], [Fails whenever reached, even unexecuted (`ErrDisabledOpcode`).],
    [`0xac`], [`OP_CHECKSIG`], [A], [`[sig pk] → [bool]`], [ECDSA signature check (#xref("rule:script-checksig")).],
    [`0xad`], [`OP_CHECKSIGVERIFY`], [A], [`[sig pk] → []`], [`OP_CHECKSIG` then verify (`ErrCheckSigVerify`).],
    [`0xae`], [`OP_CHECKMULTISIG`], [A], [`[sigs m pks n] → [bool]`], [$m$-of-$n$ ECDSA check, no dummy element; adds $n$ to the operation count (#xref("rule:script-checkmultisig")).],
    [`0xaf`], [`OP_CHECKMULTISIGVERIFY`], [A], [`[sigs m pks n] → []`], [`OP_CHECKMULTISIG` then verify.],
    [`0xb0`], [`OP_NOP1`], [U], [`[] → []`], [Upgradable no-operation.],
    [`0xb1`], [`OP_CHECKLOCKTIMEVERIFY`], [G], [`[L] → [L]`], [Lock-time check with flag `0x02` (#xref("rule:script-cltv")); else upgradable no-op (`OP_NOP2`).],
    [`0xb2`], [`OP_CHECKSEQUENCEVERIFY`], [G], [`[s] → [s]`], [Relative lock-time check with flag `0x04` (#xref("rule:script-csv")); else upgradable no-op (`OP_NOP3`).],
    [`0xb3`–`0xb9`], [`OP_NOP4` … `OP_NOP10`], [U], [`[] → []`], [Upgradable no-operations.],
    [`0xba`], [`OP_SSTX`], [N], [`[] → []`], [Stake tag; no operation. Recognized in P2SH detection; forbidden in redeem scripts.],
    [`0xbb`], [`OP_SSGEN`], [N], [`[] → []`], [Stake tag; no operation. Recognized in P2SH detection; forbidden in redeem scripts.],
    [`0xbc`], [`OP_SSRTX`], [N], [`[] → []`], [Stake tag; no operation. Recognized in P2SH detection; forbidden in redeem scripts.],
    [`0xbd`], [`OP_SSTXCHANGE`], [N], [`[] → []`], [Stake tag; no operation. Recognized in P2SH detection; forbidden in redeem scripts.],
    [`0xbe`], [`OP_CHECKSIGALT`], [A], [`[sig pk t] → [bool]`], [Alternative-suite check: $t$ = 1 Ed25519, 2 Schnorr; 0 pushes false, others push true (#xref("rule:script-checksigalt")).],
    [`0xbf`], [`OP_CHECKSIGALTVERIFY`], [A], [`[sig pk t] → []`], [`OP_CHECKSIGALT` then verify (`ErrCheckSigAltVerify`).],
    [`0xc0`], [`OP_SHA256`], [G], [`[x] → [h]`], [SHA-256 with flag `0x20`; else upgradable no-op (`OP_UNKNOWN192`).],
    [`0xc1`], [`OP_TADD`], [G], [`[] → []`], [Treasury tag with flag `0x40` (no operation); else upgradable no-op (`OP_UNKNOWN193`).],
    [`0xc2`], [`OP_TSPEND`], [G], [`[] → []`], [Treasury tag with flag `0x40`; else `OP_UNKNOWN194`. One signature operation when treasury rules apply.],
    [`0xc3`], [`OP_TGEN`], [G], [`[] → []`], [Treasury tag with flag `0x40`; else upgradable no-op (`OP_UNKNOWN195`).],
    [`0xc4`–`0xf8`], [`OP_UNKNOWN196` … `OP_UNKNOWN248`], [U], [`[] → []`], [Unassigned; upgradable no-operations.],
    [`0xf9`], [`OP_INVALID249`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0xfa`], [`OP_SMALLINTEGER`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0xfb`], [`OP_PUBKEYS`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0xfc`], [`OP_UNKNOWN252`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0xfd`], [`OP_PUBKEYHASH`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0xfe`], [`OP_PUBKEY`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
    [`0xff`], [`OP_INVALIDOPCODE`], [R], [—], [Fails if executed (`ErrReservedOpcode`).],
  ),
) <tab:opcodes-all>

== Remarks

- *Names and aliases.* `OP_FALSE` is `0x00`, `OP_TRUE` is `0x51`, `OP_NOP2`
  is `0xb1` and `OP_NOP3` is `0xb2`. When the corresponding flags are not set,
  `0xc0`–`0xc3` are called `OP_UNKNOWN192`–`OP_UNKNOWN195`. The names
  `OP_INVALID249`, `OP_SMALLINTEGER`, `OP_PUBKEYS`, `OP_UNKNOWN252`,
  `OP_PUBKEYHASH`, `OP_PUBKEY` and `OP_INVALIDOPCODE` (`0xf9`–`0xff`) are
  inherited labels with no function other than failing when executed.
- *Differences from Bitcoin.* `OP_CAT`, `OP_SUBSTR`, `OP_LEFT`, `OP_RIGHT`,
  `OP_INVERT`, `OP_AND`, `OP_OR`, `OP_XOR`, `OP_MUL`, `OP_DIV`, `OP_MOD`,
  `OP_LSHIFT` and `OP_RSHIFT` are enabled with the semantics of
  #xref("sec:script-opcodes")\; `OP_2MUL` and `OP_2DIV` are no-operations;
  `OP_CODESEPARATOR` is disabled; `0x89` and `0x8a` are the rotations
  `OP_ROTR` and `OP_ROTL`; `OP_HASH160` and `OP_HASH256` use BLAKE-256;
  `OP_CHECKMULTISIG` takes no dummy element; and `0xa8`, `0xba`–`0xc3` are
  Decred-specific. In particular `0xa8`, which is `OP_SHA256` in Bitcoin, is
  `OP_BLAKE256` here, and Decred's `OP_SHA256` is `0xc0`, available only
  when its flag is set. `OP_INVERT`, `OP_AND`, `OP_OR` and `OP_XOR` act on
  32-bit numbers, whereas Bitcoin's original versions acted on byte strings.
- *Parsing.* Every byte value parses as a one-byte opcode except
  `0x01`–`0x4e`, which carry inline data (#xref("rule:script-parse")). A
  script must parse completely before any of it executes, so the bytes after
  an `OP_RETURN` must still form valid opcodes.

