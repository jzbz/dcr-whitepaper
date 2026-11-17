#import "../template.typ": *

= The Script System <ch:script>

Every transaction output carries a short program, the _public key script_,
that states the conditions under which the output may be spent. Every
transaction input that spends an output carries a second program, the
_signature script_, that supplies the data needed to satisfy those conditions:
typically a signature and a public key. To decide whether an input may spend
an output, a node runs the two programs one after the other on a simple stack
machine. The input is valid only if the machine finishes without error and
leaves a value that counts as true.

This chapter specifies that machine as consensus requires it: the byte-level
encoding of scripts, every limit, the numeric and boolean conventions, the
semantics of all 256 opcode values, signature verification and the signature
hash, pay-to-script-hash, the stake and treasury tag opcodes, the verification
flags, signature-operation counting, and a few script predicates that other
consensus code relies on. Decred's script language descends from Bitcoin's,
but it differs in many details that are invisible in the common cases and
fatal in the uncommon ones. Nothing in this chapter should be assumed to match
Bitcoin unless the text says so. #chref("opcodes") lists all 256
opcode values in a single table.

Which transactions are checked, which inputs are skipped and which flags are
passed are decided by #chref("transactions")\; the per-block signature
operation limit is in #chref("blocks")\; the cryptographic primitives (hash
functions, DER parsing, ECDSA, EC-Schnorr-DCRv0, Ed25519) are in
#chref("crypto")\; the serialization of transactions is in #chref("encoding").

== Overview and Terminology <sec:script-overview>

A *script* is a byte string. It is read as a sequence of *opcodes*, each
introduced by a single byte. Some opcodes (the *push* opcodes) are followed by
inline data that they place on the stack; all other opcodes occupy exactly one
byte.

A transaction output holds an amount, a 16-bit *script version* and a public
key script. A transaction input holds, among other fields, a signature script.
When input $i$ of transaction $T$ spends output $o$, the script engine is
invoked with:

- the public key script of $o$ and its script version,
- the transaction $T$ and the input index $i$ (the signature script is
  $T$'s input $i$'s signature script),
- a set of *verification flags* (@sec:script-flags), chosen by the caller.

The engine maintains two stacks of byte strings. The *data stack* is the main
working stack; the *alternate stack* is auxiliary storage reachable only
through two opcodes. An entry on either stack is called an *element* or
*item*. The *top* of a stack is its most recently pushed element. In stack
diagrams, the stack is written left to right from bottom to top, so in
`[... x1 x2]` the element `x2` is on top.

The result of a script check is binary. If the check fails, the transaction
containing the input is invalid, and so is any block containing it. The
reference implementation reports a specific *error kind* for each failure
(for example `ErrEvalFalse`); these names are given in the text as an aid to
implementers and for cross-checking against dcrd's test data, but only the
binary outcome is consensus.

== Script Versions <sec:script-versions>

The script version of an output selects the language its public key script is
written in. Only version 0 is defined. The signature script and, for
pay-to-script-hash, the redeem script are interpreted under the version of the
public key script they redeem.

#rule("Non-zero script versions", src: ("txscript/engine.go · Execute", "txscript/engine.go · NewEngine"))[
  When the spent output's script version is not 0, the engine performs every
  check of @rule:script-construction (the engine construction checks), and if
  all of them pass, the input #MUST be treated as successfully verified
  without executing any script. Construction checks that depend on version 0
  semantics (the redeem-script checks of step 4) are skipped, but all others,
  including the requirement that both scripts parse under version 0 rules,
  apply regardless of the version.
] <rule:script-nonzero-version>

#pitfall[
  Outputs with a non-zero script version are therefore spendable by anyone who
  can supply a signature script that, together with the public key script,
  passes the construction checks: both scripts at most 16384 bytes, both
  parseable as version 0 scripts, not both empty, and, if the public key
  script has the byte pattern of a pay-to-script-hash script, a push-only
  signature script. Because the parse check uses version 0 rules, a public key
  script that does not parse as version 0 is unspendable at any version.
  Several other predicates used by consensus (pay-to-script-hash detection,
  signature operation counting, @rule:script-unspendable) also ignore the
  version entirely.
]

#history[
  Before the `explicitverupgrades` agenda (#dcp(8)), any 16-bit script
  version was permitted in any output. Once that agenda is active, outputs of
  regular (non-stake) transactions must carry script version 0, and stake
  transactions are constrained to specific versions by their own rules. Those
  limits are transaction-level rules specified in #chref("transactions") and
  #chref("staking")\; how agenda activation is computed is in
  #chref("voting"). Outputs created earlier with non-zero versions remain in
  the UTXO set and are governed by @rule:script-nonzero-version.
]

== Parsing <sec:script-parsing>

Parsing splits a script into opcodes and their inline data. It is defined for
version 0 and is used both by the engine and by every other predicate in this
chapter. Opcode bytes fall into four parsing classes, shown in
@tab:script-parse-classes.

#figure(
  caption: [Parsing classes of opcode bytes],
  table(
    columns: (auto, auto, 1fr),
    table.header([Byte(s)], [Opcode(s)], [Encoding]),
    [`0x00`], [`OP_0`], [The single byte. Pushes the empty byte string.],
    [`0x01`–`0x4b`], [`OP_DATA_1` … `OP_DATA_75`], [The byte $n$ followed by exactly $n$ data bytes.],
    [`0x4c`], [`OP_PUSHDATA1`], [The byte, a 1-byte length $n$, then $n$ data bytes.],
    [`0x4d`], [`OP_PUSHDATA2`], [The byte, a 2-byte little-endian length $n$, then $n$ data bytes.],
    [`0x4e`], [`OP_PUSHDATA4`], [The byte, a 4-byte little-endian length $n$, then $n$ data bytes.],
    [`0x4f`–`0xff`], [all others], [The single byte. No inline data.],
  ),
) <tab:script-parse-classes>

#rule("Script parsing", src: "txscript/tokenizer.go · ScriptTokenizer.Next")[
  A script is parsed from offset 0. At each offset $k$ the byte $b$ at $k$ is
  read and:
  + If $b$ is `0x00` or $b ≥$ `0x4f`, the opcode is $b$ with no data and the
    next offset is $k + 1$.
  + If `0x01` ≤ $b$ ≤ `0x4b`, the script #MUST contain at least $1 + b$ bytes
    from offset $k$; the data is the $b$ bytes after $b$ and the next offset
    is $k + 1 + b$.
  + If $b$ is `0x4c`, `0x4d` or `0x4e`, let $w$ be 1, 2 or 4 respectively.
    The script #MUST contain at least $w$ bytes after offset $k$. Let $n$ be
    those $w$ bytes read as an unsigned little-endian integer. The script
    #MUST contain at least $n$ further bytes after the length field. The data
    is those $n$ bytes and the next offset is $k + 1 + w + n$.

  Parsing ends successfully when the offset equals the script length. Any
  violation of a #MUST above is a *parse failure* (`ErrMalformedPush`). The
  empty script parses successfully to zero opcodes.
] <rule:script-parse>

#note[
  The reference implementation reads the `OP_PUSHDATA4` length into a signed
  32-bit integer and rejects negative values; since any length of $2^31$ or
  more also exceeds the bytes remaining in any script that fits in a
  transaction,
  the condition "at least $n$ further bytes" is equivalent.
]

Parsing does not inspect what an opcode does: unassigned, reserved and
disabled opcode bytes all parse as one-byte opcodes. In what follows, the
*data* of an opcode means its inline data (empty for `OP_0` and for every
opcode without inline data), and an opcode is a *data push* if its byte is at
most `0x4e`. This is narrower than the *push-only* test of
@sec:script-construction, which admits every opcode up to `0x60` and so
also the small-integer opcodes.

#algorithm("Script parsing", src: "txscript/tokenizer.go · ScriptTokenizer.Next")[
  ```python
  def parse(script: bytes) -> list[tuple[int, bytes]]:
      ops, k, L = [], 0, len(script)
      while k < L:
          b = script[k]
          if b == 0x00 or b >= 0x4f:
              ops.append((b, b"")); k += 1
          elif b <= 0x4b:                         # OP_DATA_1 .. OP_DATA_75
              if L - k < 1 + b: reject("ErrMalformedPush")
              ops.append((b, script[k+1 : k+1+b])); k += 1 + b
          else:                                   # OP_PUSHDATA1/2/4
              w = {0x4c: 1, 0x4d: 2, 0x4e: 4}[b]
              if L - k - 1 < w: reject("ErrMalformedPush")
              n = int.from_bytes(script[k+1 : k+1+w], "little")
              if n > L - k - 1 - w: reject("ErrMalformedPush")
              ops.append((b, script[k+1+w : k+1+w+n])); k += 1 + w + n
      return ops
  ```
] <alg:script-parse>

Several predicates walk a script only *up to* its first parse failure, using
the opcodes successfully parsed before it. Where that matters the text says
so explicitly.

== Limits <sec:script-limits>

@tab:script-limits collects the numeric limits of the engine. Each is
restated in the rule that enforces it, with the exact comparison.

#figure(
  caption: [Script engine limits],
  table(
    columns: (auto, auto, 1fr),
    table.header([Constant], [Value], [Meaning and exact comparison]),
    [#const("MaxScriptSize")], [16384], [A signature script or public key script longer than this many bytes fails (`len > 16384`). Redeem scripts are bounded by the element size instead.],
    [#const("MaxScriptElementSize")], [2048], [A data push whose data is longer than this many bytes fails (`len > 2048`), whether or not the push is executed. `OP_CAT` enforces the same bound on its result.],
    [#const("MaxOpsPerScript")], [255], [Per script, the count of opcodes with byte value greater than `0x60`, plus the key counts of executed multisignature checks, must not exceed 255 (fails when the count becomes `> 255`).],
    [#const("MaxStackSize")], [1024], [After each opcode, the combined number of elements on the data stack and alternate stack must not exceed 1024 (fails when `> 1024`).],
    [#const("MaxPubKeysPerMultiSig")], [20], [The key count of `OP_CHECKMULTISIG(VERIFY)` must be in $[0, 20]$.],
    [#const("MathOpCodeMaxScriptNumLen")], [4], [Maximum encoded length of most numeric operands (@sec:script-numbers).],
    [#const("CltvMaxScriptNumLen")], [5], [Maximum encoded length of the `OP_CHECKLOCKTIMEVERIFY` operand.],
    [#const("CsvMaxScriptNumLen")], [5], [Maximum encoded length of the `OP_CHECKSEQUENCEVERIFY` operand.],
    [—], [1], [Maximum encoded length of the `OP_CHECKSIGALT(VERIFY)` signature type operand.],
    [#const("LockTimeThreshold")], [500000000], [Lock-time values below this are block heights, at or above it Unix times.],
  ),
) <tab:script-limits>

== Engine Construction <sec:script-construction>

Before anything executes, the engine checks the pair of scripts as a whole.
These checks are part of consensus: a failure makes the input invalid exactly
as an execution failure does (dcrd reports it as `ErrScriptMalformed` at the
transaction level, but the distinction has no consensus effect).

Two script shapes are recognized by exact byte pattern. A *pay-to-script-hash*
(P2SH) public key script is exactly 23 bytes:
`a9 14` followed by 20 bytes followed by `87`, that is,
`OP_HASH160 OP_DATA_20 <20 bytes> OP_EQUAL`. A *stake-tagged P2SH* public key
script is exactly 24 bytes: a *stake tag* byte followed by those 23 bytes. The
stake tag bytes are `0xba`–`0xbd` (`OP_SSTX`, `OP_SSGEN`, `OP_SSRTX`,
`OP_SSTXCHANGE`) and, only when the `ScriptVerifyTreasury` flag is set, also
`0xc1`–`0xc3` (`OP_TADD`, `OP_TSPEND`, `OP_TGEN`). A script is
*P2SH-shaped* if it is either. P2SH is specified in @sec:script-p2sh.

A script is *push-only* if it parses (@rule:script-parse) and every opcode in
it has byte value at most `0x60` (`OP_16`). Note that this includes
`OP_RESERVED` (`0x50`), which fails if executed.

#rule("Engine construction checks", src: ("txscript/engine.go · NewEngine", "txscript/script.go · hasP2SHRedeemScriptStakeOpCodes"))[
  Let $S$ be the signature script, $P$ the public key script and $v$ the
  script version of the spent output. The following #MUST all hold:
  + $S$ and $P$ are not both empty (`ErrEvalFalse`).
  + If the flag `ScriptVerifySigPushOnly` is set, $S$ is push-only
    (`ErrNotPushOnly`).
  + If $P$ is P2SH-shaped, $S$ is push-only (`ErrNotPushOnly`). This check is
    independent of $v$.
  + If $v = 0$ and $P$ is P2SH-shaped: let $R$ be the data of the final
    opcode of $S$, taken from a full parse of $S$ (if $S$ is empty or fails
    to parse, $R$ is empty). $R$ #MUST be non-empty (`ErrNotPushOnly`). $R$
    #MUSTNOT contain a stake tag opcode, where the opcodes considered are
    `0xba`–`0xbd`, plus `0xc1`–`0xc3` when `ScriptVerifyTreasury` is set
    (`ErrP2SHStakeOpCodes`); this scan stops at the first parse failure of
    $R$, and a parse failure reached before any stake tag opcode also fails
    (`ErrMalformedPush`).
  + $|S| ≤ 16384$ and $|P| ≤ 16384$ (`ErrScriptTooBig`).
  + $S$ and $P$ both parse under version 0 rules (`ErrMalformedPush`),
    whatever $v$ is.
] <rule:script-construction>

#pitfall[
  In step 4 the redeem script is the _inline data_ of the last opcode of the
  signature script, not the top stack element the signature script will
  produce. The small-integer opcodes `OP_1`–`OP_16` and `OP_1NEGATE` have no
  inline data, so a P2SH signature script that ends with one of them fails
  construction even though executing it would leave a non-empty element on
  the stack. The same applies to `OP_0` and to an empty push such as
  `OP_PUSHDATA1 0x00`. A redeem script consisting of the single byte `0x51`
  must therefore be supplied as `01 51` (an `OP_DATA_1` push), never as `51`.
]

== Execution Model <sec:script-execution>

=== Order of Execution <sec:script-order>

The engine executes up to three scripts in sequence on a shared data stack:

+ the signature script $S$, starting from an empty data stack;
+ the public key script $P$, starting from the data stack $S$ left behind;
+ for P2SH only, the *redeem script* $R$: the top element of the data stack
  as it was after $S$ finished, executed on that stack with $R$ itself removed
  (@sec:script-p2sh).

#figure(
  caption: [Order of script execution. The data stack is carried from one
    script to the next; the alternate stack, the operation count and the
    conditional state belong to a single script.],
  block(width: 15.6cm, height: 3.5cm, {
    dg-box(0, 0.2, 4.5, 1.5)[*Signature script $S$* \ starts with an empty data stack]
    dg-box(5.55, 0.2, 4.5, 1.5)[*Public key script $P$* \ starts with the data stack $S$ left behind]
    dg-box(11.1, 0.2, 4.5, 1.5, fill: palette.wash-teal, stroke: palette.teal)[*Redeem script $R$* (P2SH only) \ the top element after $S$; runs on that stack with $R$ removed]
    dg-arrow(4.5, 0.95, 5.55, 0.95)
    dg-arrow(10.05, 0.95, 11.1, 0.95, colour: palette.teal)
    dg-seg(0, 2.15, 15.6, 2.15, stroke: 0.6pt + palette.muted)
    dg-seg(0, 2.0, 0, 2.15, stroke: 0.6pt + palette.muted)
    dg-seg(4.5, 2.0, 4.5, 2.15, stroke: 0.6pt + palette.muted)
    dg-seg(5.55, 2.0, 5.55, 2.15, stroke: 0.6pt + palette.muted)
    dg-seg(10.05, 2.0, 10.05, 2.15, stroke: 0.6pt + palette.muted)
    dg-seg(11.1, 2.0, 11.1, 2.15, stroke: 0.6pt + palette.muted)
    dg-seg(15.6, 2.0, 15.6, 2.15, stroke: 0.6pt + palette.muted)
    dg-text(0, 2.35, 15.6, colour: palette.muted)[After each non-empty script: the alternate stack is emptied, the operation count is reset to zero, and no conditional may remain open.]
  }),
) <fig:script-order>

An empty script is skipped entirely: it executes no opcodes and none of the
per-script end checks below apply to it. The alternate stack, the operation
count and the conditional state are per script: the alternate stack is emptied
and the operation count reset to zero at the end of each non-empty script.

#rule("Per-script end conditions", src: "txscript/engine.go · Engine.Step")[
  When the last opcode of a non-empty script has executed:
  + the conditional nesting depth (@sec:script-conditionals) #MUST be 0
    (`ErrUnbalancedConditional`): an `OP_IF` or `OP_NOTIF` block cannot span
    two scripts;
  + the alternate stack is then emptied, and the operation count reset to 0,
    before the next script starts.
] <rule:script-end-of-script>

#rule("Combined stack size", src: "txscript/engine.go · Engine.Step")[
  After every opcode the engine processes, including opcodes in unexecuted
  branches, the number of elements on the data stack plus the number on the
  alternate stack #MUSTNOT exceed 1024 (`ErrStackOverflow`).
] <rule:script-stack-size>

=== Processing One Opcode <sec:script-opcode-processing>

The engine walks each script opcode by opcode in parse order. Every opcode
the program counter reaches is *processed*, whether or not it lies in a branch
that is being executed; processing decides whether the opcode's operation is
actually *executed*. A branch is *executing* when no enclosing `OP_IF`,
`OP_NOTIF` or `OP_ELSE` has disabled it (@sec:script-conditionals).

#rule("Opcode processing", src: ("txscript/engine.go · executeOpcode", "txscript/engine.go · isOpcodeDisabled", "txscript/engine.go · isOpcodeAlwaysIllegal"))[
  For each opcode $o$ with data $d$ reached by the program counter, in this
  order:
  + If $o$ is `OP_CODESEPARATOR` (`0xab`), the script #MUST fail
    (`ErrDisabledOpcode`), whether or not the branch is executing.
  + If $o$ is `OP_VERIF` (`0x65`) or `OP_VERNOTIF` (`0x66`), the script
    #MUST fail (`ErrReservedOpcode`), whether or not the branch is executing.
  + If $o > $ `0x60`, the per-script operation count is incremented by one,
    and if it now exceeds 255 the script #MUST fail
    (`ErrTooManyOperations`). Otherwise ($o ≤ $ `0x60`), if $|d| > 2048$ the
    script #MUST fail (`ErrElementTooBig`). Both checks apply whether or not
    the branch is executing.
  + If the branch is not executing and $o$ is not one of `OP_IF`,
    `OP_NOTIF`, `OP_ELSE`, `OP_ENDIF`, processing of $o$ ends here: it has
    no further effect.
  + If the branch is executing and $o ≤ $ `0x4e`, the push #MUST be minimal
    (@rule:script-minimal-push).
  + The operation of $o$ is executed, as specified in @sec:script-opcodes
    and #chref("opcodes"). The conditional opcodes are executed in
    unexecuted branches as well, with the behaviour given in
    @sec:script-conditionals.
] <rule:script-opcode-processing>

#pitfall[
  The operation count includes every opcode above `0x60` that the program
  counter passes over, including those in unexecuted branches, and excludes
  every opcode at or below `0x60`, including `OP_RESERVED` (`0x50`). The
  element size limit likewise applies to pushes in unexecuted branches. By
  contrast, the minimal-push rule applies only to executed pushes.
]

#rule("Minimal data pushes", src: "txscript/engine.go · checkMinimalDataPush")[
  An executed data push with opcode $o$ (`0x00`–`0x4e`) and data $d$ #MUST
  satisfy the first matching condition (`ErrMinimalData`):
  + if $|d| = 0$: $o$ is `OP_0`;
  + if $|d| = 1$ and $1 ≤ d[0] ≤ 16$: $o$ is `OP_1` + $d[0] - 1$ (that is,
    a small-integer opcode, which is not a data push and so never reaches
    this check);
  + if $|d| = 1$ and $d[0] =$ `0x81`: $o$ is `OP_1NEGATE` (likewise
    impossible to satisfy with a data push);
  + if $|d| ≤ 75$: $o = |d|$ (an `OP_DATA_n` opcode);
  + if $|d| ≤ 255$: $o$ is `OP_PUSHDATA1`;
  + if $|d| ≤ 65535$: $o$ is `OP_PUSHDATA2`.
] <rule:script-minimal-push>

In effect, every executed push must use the shortest encoding: the empty
string only via `OP_0`; the single bytes `0x01`–`0x10` and `0x81` only via
`OP_1`–`OP_16` and `OP_1NEGATE`; other strings of 1 to 75 bytes only via
`OP_DATA_n`; 76 to 255 bytes only via `OP_PUSHDATA1`; 256 to 2048 bytes only
via `OP_PUSHDATA2`. An executed `OP_PUSHDATA4` always fails, because a push of
at most 65535 bytes requires a shorter opcode and a longer one cannot fit in a
script. The single bytes `0x00` and `0x80` may be pushed with `OP_DATA_1`.

=== Conditional Execution <sec:script-conditionals>

Branching uses two per-script integers: the *nesting depth* $D$, the number
of currently open `OP_IF`/`OP_NOTIF` blocks, and the *disable depth* $X$,
which is either "none" (the branch is executing) or the nesting depth at
which execution was disabled. Both start at $D = 0$, $X = "none"$. Since
$D$ must return to 0 at the end of every script, both are effectively reset
between scripts.

#rule("Conditional opcodes", src: ("txscript/opcode.go · opcodeIf", "txscript/opcode.go · opcodeNotIf", "txscript/opcode.go · opcodeElse", "txscript/opcode.go · opcodeEndif"))[
  - `OP_IF`: if $X$ is none, pop the top data stack element (an empty stack
    fails with `ErrInvalidStackOperation`) and interpret it as a boolean
    (@rule:script-bool); if it is false, set $X := D$. In all cases then set
    $D := D + 1$.
  - `OP_NOTIF`: as `OP_IF`, except that $X := D$ is set when the popped
    value is true.
  - `OP_ELSE`: if $D = 0$ the script #MUST fail
    (`ErrUnbalancedConditional`). Otherwise let $d = D - 1$. If $X$ is none,
    set $X := d$; else if $X = d$, set $X := "none"$; otherwise do nothing.
  - `OP_ENDIF`: if $D = 0$ the script #MUST fail
    (`ErrUnbalancedConditional`). Otherwise set $D := D - 1$, and then if
    $X = D$ set $X := "none"$.
] <rule:script-conditionals>

Consequences worth stating explicitly: an `OP_IF` reached in an unexecuted
branch consumes nothing from the stack but still opens a block; any number of
`OP_ELSE` opcodes may appear in one block, each toggling execution; and the
condition value is interpreted as a boolean, with no requirement that it be
minimally encoded (Decred has no "minimal if" rule).

=== Successful Completion <sec:script-completion>

#rule("Final result", src: ("txscript/engine.go · CheckErrorCondition", "txscript/engine.go · Engine.Execute"))[
  After the last script has finished:
  + if the flag `ScriptVerifyCleanStack` is set, the data stack #MUST contain
    exactly one element (`ErrCleanStack`);
  + otherwise the data stack #MUST contain at least one element
    (`ErrEmptyStack`);
  + the top element, interpreted as a boolean, #MUST be true
    (`ErrEvalFalse`).
] <rule:script-final>

The clean-stack flag is part of the consensus flag set on every block
(@sec:script-flags), so in consensus validation the data stack must end with
exactly one element, which must be true. Contents of the alternate stack at
the end are irrelevant (the alternate stack has been emptied by
@rule:script-end-of-script).

For P2SH, an intermediate check precedes the redeem script; it is given in
@rule:script-p2sh-eval.

=== Complete Input Verification <sec:script-verify-alg>

@alg:script-verify combines the rules of this section into a single
procedure. The handlers for individual opcodes are specified in
@sec:script-opcodes and @sec:script-signatures.

#algorithm("Verifying one input", src: ("txscript/engine.go · NewEngine", "txscript/engine.go · Engine.Step", "txscript/engine.go · Engine.Execute"))[
  ```python
  MAX_SCRIPT_SIZE, MAX_ELEMENT, MAX_OPS, MAX_STACK = 16384, 2048, 255, 1024

  def verify_input(tx, idx, pk_script, version, flags):
      S, P = tx.inputs[idx].sig_script, pk_script
      treasury = TREASURY in flags
      if len(S) == 0 and len(P) == 0: reject("ErrEvalFalse")
      if SIGPUSHONLY in flags and not is_push_only(S): reject("ErrNotPushOnly")
      p2sh = is_p2sh(P) or is_stake_p2sh(P, treasury)
      if p2sh and not is_push_only(S): reject("ErrNotPushOnly")
      if version == 0 and p2sh:
          R = final_opcode_data(S)            # b"" if S is empty or unparseable
          if len(R) == 0: reject("ErrNotPushOnly")
          # contains_stake_opcode tokenizes R and rejects with ErrMalformedPush
          # if R does not parse, unless a stake opcode is found first
          if contains_stake_opcode(R, treasury): reject("ErrP2SHStakeOpCodes")
      for s in (S, P):
          if len(s) > MAX_SCRIPT_SIZE: reject("ErrScriptTooBig")
          parse(s)                            # version 0 rules, may reject
      if version != 0:
          return                              # valid (rule: non-zero versions)
      vm = VM(tx, idx, flags)                 # empty data and alternate stacks
      run_script(vm, S)
      saved = list(vm.dstack)                 # used only for P2SH
      run_script(vm, P)
      if p2sh:
          if len(vm.dstack) < 1: reject("ErrEmptyStack")
          if not as_bool(vm.dstack.pop()): reject("ErrEvalFalse")
          R = saved[-1]
          parse(R)                            # redundant for version 0: checked above
          vm.dstack = saved[:-1]
          run_script(vm, R)
      if CLEANSTACK in flags and len(vm.dstack) != 1: reject("ErrCleanStack")
      if len(vm.dstack) < 1: reject("ErrEmptyStack")
      if not as_bool(vm.dstack.pop()): reject("ErrEvalFalse")

  def run_script(vm, script):
      if len(script) == 0:
          return
      vm.script = script                      # the "current script"
      vm.num_ops, vm.depth, vm.disabled_at = 0, 0, None
      for op, data in parse(script):
          process_opcode(vm, op, data)
          if len(vm.dstack) + len(vm.astack) > MAX_STACK:
              reject("ErrStackOverflow")
      if vm.depth != 0: reject("ErrUnbalancedConditional")
      vm.astack = []

  def process_opcode(vm, op, data):
      if op == 0xab: reject("ErrDisabledOpcode")          # OP_CODESEPARATOR
      if op in (0x65, 0x66): reject("ErrReservedOpcode")  # OP_VERIF, OP_VERNOTIF
      if op > 0x60:
          vm.num_ops += 1
          if vm.num_ops > MAX_OPS: reject("ErrTooManyOperations")
      elif len(data) > MAX_ELEMENT:
          reject("ErrElementTooBig")
      executing = vm.disabled_at is None
      if not executing and op not in (OP_IF, OP_NOTIF, OP_ELSE, OP_ENDIF):
          return
      if executing and op <= 0x4e:
          check_minimal_push(op, data)
      HANDLERS[op](vm, data)
  ```
] <alg:script-verify>

#note[
  For a version 0 P2SH spend, `saved[-1]` and `final_opcode_data(S)` are
  always the same byte string: $S$ is push-only, construction has ensured its
  last opcode is a non-empty data push, and that push is the top of the stack
  $S$ produces.
]

=== Example: Pay-to-Pubkey-Hash <sec:script-example>

The most common public key script is pay-to-pubkey-hash:

#align(center)[`OP_DUP OP_HASH160 <20-byte hash> OP_EQUALVERIFY OP_CHECKSIG`]

It is redeemed by a signature script `<signature> <public key>`. @tab:script-p2pkh-trace shows
the data stack after each opcode.

#figure(
  caption: [Execution of a pay-to-pubkey-hash spend],
  table(
    columns: (auto, auto, 1fr),
    table.header([Script], [Opcode], [Data stack afterwards (bottom … top)]),
    [S], [`OP_DATA_72`], [`sig`],
    [S], [`OP_DATA_33`], [`sig pk`],
    [P], [`OP_DUP`], [`sig pk pk`],
    [P], [`OP_HASH160`], [`sig pk H(pk)` where `H` = RIPEMD-160(BLAKE-256(·))],
    [P], [`OP_DATA_20`], [`sig pk H(pk) h`],
    [P], [`OP_EQUALVERIFY`], [`sig pk` (fails unless `H(pk) = h`)],
    [P], [`OP_CHECKSIG`], [`1` if the signature verifies, else the empty string],
    [—], [final check], [exactly one element, true: valid],
  ),
) <tab:script-p2pkh-trace>

== Data Representation <sec:script-data>

Stack elements are untyped byte strings. Opcodes interpret them as raw
bytes, as booleans or as numbers, and the interpretation is fixed per opcode.

=== Booleans <sec:script-booleans>

#rule("Boolean interpretation", src: "txscript/stack.go · asBool")[
  A byte string $x$ is *false* if every byte of $x$ is `0x00`, or if every
  byte except the last is `0x00` and the last byte is `0x80` ("negative
  zero"). In particular the empty string is false. Every other byte string is
  *true*. There is no length limit on a value interpreted as a boolean.

  An opcode that *pushes a boolean* pushes the one-byte string `01` for true
  and the empty string for false.
] <rule:script-bool>

Booleans are consumed by `OP_IF`, `OP_NOTIF`, `OP_VERIFY`, `OP_IFDUP`, the
`…VERIFY` forms of other opcodes, and the final check. `OP_NOT`, `OP_BOOLAND`
and `OP_BOOLOR` are *numeric* opcodes and do not use this interpretation.

=== Script Numbers <sec:script-numbers>

Numbers on the stack are encoded as little-endian sign-magnitude byte
strings: the magnitude is written in the fewest bytes possible, least
significant byte first, and the most significant bit of the last byte is the
sign. If the magnitude's most significant byte already has its top bit set, an
extra byte `0x00` (positive) or `0x80` (negative) is appended. Zero is the
empty string.

#algorithm("Script number encoding and decoding", src: ("txscript/scriptnum.go · ScriptNum.Bytes", "txscript/scriptnum.go · MakeScriptNum", "txscript/scriptnum.go · checkMinimalDataEncoding"))[
  ```python
  def encode_num(n: int64) -> bytes:
      if n == 0:
          return b""
      neg, m = n < 0, abs(n)
      out = bytearray()
      while m > 0:
          out.append(m & 0xff); m >>= 8
      if out[-1] & 0x80:
          out.append(0x80 if neg else 0x00)
      elif neg:
          out[-1] |= 0x80
      return bytes(out)

  def decode_num(b: bytes, max_len: int) -> int:
      if len(b) > max_len:
          reject("ErrNumOutOfRange")
      if len(b) > 0 and (b[-1] & 0x7f) == 0:          # minimal encoding
          if len(b) == 1 or (b[-2] & 0x80) == 0:
              reject("ErrMinimalData")
      if len(b) == 0:
          return 0
      mag = int.from_bytes(b, "little")
      if b[-1] & 0x80:
          return -(mag & ~(0x80 << (8 * (len(b) - 1))))
      return mag
  ```
] <alg:script-num>

#rule("Numeric operands", src: ("txscript/scriptnum.go · MakeScriptNum", "txscript/stack.go · stack.PopInt"))[
  Whenever an opcode interprets a stack element as a number, the element
  #MUST decode under `decode_num` of @alg:script-num with the maximum length
  for that opcode: its length #MUSTNOT exceed the maximum
  (`ErrNumOutOfRange`) and it #MUST be minimally encoded (`ErrMinimalData`).
  The length check precedes the minimality check. The maximum length is 5 for
  the operand of `OP_CHECKLOCKTIMEVERIFY` and `OP_CHECKSEQUENCEVERIFY`, 1 for
  the signature-type operand of `OP_CHECKSIGALT(VERIFY)`, and 4 for every
  other numeric operand.
] <rule:script-numeric-operands>

A maximum length of 4 bytes admits exactly the integers
$[-(2^31 - 1), 2^31 - 1]$; 5 bytes admits $[-(2^39 - 1), 2^39 - 1]$; 1 byte
admits $[-127, 127]$. Note that $-2^31$ is *not* a valid 4-byte operand: its
encoding `00 00 00 80 80` is 5 bytes long.

The minimality requirement applies only when a value is interpreted as a
number. Pushing the two-byte string `05 00` (with `OP_DATA_2`, which is the
minimal *push* for it) is permitted even though it is a non-minimal encoding
of the number 5; the element may be compared with `OP_EQUAL`, hashed or used
as a boolean, and fails only if a numeric opcode consumes it.

Results of numeric opcodes are always pushed with `encode_num`, which never
produces a non-minimal encoding. Results are not range-checked: an addition of
two 4-byte operands may produce a 5-byte result such as $2^32 - 2$, which can
be pushed, compared bytewise, hashed or interpreted as a boolean, but fails if
it is later used as a 4-byte numeric operand.

#note[
  The reference implementation converts decoded operands to 32-bit integers
  with a saturating conversion (values above $2^31 - 1$ become $2^31 - 1$,
  values below $-2^31$ become $-2^31$) wherever an operand is used as a
  32-bit quantity. Because every operand so converted has already passed a
  4-byte length check, it always lies in $[-(2^31 - 1), 2^31 - 1]$ and the
  saturation never changes a value. An implementation may use a plain
  conversion.
]

== Opcode Semantics <sec:script-opcodes>

This section specifies the operation performed when an opcode is *executed*
(step 6 of @rule:script-opcode-processing). All opcodes are listed by byte
value in #chref("opcodes"). Unless stated otherwise:

- "pop" removes the top element of the data stack, and popping from an empty
  stack fails (`ErrInvalidStackOperation`); likewise any reference to an
  element deeper than the stack fails with that error;
- a numeric operand is popped and decoded under
  @rule:script-numeric-operands with maximum length 4;
- operands are popped top first: in `[... x1 x2]`, `x2` is popped first;
- results are pushed after all operands have been popped.

Because any failure invalidates the input, the order in which an opcode checks
its operands only affects which error is reported; it is stated where an
opcode can either fail or push a result depending on that order.

=== Push Opcodes <sec:script-op-push>

#figure(
  caption: [Push opcodes],
  table(
    columns: (auto, auto, 1fr),
    table.header([Byte(s)], [Opcode], [Operation]),
    [`0x00`], [`OP_0`, `OP_FALSE`], [Push the empty string.],
    [`0x01`–`0x4b`], [`OP_DATA_n`], [Push the $n$ inline data bytes.],
    [`0x4c`–`0x4e`], [`OP_PUSHDATA1/2/4`], [Push the inline data bytes.],
    [`0x4f`], [`OP_1NEGATE`], [Push the number $-1$ (`81`).],
    [`0x51`–`0x60`], [`OP_1`/`OP_TRUE` … `OP_16`], [Push the number $b - $ `0x50` (`01` … `10`).],
  ),
) <tab:script-push-ops>

=== Flow Control <sec:script-op-flow>

#figure(
  caption: [Flow-control opcodes],
  table(
    columns: (auto, auto, 1fr),
    table.header([Byte], [Opcode], [Operation when executed]),
    [`0x61`], [`OP_NOP`], [None.],
    [`0x62`], [`OP_VER`], [Fail (`ErrReservedOpcode`). Ignored in an unexecuted branch.],
    [`0x63`], [`OP_IF`], [@rule:script-conditionals.],
    [`0x64`], [`OP_NOTIF`], [@rule:script-conditionals.],
    [`0x65`], [`OP_VERIF`], [Fail whenever reached, even in an unexecuted branch (@rule:script-opcode-processing).],
    [`0x66`], [`OP_VERNOTIF`], [Fail whenever reached, even in an unexecuted branch.],
    [`0x67`], [`OP_ELSE`], [@rule:script-conditionals.],
    [`0x68`], [`OP_ENDIF`], [@rule:script-conditionals.],
    [`0x69`], [`OP_VERIFY`], [Pop $x$; if $x$ is false, fail (`ErrVerify`).],
    [`0x6a`], [`OP_RETURN`], [Fail (`ErrEarlyReturn`). Ignored in an unexecuted branch.],
  ),
) <tab:script-flow-ops>

Every opcode named `…VERIFY` other than `OP_VERIFY`, `OP_CHECKLOCKTIMEVERIFY`
and `OP_CHECKSEQUENCEVERIFY` behaves as its base opcode followed by
`OP_VERIFY`, except that the error on a false result has its own kind
(`ErrEqualVerify`, `ErrNumEqualVerify`, `ErrCheckSigVerify`,
`ErrCheckMultiSigVerify`, `ErrCheckSigAltVerify`). A `…VERIFY` opcode counts
as a single operation.

=== Stack Manipulation <sec:script-op-stack>

In @tab:script-stack-ops, a failure because the stack holds too few elements
is always `ErrInvalidStackOperation`.

#figure(
  caption: [Stack-manipulation opcodes],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Byte], [Opcode], [Data stack effect], [Notes]),
    [`0x6b`], [`OP_TOALTSTACK`], [`[x] → []`], [`x` is pushed onto the alternate stack.],
    [`0x6c`], [`OP_FROMALTSTACK`], [`[] → [x]`], [`x` is popped from the alternate stack; fails if it is empty.],
    [`0x6d`], [`OP_2DROP`], [`[x1 x2] → []`], [],
    [`0x6e`], [`OP_2DUP`], [`[x1 x2] → [x1 x2 x1 x2]`], [],
    [`0x6f`], [`OP_3DUP`], [`[x1 x2 x3] → [x1 x2 x3 x1 x2 x3]`], [],
    [`0x70`], [`OP_2OVER`], [`[x1 x2 x3 x4] → [x1 x2 x3 x4 x1 x2]`], [],
    [`0x71`], [`OP_2ROT`], [`[x1 … x6] → [x3 x4 x5 x6 x1 x2]`], [Requires 6 elements.],
    [`0x72`], [`OP_2SWAP`], [`[x1 x2 x3 x4] → [x3 x4 x1 x2]`], [],
    [`0x73`], [`OP_IFDUP`], [`[x] → [x x]` or `[x]`], [Duplicates `x` only if `x` is true as a boolean.],
    [`0x74`], [`OP_DEPTH`], [`[] → [n]`], [`n` is the number of data stack elements before the push.],
    [`0x75`], [`OP_DROP`], [`[x] → []`], [],
    [`0x76`], [`OP_DUP`], [`[x] → [x x]`], [],
    [`0x77`], [`OP_NIP`], [`[x1 x2] → [x2]`], [],
    [`0x78`], [`OP_OVER`], [`[x1 x2] → [x1 x2 x1]`], [],
    [`0x79`], [`OP_PICK`], [`[xn … x0 n] → [xn … x0 xn]`], [See below.],
    [`0x7a`], [`OP_ROLL`], [`[xn … x0 n] → [… x0 xn]`], [See below.],
    [`0x7b`], [`OP_ROT`], [`[x1 x2 x3] → [x2 x3 x1]`], [],
    [`0x7c`], [`OP_SWAP`], [`[x1 x2] → [x2 x1]`], [],
    [`0x7d`], [`OP_TUCK`], [`[x1 x2] → [x2 x1 x2]`], [],
  ),
) <tab:script-stack-ops>

#rule("OP_PICK and OP_ROLL", src: ("txscript/opcode.go · opcodePick", "txscript/opcode.go · opcodeRoll", "txscript/stack.go · stack.PickN", "txscript/stack.go · stack.RollN"))[
  Pop a numeric operand $n$ (4-byte maximum). Then, on the remaining stack of
  depth $k$, $n$ #MUST satisfy $0 ≤ n < k$ (`ErrInvalidStackOperation`). The
  element at distance $n$ from the top (distance 0 is the top) is copied to
  the top (`OP_PICK`) or moved to the top, closing the gap (`OP_ROLL`).
  `OP_ROLL` with $n = 0$ leaves the stack unchanged.
] <rule:script-pick-roll>

=== Splice Operations <sec:script-op-splice>

Decred enables the string opcodes that Bitcoin disabled, with its own
semantics.

#rule("OP_CAT", src: "txscript/opcode.go · opcodeCat")[
  `[... x1 x2] → [... x1 || x2]`. Pop `x2`, then `x1`. If both are empty,
  push the empty string. If exactly one is empty, push the other unchanged.
  Otherwise $|x_1| + |x_2|$ #MUSTNOT exceed 2048 (`ErrElementTooBig`), and
  the concatenation `x1 || x2` is pushed.
] <rule:script-cat>

#rule("OP_SUBSTR", src: "txscript/opcode.go · opcodeSubstr")[
  `[... s e b] → [... s[b:e]]`. Pop the numeric *start index* $b$ (the top
  element), then the numeric *end index* $e$, then the string $s$ (all
  numeric operands 4-byte maximum). If $|s| = 0$, push the empty string
  regardless of $b$ and $e$. Otherwise, in this order, #MUST hold: $b ≥ 0$
  and $e ≥ 0$ (`ErrNegativeSubstrIdx`); $b ≤ |s|$, $e ≤ |s|$ and $b ≤ e$
  (`ErrOverflowSubstrIdx`). Push the bytes of $s$ from index $b$ up to but
  not including $e$ (empty when $b = e$).
] <rule:script-substr>

#rule("OP_LEFT and OP_RIGHT", src: ("txscript/opcode.go · opcodeLeft", "txscript/opcode.go · opcodeRight"))[
  `[... s n]`. Pop the numeric index $n$, then the string $s$. If $|s| = 0$,
  push the empty string regardless of $n$. Otherwise #MUST hold: $n ≥ 0$
  (`ErrNegativeSubstrIdx`) and $n ≤ |s|$ (`ErrOverflowSubstrIdx`).
  `OP_LEFT` pushes the first $n$ bytes `s[0:n]`; `OP_RIGHT` pushes the bytes
  from index $n$ to the end, `s[n:]`.
] <rule:script-left-right>

`OP_SIZE` (`0x82`): `[... x] → [... x n]`, where `n` is $|x|$ encoded as a
number; `x` is not removed.

#pitfall[
  The operand order of `OP_SUBSTR` is the reverse of what its name suggests:
  the start index is on top, the end index beneath it. `'abcd' 3 1 OP_SUBSTR`
  yields `'bc'`. The "empty string" shortcuts are taken after the indices have
  been decoded (so an over-long index still fails with `ErrNumOutOfRange`) but
  before any bounds check, so `'' 2147483647 2147483646 OP_SUBSTR` succeeds
  and pushes the empty string.
]

=== Bitwise Logic, Comparison and Rotation <sec:script-op-bitwise>

The bitwise opcodes operate on numbers, not on byte strings. Each operand is
decoded as a 4-byte script number and then treated as a 32-bit two's
complement integer; the 32-bit result is interpreted as a signed integer and
pushed with `encode_num`.

#figure(
  caption: [Bitwise and byte-comparison opcodes],
  table(
    columns: (auto, auto, 1fr),
    table.header([Byte], [Opcode], [Operation (`[... x1 x2]`, `x2` on top)]),
    [`0x83`], [`OP_INVERT`], [`[x] → [~x]`: bitwise complement as `int32`, equal to $-x - 1$. `OP_INVERT` of $2^31 - 1$ yields $-2^31$, pushed as 5 bytes.],
    [`0x84`], [`OP_AND`], [`int32(x1) & int32(x2)`.],
    [`0x85`], [`OP_OR`], [`int32(x1) | int32(x2)`.],
    [`0x86`], [`OP_XOR`], [`int32(x1) ^ int32(x2)`.],
    [`0x87`], [`OP_EQUAL`], [Pop two elements; push true if they are identical byte strings (same length and bytes), else false. No numeric interpretation: `00` and the empty string differ.],
    [`0x88`], [`OP_EQUALVERIFY`], [`OP_EQUAL` then verify (`ErrEqualVerify`).],
    [`0x89`], [`OP_ROTR`], [@rule:script-rotate.],
    [`0x8a`], [`OP_ROTL`], [@rule:script-rotate.],
  ),
) <tab:script-bitwise-ops>

#rule("OP_ROTR and OP_ROTL", src: ("txscript/opcode.go · opcodeRotr", "txscript/opcode.go · opcodeRotl"))[
  `[... v c]`. Pop the numeric *count* $c$, then the numeric *value* $v$
  (both 4-byte maximum). $c ≥ 0$ #MUST hold (`ErrNegativeRotation`) and
  $c ≤ 31$ #MUST hold (`ErrOverflowRotation`). Let $u$ = `uint32(v)`. The
  result is $u$ rotated right (`OP_ROTR`) or left (`OP_ROTL`) by $c$ bit
  positions within 32 bits, reinterpreted as `int32`. A rotation by 0 returns
  $v$ unchanged.
] <rule:script-rotate>

#pitfall[
  Because results are reinterpreted as signed and operands are limited to 4
  bytes, a rotation or shift whose result has bit 31 set produces a negative
  number; if that number is $-2^31$ its encoding is 5 bytes and it cannot be
  used as an operand again. For example `1 1 OP_ROTR` pushes $-2^31$
  (`00 00 00 80 80`), and feeding that to a second `OP_ROTR` fails with
  `ErrNumOutOfRange`, whereas `1 2 OP_ROTR` pushes $2^30$, which remains a valid operand.
]

=== Arithmetic <sec:script-op-arith>

All operands in @tab:script-arith-ops are 4-byte numeric operands. In the
binary operations, $a$ is the second element from the top (`x1`) and $b$ the
top element (`x2`), so `a b OP_SUB` computes $a - b$. Results marked "exact"
are computed without overflow (they lie within $[-(2^32 - 2), 2^32 - 2]$ and
may encode to 5 bytes). Booleans produced by numeric opcodes are the numbers 1
and 0, that is, `01` and the empty string.

#figure(
  caption: [Arithmetic opcodes],
  table(
    columns: (auto, auto, 1fr),
    table.header([Byte], [Opcode], [Result]),
    [`0x8b`], [`OP_1ADD`], [$a + 1$, exact.],
    [`0x8c`], [`OP_1SUB`], [$a - 1$, exact.],
    [`0x8d`], [`OP_2MUL`], [*No operation* (behaves as `OP_NOP`; nothing is popped or checked).],
    [`0x8e`], [`OP_2DIV`], [*No operation* (behaves as `OP_NOP`).],
    [`0x8f`], [`OP_NEGATE`], [$-a$.],
    [`0x90`], [`OP_ABS`], [$|a|$.],
    [`0x91`], [`OP_NOT`], [1 if $a = 0$, else 0.],
    [`0x92`], [`OP_0NOTEQUAL`], [0 if $a = 0$, else 1.],
    [`0x93`], [`OP_ADD`], [$a + b$, exact.],
    [`0x94`], [`OP_SUB`], [$a - b$, exact.],
    [`0x95`], [`OP_MUL`], [`int32(a * b)`: the product reduced modulo $2^32$ and reinterpreted as signed (wrapping).],
    [`0x96`], [`OP_DIV`], [`tdiv(a, b)` (truncating toward zero). $b = 0$ fails (`ErrDivideByZero`).],
    [`0x97`], [`OP_MOD`], [`tmod(a, b)` (remainder of truncating division, sign of $a$). $b = 0$ fails (`ErrDivideByZero`).],
    [`0x98`], [`OP_LSHIFT`], [@rule:script-shift.],
    [`0x99`], [`OP_RSHIFT`], [@rule:script-shift.],
    [`0x9a`], [`OP_BOOLAND`], [1 if $a ≠ 0$ and $b ≠ 0$, else 0.],
    [`0x9b`], [`OP_BOOLOR`], [1 if $a ≠ 0$ or $b ≠ 0$, else 0.],
    [`0x9c`], [`OP_NUMEQUAL`], [1 if $a = b$, else 0.],
    [`0x9d`], [`OP_NUMEQUALVERIFY`], [`OP_NUMEQUAL` then verify (`ErrNumEqualVerify`).],
    [`0x9e`], [`OP_NUMNOTEQUAL`], [1 if $a ≠ b$, else 0.],
    [`0x9f`], [`OP_LESSTHAN`], [1 if $a < b$, else 0.],
    [`0xa0`], [`OP_GREATERTHAN`], [1 if $a > b$, else 0.],
    [`0xa1`], [`OP_LESSTHANOREQUAL`], [1 if $a ≤ b$, else 0.],
    [`0xa2`], [`OP_GREATERTHANOREQUAL`], [1 if $a ≥ b$, else 0.],
    [`0xa3`], [`OP_MIN`], [$min(a, b)$.],
    [`0xa4`], [`OP_MAX`], [$max(a, b)$.],
    [`0xa5`], [`OP_WITHIN`], [`[... x lo hi]`: pop `hi`, `lo`, `x`; 1 if $"lo" ≤ x < "hi"$, else 0.],
  ),
) <tab:script-arith-ops>

#rule("OP_LSHIFT and OP_RSHIFT", src: ("txscript/opcode.go · opcodeLShift", "txscript/opcode.go · opcodeRShift"))[
  `[... v c]`. Pop the numeric *count* $c$, then the numeric *value* $v$
  (both 4-byte maximum). $c ≥ 0$ #MUST hold (`ErrNegativeShift`) and
  $c ≤ 32$ #MUST hold (`ErrOverflowShift`). With $v$ as a 32-bit two's
  complement integer:
  - `OP_LSHIFT` pushes `int32(v << c)`, discarding bits shifted out of the
    32-bit width; for $c = 32$ the result is 0;
  - `OP_RSHIFT` pushes the arithmetic (sign-replicating) shift `v >> c`; for
    $c = 32$ the result is 0 if $v ≥ 0$ and $-1$ if $v < 0$.
] <rule:script-shift>

#pitfall[
  Shifts by 32 are defined (Go semantics). In C and C++, shifting a
  32-bit value by 32 is undefined; in Rust it panics in debug builds and
  silently masks the count in release builds, so that `x << 32` yields `x`.
  Implementations in those languages must special-case it. The same applies to the `32 - c` shift
  inside a rotation by 0.
]

#note[
  Overflow cannot occur in `OP_DIV` or `OP_MOD`: the only overflowing case of
  32-bit truncating division, $-2^31 div -1$, needs the operand $-2^31$,
  which is not a valid 4-byte operand. `OP_NOT` and `OP_0NOTEQUAL` decode
  their operand numerically, so `'abcdef' OP_NOT` fails with
  `ErrNumOutOfRange` rather than treating the string as a boolean.
]

=== Hash Opcodes <sec:script-op-hash>

Each hash opcode pops one element, hashes its bytes, and pushes the digest.
The functions are defined in #chref("crypto").

#figure(
  caption: [Hash opcodes],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Byte], [Opcode], [Digest], [Function]),
    [`0xa6`], [`OP_RIPEMD160`], [20], [RIPEMD-160(x).],
    [`0xa7`], [`OP_SHA1`], [20], [SHA-1(x).],
    [`0xa8`], [`OP_BLAKE256`], [32], [BLAKE-256(x) (14 rounds, as used throughout Decred).],
    [`0xa9`], [`OP_HASH160`], [20], [RIPEMD-160(BLAKE-256(x)). *Not* SHA-256 as in Bitcoin.],
    [`0xaa`], [`OP_HASH256`], [32], [BLAKE-256(BLAKE-256(x)). *Not* double SHA-256.],
    [`0xc0`], [`OP_SHA256`], [32], [SHA-256(x), only when `ScriptVerifySHA256` is set (@rule:script-sha256).],
  ),
) <tab:script-hash-ops>

#rule("OP_SHA256", src: "txscript/opcode.go · opcodeSha256")[
  If the flag `ScriptVerifySHA256` is set, executing byte `0xc0` pops $x$
  and pushes SHA-256($x$). If the flag is not set, it behaves as an
  upgradable no-operation (@rule:script-nops), named `OP_UNKNOWN192`.
] <rule:script-sha256>

#history[
  `OP_SHA256` was introduced by #dcp(2) @dcp0002 to support hash time-locked
  contracts that share a SHA-256 hash lock with other chains. It is enabled,
  together with `OP_CHECKSEQUENCEVERIFY`, by the `lnfeatures` agenda: the
  flag is set for a block exactly when that agenda is active for the block
  (#chref("transactions") specifies the flag selection, #chref("voting") the
  activation). Before activation, byte `0xc0` is a no-operation. The meaning
  of the byte therefore depends on the flag of the block that contains the
  spend, and an implementation must select the flag per block. Unlike the
  lock-time opcodes, which only make a no-operation stricter, this change is
  not a pure tightening: `<x> 0xc0 <SHA-256(x)> OP_EQUAL` is invalid before
  activation and valid after it, and `<h> 0xc0 <h> OP_EQUAL` the reverse.
]

=== Lock-Time Opcodes <sec:script-op-locktime>

These opcodes compare a stack value with fields of the spending transaction.
Neither removes its operand from the stack; scripts conventionally follow them
with `OP_DROP`. Both operands are decoded with a 5-byte maximum so that values
up to $2^32 - 1$ (and beyond) can be expressed.

#rule("OP_CHECKLOCKTIMEVERIFY", src: ("txscript/opcode.go · opcodeCheckLockTimeVerify", "txscript/opcode.go · verifyLockTime"))[
  If the flag `ScriptVerifyCheckLockTimeVerify` is not set, byte `0xb1`
  behaves as an upgradable no-operation (named `OP_NOP2`) (@rule:script-nops).
  Otherwise, let $L$ be the top element decoded as a number with maximum
  length 5, without popping it (an empty stack fails with
  `ErrInvalidStackOperation`), let $T$ be the transaction's lock time and $q$
  the sequence number of the input being verified. The following #MUST hold:
  + $L ≥ 0$ (`ErrNegativeLockTime`);
  + $L$ and $T$ are of the same kind: both $< 500000000$ (block heights) or
    both $≥ 500000000$ (Unix times) (`ErrUnsatisfiedLockTime`);
  + $L ≤ T$ (`ErrUnsatisfiedLockTime`);
  + $q ≠$ `0xffffffff` (`ErrUnsatisfiedLockTime`).
] <rule:script-cltv>

The opcode thus proves that the transaction's own lock time is at least $L$,
and the last condition ensures that the lock time is actually enforced for
this transaction (a transaction whose inputs all have the maximum sequence
number ignores its lock time; see #chref("transactions")).

#rule("OP_CHECKSEQUENCEVERIFY", src: "txscript/opcode.go · opcodeCheckSequenceVerify")[
  If the flag `ScriptVerifyCheckSequenceVerify` is not set, byte `0xb2`
  behaves as an upgradable no-operation (named `OP_NOP3`) (@rule:script-nops).
  Otherwise, let $s$ be the top element decoded as a number with maximum
  length 5, without popping it, let $V$ be the transaction version and $q$
  the sequence number of the input being verified. Then:
  + $s ≥ 0$ #MUST hold (`ErrNegativeLockTime`);
  + if bit 31 of $s$ is set ($s$ AND `0x80000000` $≠ 0$), the opcode
    succeeds with no further checks;
  + $V ≥ 2$ #MUST hold (`ErrUnsatisfiedLockTime`);
  + bit 31 of $q$ #MUST be clear (`ErrUnsatisfiedLockTime`);
  + let $m$ = `0x0040ffff` (the type flag, bit 22, together with the low 16
    bits), $s' = s$ AND $m$ and $q' = q$ AND $m$. $s'$ and $q'$ #MUST be of
    the same kind: both $< $ `0x00400000` or both $≥ $ `0x00400000`
    (`ErrUnsatisfiedLockTime`);
  + $s' ≤ q'$ #MUST hold (`ErrUnsatisfiedLockTime`).
] <rule:script-csv>

#note[
  Bits 16 to 21 and 23 to 30 of both values, and bits 32 to 38 of the 5-byte
  operand, are ignored. The meaning of the input sequence number as a relative
  lock time (blocks if bit 22 is clear, units of 512 seconds if set) and its
  enforcement are specified in #chref("transactions")\; this opcode only
  compares the script's requirement with the value the transaction commits
  to.
]

#pitfall[
  Both lock-time operands are subject to the minimal-encoding rule of
  @rule:script-numeric-operands. The test vector table of #dcp(3) lists the
  public key script `05 00 00 00 00 00 b2 51` (a 5-byte non-minimal encoding
  of zero followed by `OP_CHECKSEQUENCEVERIFY OP_1`) as valid; dcrd rejects
  it with `ErrMinimalData`. (The non-minimal lock-time operands in dcrd's
  `txscript/testdata/tx_invalid.json` are 6 bytes long and fail the length
  check, `ErrNumOutOfRange`, before minimality is considered.) The reference
  implementation is authoritative.
]

#history[
  `OP_CHECKLOCKTIMEVERIFY` is enforced on every block since the genesis block
  (the flag is unconditionally part of the consensus flags).
  `OP_CHECKSEQUENCEVERIFY` was introduced by #dcp(3) @dcp0003 and is enforced
  once the `lnfeatures` agenda is active; before that byte `0xb2` is a
  no-operation.
]

=== No-Operation and Unassigned Opcodes <sec:script-op-nops>

#rule("No-operation opcodes", src: "txscript/opcode.go · opcodeNop")[
  When executed:
  - `OP_NOP` (`0x61`), `OP_2MUL` (`0x8d`), `OP_2DIV` (`0x8e`) and the stake
    tag opcodes `0xba`–`0xbd` have no effect under any flags;
  - the *upgradable* no-operations `OP_NOP1` (`0xb0`), `OP_NOP4`–`OP_NOP10`
    (`0xb3`–`0xb9`) and #box[`OP_UNKNOWN196`–`OP_UNKNOWN248`] (`0xc4`–`0xf8`), and
    the flag-gated opcodes `0xb1`, `0xb2`, `0xc0`, `0xc1`, `0xc2`, `0xc3` when
    their enabling flag is not set, have no effect unless the flag
    `ScriptDiscourageUpgradableNops` is set, in which case they fail
    (`ErrDiscourageUpgradableNOPs`).

  All of these count toward the operation limit when reached.
] <rule:script-nops>

#rule("Reserved and invalid opcodes", src: ("txscript/opcode.go · opcodeReserved", "txscript/opcode.go · opcodeInvalid"))[
  Executing `OP_RESERVED` (`0x50`), `OP_VER` (`0x62`), or any of `0xf9`–`0xff`
  fails (`ErrReservedOpcode`). In an unexecuted branch they have no effect.
  `0x50` does not count toward the operation limit; the others do.
] <rule:script-reserved>

`ScriptDiscourageUpgradableNops` is a policy flag and is never set in
consensus validation; consensus therefore treats every upgradable
no-operation as a plain no-operation. Note also that `OP_2MUL` and `OP_2DIV`
are no-operations that are _not_ discouraged even under the policy flag.

=== Stake and Treasury Tag Opcodes <sec:script-op-stake>

Bytes `0xba`–`0xbd` (`OP_SSTX`, `OP_SSGEN`, `OP_SSRTX`, `OP_SSTXCHANGE`) and
`0xc1`–`0xc3` (`OP_TADD`, `OP_TSPEND`, `OP_TGEN`) are *tags*: when executed
they do nothing. Their meaning is structural and is enforced outside the
engine (@sec:script-stake). The stake tags `0xba`–`0xbd` are no-operations
under all flags. The treasury tags are no-operations when
`ScriptVerifyTreasury` is set; when it is not set they are the upgradable
no-operations `OP_UNKNOWN193`–`OP_UNKNOWN195` (@rule:script-nops).

== Signature Verification <sec:script-signatures>

Six opcodes verify signatures: `OP_CHECKSIG` and `OP_CHECKSIGVERIFY` (ECDSA
over secp256k1, one key), `OP_CHECKMULTISIG` and `OP_CHECKMULTISIGVERIFY`
(ECDSA, $m$ of $n$ keys), and `OP_CHECKSIGALT` and `OP_CHECKSIGALTVERIFY`
(alternative suites: Ed25519 and EC-Schnorr-DCRv0). In every case the
message signed is the 32-byte *signature hash* of @sec:script-sighash,
computed from the transaction, the input index, the hash type and a
*subscript* derived from the current script.

A *signature element* on the stack is the encoded signature followed by one
*hash type* byte. The engine distinguishes two kinds of failure. An
*encoding* failure (an invalid hash type, a non-canonical DER signature or a
disallowed public key format) makes the script fail immediately. A
*verification* failure (a signature that is well encoded but does not verify,
a public key that is not a valid curve point, and similar) makes the opcode
push false; the script fails only if that false value is later verified or
left as the result. The difference is observable (for example with
`OP_CHECKSIG OP_NOT`) and is consensus.

=== Encoding Checks <sec:script-encoding-checks>

#rule("Hash type encoding", src: "txscript/consensus.go · CheckHashTypeEncoding")[
  A hash type byte $t$ is valid if and only if $t$ AND `0x7f` is 1, 2 or 3;
  that is, $t$ is one of `0x01`, `0x02`, `0x03`, `0x81`, `0x82`, `0x83`. An
  invalid hash type is an encoding failure (`ErrInvalidSigHashType`).
] <rule:script-hashtype>

#rule("Strict DER signature encoding", src: "txscript/consensus.go · CheckSignatureEncoding")[
  An ECDSA signature $g$ (the signature element without its hash type byte)
  #MUST satisfy all of the following; any violation is an encoding failure
  with the error kind shown. Let $L = |g|$.
  + $L ≥ 8$ (`ErrSigTooShort`) and $L ≤ 72$ (`ErrSigTooLong`).
  + $g[0] =$ `0x30` (`ErrSigInvalidSeqID`).
  + $g[1] = L - 2$ (`ErrSigInvalidDataLen`).
  + Let $r_"len" = g[3]$ and $s_"type" = 4 + r_"len"$. $s_"type" < L$
    (`ErrSigMissingSTypeID`) and $s_"type" + 1 < L$ (`ErrSigMissingSLen`).
  + Let $s_"len" = g[s_"type" + 1]$. $s_"type" + 2 + s_"len" = L$
    (`ErrSigInvalidSLen`).
  + $g[2] =$ `0x02` (`ErrSigInvalidRIntID`); $r_"len" ≠ 0$
    (`ErrSigZeroRLen`); $g[4]$ AND `0x80` $= 0$ (`ErrSigNegativeR`); not
    ($r_"len" > 1$ and $g[4] = $ `0x00` and $g[5]$ AND `0x80` $= 0$)
    (`ErrSigTooMuchRPadding`).
  + $g[s_"type"] =$ `0x02` (`ErrSigInvalidSIntID`); $s_"len" ≠ 0$
    (`ErrSigZeroSLen`); the first byte of $S$ has its top bit clear
    (`ErrSigNegativeS`); not ($s_"len" > 1$ and $S$'s first byte is
    `0x00` and its second byte has the top bit clear)
    (`ErrSigTooMuchSPadding`).
  + With leading zero bytes removed, $S$ is at most 32 bytes, and as a
    big-endian integer $S < n$ and $S ≤ n / 2$ (rounded down), where $n$
    is the order of the secp256k1 group (`ErrSigHighS`).

  The bytes of $R$ are $g[4 : 4 + r_"len"]$ and those of $S$ are
  $g[s_"type" + 2 : L]$.
] <rule:script-der>

These checks do not ensure that $R$ is non-zero or less than $n$, nor that
$S$ is non-zero; those conditions are checked when the signature is parsed
(#chref("crypto")), and a failure there is a verification failure, not an
encoding failure.

#rule("Public key encoding", src: ("txscript/consensus.go · CheckPubKeyEncoding", "txscript/engine.go · isStrictPubKeyEncoding"))[
  A public key for `OP_CHECKSIG` or `OP_CHECKMULTISIG` #MUST be either 33
  bytes beginning with `0x02` or `0x03` (compressed) or 65 bytes beginning
  with `0x04` (uncompressed). Anything else, including the 65-byte "hybrid"
  formats beginning with `0x06` or `0x07`, is an encoding failure
  (`ErrPubKeyType`). Whether the bytes denote a point on the curve is
  checked later, and a failure there is a verification failure.
] <rule:script-pubkey-encoding>

=== The Subscript <sec:script-subscript>

The signature hash commits to the script containing the signature-checking
opcode, called the *current script*: the public key script for an ordinary
spend, the redeem script for a P2SH spend, or the signature script itself if
the signature opcode appears there. Because `OP_CODESEPARATOR` is disabled
(executing or passing over it fails), the subscript always starts at the
beginning of the current script.

Before hashing, every push in the current script whose data *contains* a
signature element being checked is removed. This exists for historical
reasons and rarely matters, but it is consensus.

#rule("Subscript construction", src: ("txscript/opcode.go · opcodeCheckSig", "txscript/script.go · removeOpcodeByData", "txscript/script.go · isCanonicalPush"))[
  The subscript for a signature element $e$ is the current script with every
  opcode removed that satisfies both:
  - it is *canonical* in the sense of @alg:script-remove (this differs from
    the minimal-push rule), and
  - its data contains $e$ as a contiguous substring.

  The opcodes that remain are concatenated in their original encoding. If
  $e$ is empty, nothing is removed. For `OP_CHECKMULTISIG` the removal is
  applied successively for every signature element popped, in the order they
  were popped (topmost first), before any signature is checked.
] <rule:script-subscript>

#algorithm("Removing signature pushes from the subscript", src: "txscript/script.go · removeOpcodeByData")[
  ```python
  def is_canonical_for_removal(op, data) -> bool:
      if op > 0x60:                               # not a push-class opcode
          return True
      if 0x00 < op < 0x4c and len(data) == 1 and data[0] <= 16:
          return False                            # note: includes data == 00
      if op == 0x4c and len(data) < 0x4c:   return False
      if op == 0x4d and len(data) <= 0xff:  return False
      if op == 0x4e and len(data) <= 0xffff: return False
      return True

  def remove_sig_pushes(script: bytes, e: bytes) -> bytes:
      if len(script) == 0 or len(e) == 0:
          return script
      out = b""
      for op, data, start, end in parse_with_offsets(script):
          if is_canonical_for_removal(op, data) and contains(data, e):
              continue                              # drop this opcode
          out += script[start:end]                  # keep its original bytes
      return out
  ```
] <alg:script-remove>

Opcodes without data never match (a non-empty $e$ is not a substring of the
empty string). Note that `OP_DATA_1 00` counts as *non-canonical* here
(although it is a minimal push under @rule:script-minimal-push), whereas
`OP_DATA_1 81` counts as canonical.

=== OP_CHECKSIG <sec:script-checksig>

#rule("OP_CHECKSIG", src: "txscript/opcode.go · opcodeCheckSig")[
  `[... sig pk] → [... bool]`. In this order:
  + Pop $p$ (the public key), then $e$ (the signature element).
  + If $|e| = 0$, push false and stop. (The public key is not checked.)
  + Let $t$ be the last byte of $e$ and $g$ the preceding bytes. $t$ #MUST
    pass @rule:script-hashtype, $g$ #MUST pass @rule:script-der and $p$ #MUST
    pass @rule:script-pubkey-encoding; each failure is an encoding failure.
  + Build the subscript by @rule:script-subscript for $e$ and compute the
    signature hash $h$ (@alg:script-sighash) with hash type $t$. If the hash
    cannot be computed (the `SIGHASH_SINGLE` case of
    @rule:script-sighash-single), push false and stop.
  + Parse $p$ as a secp256k1 point and $g$ as a DER signature
    (#chref("crypto")); if either fails, push false and stop.
  + Push true if the ECDSA signature $g$ is valid for $h$ under $p$, else
    false.
] <rule:script-checksig>

`OP_CHECKSIGVERIFY` performs `OP_CHECKSIG` followed by verification of the
result (`ErrCheckSigVerify`).

=== OP_CHECKMULTISIG <sec:script-checkmultisig>

Decred's multisignature opcode does *not* pop an extra "dummy" element. A
signature script that supplies Bitcoin's customary leading `OP_0` leaves that
element on the stack, which fails the clean-stack rule in consensus
validation.

#rule("OP_CHECKMULTISIG", src: "txscript/opcode.go · opcodeCheckMultiSig")[
  `[... sig_1 … sig_m m pk_1 … pk_n n] → [... bool]`. In this order:
  + Pop the numeric operand $n$ (4-byte maximum). $0 ≤ n ≤ 20$ #MUST hold
    (`ErrInvalidPubKeyCount`).
  + Add $n$ to the per-script operation count; the count #MUSTNOT exceed 255
    (`ErrTooManyOperations`).
  + Pop $n$ public keys. Call them $K_0, …, K_(n-1)$ in popping order
    ($K_0$ was on top, so $K_0 = $ `pk_n`).
  + Pop the numeric operand $m$ (4-byte maximum). $0 ≤ m ≤ n$ #MUST hold
    (`ErrInvalidSignatureCount`).
  + Pop $m$ signature elements $E_0, …, E_(m-1)$ in popping order
    ($E_0 = $ `sig_m`).
  + Compute the subscript by applying @rule:script-subscript for $E_0$,
    then $E_1$, and so on.
  + Match signatures to keys with @alg:script-multisig and push its result.
] <rule:script-checkmultisig>

#algorithm("OP_CHECKMULTISIG matching", src: "txscript/opcode.go · opcodeCheckMultiSig")[
  ```python
  def multisig_match(E, K, subscript, tx, idx) -> bool:
      parsed = [None] * len(E)          # None: not yet parsed; INVALID; or a signature
      keys_left, sigs_left = len(K) + 1, len(E)
      ki, si = -1, 0
      while sigs_left > 0:
          ki += 1; keys_left -= 1
          if sigs_left > keys_left:
              return False                         # cannot succeed any more
          e, k = E[si], K[ki]
          if len(e) == 0:
              continue                             # empty signature: next key
          t, g = e[-1], e[:-1]
          if parsed[si] is None:
              check_hash_type(t)                   # encoding failure: script fails
              check_der(g)                         # encoding failure: script fails
              parsed[si] = parse_der(g) or INVALID
              if parsed[si] is INVALID:
                  continue
          elif parsed[si] is INVALID:
              continue
          check_pubkey_encoding(k)                 # encoding failure: script fails
          point = parse_pubkey(k)
          if point is None:
              continue
          h = signature_hash(subscript, t, tx, idx)    # SIGHASH_SINGLE out of range:
                                                       # the script FAILS here
          if ecdsa_verify(parsed[si], h, point):
              si += 1; sigs_left -= 1
      return True
  ```
] <alg:script-multisig>

Consequences that must be reproduced exactly:

- Signatures must appear in the same relative order as the keys they match.
  Matching starts from the topmost signature and topmost key.
- A key that fails to match the current signature is skipped and never
  reconsidered. Once fewer keys remain than signatures, the result is false
  without examining the rest.
- Encoding checks are lazy: a signature's hash type and DER encoding are
  checked only when that signature is first compared, and a key's encoding
  only when it is compared against a non-empty, parseable signature. Elements
  never reached are never checked, so a badly encoded key or signature beyond
  the point of early exit does not cause failure.
- An empty signature element matches no key; with $m ≥ 1$ empty elements, the
  result is false after the keys are exhausted.
- With $m = 0$ the result is true and no key is examined;
  `0 0 OP_CHECKMULTISIG` pushes true.
- Unlike `OP_CHECKSIG`, an out-of-range `SIGHASH_SINGLE` makes the script
  *fail* rather than push false.
- The key count $n$ is added to the operation count whenever the opcode is
  executed, regardless of how many keys are examined.

`OP_CHECKMULTISIGVERIFY` performs `OP_CHECKMULTISIG` followed by verification
(`ErrCheckMultiSigVerify`).

=== OP_CHECKSIGALT <sec:script-checksigalt>

`OP_CHECKSIGALT` verifies a signature under one of several alternative
signature suites, selected by a small integer on top of the stack.
@tab:script-sigtypes lists the suites.

#figure(
  caption: [Signature types for `OP_CHECKSIGALT`],
  table(
    columns: (auto, auto, auto, auto, 1fr),
    table.header([Type], [Suite], [Public key], [Element], [Behaviour]),
    [0], [(ECDSA, not allowed here)], [—], [—], [Pushes false; nothing else popped.],
    [1], [Ed25519], [32 bytes], [65 bytes], [Verified as below.],
    [2], [EC-Schnorr-DCRv0 (secp256k1)], [33 bytes], [65 bytes], [Verified as below.],
    [other], [unassigned], [—], [—], [Pushes *true*; nothing else popped.],
  ),
) <tab:script-sigtypes>

#rule("OP_CHECKSIGALT", src: "txscript/opcode.go · opcodeCheckSigAlt")[
  `[... sig pk type] → [... bool]`. In this order:
  + Pop the numeric operand $y$ with maximum length *1* (so
    $-127 ≤ y ≤ 127$; a longer element fails with `ErrNumOutOfRange`).
  + If $y = 0$, push false and stop. If $y$ is neither 1 nor 2, push true and
    stop. In both cases the public key and signature are not popped.
  + Pop $p$. If $|p| ≠ 32$ (for $y = 1$) or $|p| ≠ 33$ (for $y = 2$), push
    false and stop; the signature element is *not* popped.
  + Pop $e$. If $|e| ≠ 65$, push false and stop.
  + Let $t = e[64]$ and $g = e[0:64]$. $t$ #MUST pass @rule:script-hashtype
    (encoding failure). No DER or public key format check applies.
  + Build the subscript by @rule:script-subscript for $e$ and compute the
    signature hash $h$ with hash type $t$. If it cannot be computed, push
    false and stop.
  + For $y = 1$: parse $p$ as an Ed25519 public key and $g$ as an Ed25519
    signature; for $y = 2$: parse $p$ as a compressed secp256k1 public key
    (first byte `0x02` or `0x03`) and $g$ as an EC-Schnorr-DCRv0 signature
    $(r, s)$ with $r < p_"field"$ and $s < n$ (#chref("crypto")). If either
    parse fails, push false; otherwise push the result of verifying $g$ over
    $h$ under $p$.
] <rule:script-checksigalt>

`OP_CHECKSIGALTVERIFY` performs `OP_CHECKSIGALT` followed by verification
(`ErrCheckSigAltVerify`).

#pitfall[
  The early exits of `OP_CHECKSIGALT` leave elements on the stack. For an
  unassigned type such as 3 the opcode consumes only the type and pushes
  true, so `3 OP_CHECKSIGALT` succeeds on an otherwise empty stack. With a
  wrong-length public key the signature element stays beneath the pushed
  false. Under the clean-stack rule these leftovers usually cause failure,
  but an implementation that pops all three operands up front produces
  different results for scripts such as
  `<sig> <short key> 1 OP_CHECKSIGALT OP_NOT OP_DROP`.
]

#rationale[
  Treating unknown signature types as success was intended to allow new
  suites to be introduced as soft forks, by making a previously
  always-succeeding opcode stricter. Type 0 is the identifier of ECDSA over
  secp256k1 (`STEcdsaSecp256k1`), which has its own opcodes; through
  `OP_CHECKSIGALT` it always yields false.
]

@tab:script-sig-failures summarizes which conditions fail the script and
which push false.

#figure(
  caption: [Failure modes of the signature opcodes],
  table(
    columns: (1fr, auto, auto, auto),
    table.header([Condition], [`CHECKSIG`], [`CHECKMULTISIG`], [`CHECKSIGALT`]),
    [Too few stack elements], [fail], [fail], [fail#super[a]],
    [Empty signature element], [false], [skip key], [false (wrong length)],
    [Invalid hash type], [fail], [fail (if reached)], [fail],
    [DER encoding violation], [fail], [fail (if reached)], [n/a],
    [Public key format violation], [fail], [fail (if reached)], [false (length only)],
    [Key not a valid point / signature unparseable], [false], [skip], [false],
    [`SIGHASH_SINGLE` index out of range], [false], [fail], [false],
    [Signature does not verify], [false], [skip key], [false],
  ),
) <tab:script-sig-failures>

#text(size: 8.6pt)[
  #super[a] Only for elements actually popped: signature type 0 and unknown
  types return after popping the type alone, and a public key of the wrong
  length yields false before the signature is popped, leaving the signature
  on the stack (@rule:script-checksigalt).
]

== Signature Hash <sec:script-sighash>

The signature hash is the 32-byte message that signatures commit to. Decred
computes it from two intermediate hashes, mirroring its split of a
transaction into a *prefix* (inputs' outpoints and sequences, outputs, lock
time, expiry) and a *witness* (per-input data, #chref("encoding")). The prefix
hash commits to the parts of the prefix selected by the hash type; the witness
hash commits to the subscript, placed at the position of the input being
signed. The final hash commits to the hash type and both intermediate hashes.
All three hashes use BLAKE-256.

#figure(
  caption: [Signature hash types],
  table(
    columns: (auto, auto, 1fr),
    table.header([Value], [Name], [Commits to]),
    [`0x01`], [`SIGHASH_ALL`], [All inputs and all outputs.],
    [`0x02`], [`SIGHASH_NONE`], [All inputs (other inputs' sequence numbers replaced by 0) and no outputs.],
    [`0x03`], [`SIGHASH_SINGLE`], [All inputs (other inputs' sequence numbers replaced by 0) and the output at the same index as the input; earlier outputs are committed in blanked form, later outputs not at all.],
    [`0x80`], [`SIGHASH_ANYONECANPAY`], [Flag combined with one of the above: only the input being signed is committed, in both the prefix and the witness.],
  ),
) <tab:script-hashtypes>

Two constants select the serialization variant and are mixed into the version
field of each intermediate serialization: #const("SigHashSerializePrefix") $= 1$
and #const("SigHashSerializeWitness") $= 3$.

#rule("SIGHASH_SINGLE with no matching output", src: "txscript/sighash.go · calcSignatureHash")[
  If the hash type AND `0x1f` equals 3 and the input index is greater than or
  equal to the number of transaction outputs, the signature hash is
  undefined (`ErrInvalidSigHashSingleIndex`). The consequence is
  opcode-specific: `OP_CHECKSIG` and `OP_CHECKSIGALT` push false, and
  `OP_CHECKMULTISIG` fails the script (@tab:script-sig-failures).
] <rule:script-sighash-single>

#algorithm("Signature hash", src: ("txscript/sighash.go · calcSignatureHash", "txscript/sighash.go · CalcSignatureHash"))[
  ```python
  ALL, NONE, SINGLE, ANYONECANPAY = 0x01, 0x02, 0x03, 0x80
  SER_PREFIX, SER_WITNESS = 1, 3

  def signature_hash(sub: bytes, t: int, tx, idx: int) -> bytes:
      base = t & 0x1f
      if base == SINGLE and idx >= len(tx.outputs):
          fail("ErrInvalidSigHashSingleIndex")
      if t & ANYONECANPAY:
          ins, sign_in = [tx.inputs[idx]], 0
      else:
          ins, sign_in = tx.inputs, idx
      if base == NONE:
          outs = []
      elif base == SINGLE:
          outs = tx.outputs[: idx + 1]
      else:                                    # ALL (and any other value)
          outs = tx.outputs

      p = le32(tx.version | (SER_PREFIX << 16)) + varint(len(ins))
      for j, ti in enumerate(ins):
          seq = ti.sequence
          if base in (NONE, SINGLE) and j != sign_in:
              seq = 0
          p += ti.prev_hash + le32(ti.prev_index) + u8(ti.prev_tree) + le32(seq)
      p += varint(len(outs))
      for j, to in enumerate(outs):
          value, script = to.value, to.pk_script
          if base == SINGLE and j != idx:
              value, script = -1, b""          # version is kept
          p += le64(uint64(value)) + le16(to.version) + varint(len(script)) + script
      p += le32(tx.lock_time) + le32(tx.expiry)

      w = le32(tx.version | (SER_WITNESS << 16)) + varint(len(ins))
      for j in range(len(ins)):
          s = sub if j == sign_in else b""
          w += varint(len(s)) + s

      return BLAKE256(le32(t) + BLAKE256(p) + BLAKE256(w))
  ```
] <alg:script-sighash>

Notes on @alg:script-sighash:

- `tx.version` is the 16-bit transaction version; the low 16 bits of the
  32-bit field are the version and the high 16 bits the serialization type.
  `varint` is the variable-length integer of #chref("encoding"). `prev_hash`
  is the 32-byte previous transaction hash in its internal (non-reversed)
  byte order, and `prev_tree` is the one-byte tree indicator of the outpoint.
- The final serialization is 68 bytes: the full hash type byte zero-extended
  to 32 bits and written little-endian, followed by the two 32-byte hashes.
- For `SIGHASH_ALL` without `SIGHASH_ANYONECANPAY`, the prefix serialization
  is byte-for-byte the transaction prefix serialization of #chref("encoding"),
  so the prefix hash equals the transaction hash. This is not true of the
  witness part: the signature-hash witness contains only the subscript for
  the signed input and an empty script for every other input, and none of the
  value, block height, block index or signature script fields of the wire
  witness serialization.
- In the `SIGHASH_SINGLE` case, every output before the signed index is
  committed with amount $-1$ (eight `0xff` bytes), its original script
  version, and an empty script; outputs after the index are omitted. With
  `SIGHASH_ANYONECANPAY`, the comparison `j != idx` still uses the original
  input index, since output positions are not renumbered.
- Within the engine the hash type has already passed @rule:script-hashtype,
  so `base` is 1, 2 or 3. The mask `0x1f` and the treatment of other values as
  `SIGHASH_ALL` matter only to external callers of the function (dcrd's test
  vectors exercise them).
- `OP_CODESEPARATOR` has no role: it cannot appear in a script that executes.
  The subscript `sub` is the whole current script minus the pushes removed
  by @rule:script-subscript.

The signature hash vectors in @sec:script-vectors show the intermediate
serializations for each hash type.

== Pay-to-Script-Hash <sec:script-p2sh>

Pay-to-script-hash @bip16 lets an output commit to the hash of an arbitrary
*redeem script* rather than to the script itself. The spender reveals the
redeem script as the last push of the signature script, together with the data
that satisfies it. The engine first checks that the revealed script hashes to
the committed value, then executes the redeem script. In Decred the hash is
`OP_HASH160`, that is RIPEMD-160(BLAKE-256(·)).

Pay-to-script-hash is recognized purely by the byte pattern of the public key
script (@sec:script-construction), regardless of the script version and of
any flags other than `ScriptVerifyTreasury`, which widens the set of stake
tags. There is no activation height: P2SH has been enforced since the genesis
block.

#figure(
  caption: [Pay-to-script-hash patterns],
  table(
    columns: (auto, auto, 1fr),
    table.header([Form], [Length], [Bytes]),
    [P2SH], [23], [`a9 14` ‖ 20-byte hash ‖ `87`],
    [Stake-tagged P2SH], [24], [tag ‖ `a9 14` ‖ 20-byte hash ‖ `87`, tag ∈ {`ba`, `bb`, `bc`, `bd`}, or also ∈ {`c1`, `c2`, `c3`} when `ScriptVerifyTreasury` is set],
  ),
) <tab:script-p2sh-forms>

The 23-byte form is recognized only when the whole public key script is
exactly that pattern; the bytes `a9 14 … 87` embedded in a longer script do
not make it P2SH. A stake-tagged P2SH script executes its tag as a
no-operation, then the ordinary hash comparison.

#rule("Pay-to-script-hash evaluation", src: ("txscript/engine.go · Engine.Step", "txscript/engine.go · NewEngine"))[
  If the public key script is P2SH-shaped:
  + the signature script #MUST be push-only, and for version 0 the
    redeem-script conditions of @rule:script-construction step 4 #MUST hold;
  + after the signature script, the data stack is saved, and the public key
    script is executed on it as usual (it compares the hash of the top
    element with the committed hash);
  + after the public key script, the data stack #MUST be non-empty
    (`ErrEmptyStack`) and its top element #MUST be true (`ErrEvalFalse`).
    No clean-stack check applies at this point;
  + the redeem script $R$ is the top element of the saved stack. $R$ #MUST
    parse (`ErrMalformedPush`). The data stack is replaced by the saved stack
    with $R$ removed, and $R$ is executed as a third script, with its own
    operation count, alternate stack and conditional state;
  + the final result is then determined by @rule:script-final.
] <rule:script-p2sh-eval>

#rule("No stake opcodes in redeem scripts", src: "txscript/script.go · hasP2SHRedeemScriptStakeOpCodes")[
  For a version 0 spend of a P2SH-shaped output, the redeem script #MUSTNOT
  contain any of the opcodes `0xba`–`0xbd`, and, when `ScriptVerifyTreasury`
  is set, `0xc1`–`0xc3` (`ErrP2SHStakeOpCodes`). The redeem script is
  scanned opcode by opcode from the start; if a parse failure is met before
  any such opcode, the spend also fails.
] <rule:script-p2sh-stake>

#rationale[
  Stake and treasury tags are meaningful only in the precise positions the
  stake system checks. Hiding one inside a redeem script, where no structural
  rule can see it, is prohibited outright so that tagged scripts cannot be
  smuggled into regular transactions.
]

#note[
  Redeem scripts are not subject to the 16384-byte script size limit, but as
  stack elements they are limited to 2048 bytes by @rule:script-opcode-processing.
  Like every script, a redeem script has its own limit of 255 operations.
]

#history[
  Before the `treasury` agenda (#dcp(6)) is active, the flag
  `ScriptVerifyTreasury` is not set, so `0xc1`–`0xc3` are neither stake tags
  for P2SH detection nor prohibited in redeem scripts. A script such as
  `c1 a9 14 … 87` is then executed as an ordinary script whose first opcode is
  a no-operation (`OP_UNKNOWN193`), not as P2SH; dcrd's test data includes
  both cases.
]

== Stake and Treasury Tags <sec:script-stake>

Decred's staking and treasury transactions place tag opcodes at the start of
specific output scripts. A ticket's voting-rights output begins with
`OP_SSTX`, its change outputs with `OP_SSTXCHANGE`, vote outputs with
`OP_SSGEN`, revocation outputs with `OP_SSRTX`, treasury additions with
`OP_TADD`, treasury spend payouts with `OP_TGEN`, and the treasury spend
signature script ends with `OP_TSPEND`. The tags let consensus code recognize
these outputs, and impose maturity and other spending restrictions on them,
without executing scripts.

The script engine itself enforces only the following; everything else about
the tags is a transaction-level rule.

+ Executing a tag does nothing (@sec:script-op-stake). After the tag, a
  tagged pay-to-pubkey-hash script is executed exactly as the untagged form,
  and a tagged P2SH script is evaluated as P2SH (@rule:script-p2sh-eval).
+ Redeem scripts must not contain tags (@rule:script-p2sh-stake).
+ The treasury tags `0xc1`–`0xc3` are tags only when `ScriptVerifyTreasury`
  is set; otherwise they are upgradable no-operations.

The rules that restrict where tags may appear, and what must follow them, are
specified elsewhere and summarized in @tab:script-tag-owners.

#figure(
  caption: [Where tag placement is enforced (informative)],
  table(
    columns: (auto, 1fr, auto),
    table.header([Tag], [Required forms], [Specified in]),
    [`OP_SSTX`], [Ticket output 0: tag followed by a P2PKH or P2SH script (26 or 24 bytes).], [#chref("staking")],
    [`OP_SSTXCHANGE`], [Ticket change outputs, and the optional change output (output 1) of a treasury add: tag followed by P2PKH or P2SH.], [#chref("staking"), #chref("treasury")],
    [`OP_SSGEN`], [Vote payment outputs: tag followed by P2PKH or P2SH.], [#chref("staking")],
    [`OP_SSRTX`], [Revocation outputs: tag followed by P2PKH or P2SH.], [#chref("staking")],
    [`OP_TADD`], [Treasury add and treasurybase output 0: the single byte `c1`.], [#chref("treasury")],
    [`OP_TGEN`], [Treasury spend payouts: tag followed by P2PKH or P2SH.], [#chref("treasury")],
    [`OP_TSPEND`], [Treasury spend signature script: `OP_DATA_64 <sig> OP_DATA_33 <key> OP_TSPEND` (100 bytes).], [#chref("treasury")],
    [any], [Outputs of regular (non-stake) transactions must not contain any tag opcode (@rule:script-contains-stake).], [#chref("transactions")],
  ),
) <tab:script-tag-owners>

#rule("Detecting tag opcodes in a script", src: ("txscript/script.go · ContainsStakeOpCodes", "txscript/script.go · isStakeOpcode"))[
  A script *contains a stake opcode* if, scanning its opcodes in order with
  version 0 parsing, an opcode in `0xba`–`0xbd` is found, or, when treasury
  rules are in effect, an opcode in `0xc1`–`0xc3`, before the end of the
  script or the first parse failure. If a parse failure is reached first, the
  predicate reports that failure as an error. Opcode bytes are only examined
  at opcode boundaries; a tag value inside push data does not count.
] <rule:script-contains-stake>

The transaction-level rule that applies this predicate to regular
transactions (and treats the parse error as invalidity) is in
#chref("transactions").

== Verification Flags <sec:script-flags>

The caller passes a set of flags that modify the engine. @tab:script-flags
lists every flag defined by dcrd, with its bit value and effect. Which flags
consensus validation passes for a given block is specified in
#chref("transactions")\; as of the reference commit it is
`ScriptVerifyCleanStack` and `ScriptVerifyCheckLockTimeVerify` for every
block, plus `ScriptVerifyCheckSequenceVerify` and `ScriptVerifySHA256` when
the `lnfeatures` agenda is active, plus `ScriptVerifyTreasury` when the
`treasury` agenda is active. `ScriptDiscourageUpgradableNops` and
`ScriptVerifySigPushOnly` are never used for consensus. dcrd's relay policy
sets the first but not the second: it obtains the push-only requirement from
a separate standardness check (#chref("policy")).

#figure(
  caption: [Script verification flags],
  table(
    columns: (auto, auto, 1fr),
    table.header([Bit], [Flag], [Effect when set]),
    [`0x01`], [`ScriptDiscourageUpgradableNops`], [Executing an upgradable no-operation fails (@rule:script-nops). Policy only.],
    [`0x02`], [`ScriptVerifyCheckLockTimeVerify`], [Byte `0xb1` is `OP_CHECKLOCKTIMEVERIFY` (@rule:script-cltv); otherwise it is the no-operation `OP_NOP2`.],
    [`0x04`], [`ScriptVerifyCheckSequenceVerify`], [Byte `0xb2` is `OP_CHECKSEQUENCEVERIFY` (@rule:script-csv); otherwise it is `OP_NOP3`.],
    [`0x08`], [`ScriptVerifyCleanStack`], [The data stack must hold exactly one element at the end (@rule:script-final).],
    [`0x10`], [`ScriptVerifySigPushOnly`], [Every signature script must be push-only (@rule:script-construction step 2). Set by neither consensus nor dcrd's policy.],
    [`0x20`], [`ScriptVerifySHA256`], [Byte `0xc0` is `OP_SHA256` (@rule:script-sha256); otherwise it is `OP_UNKNOWN192`.],
    [`0x40`], [`ScriptVerifyTreasury`], [Bytes `0xc1`–`0xc3` are the treasury tags: they count as stake tags for P2SH detection and redeem-script prohibition. Otherwise they are #box[`OP_UNKNOWN193`–`OP_UNKNOWN195`].],
  ),
) <tab:script-flags>

The signature operation counter (@sec:script-sigops) and
@rule:script-contains-stake take a separate "treasury rules in effect"
argument. It reflects the same agenda condition as `ScriptVerifyTreasury`,
but is supplied by the caller rather than read from the engine flags.

== Signature Operation Counting <sec:script-sigops>

To bound the cost of validating a block, consensus limits the number of
*signature operations* a block may contain (#chref("blocks")). The count is a
static estimate made without executing scripts. This section specifies the
counting functions; the limit, and which transactions of a block are counted,
are in #chref("blocks").

#algorithm("Counting signature operations in one script", src: ("txscript/script.go · countSigOpsV0", "txscript/script.go · GetSigOpCount"))[
  ```python
  def count_sigops(script: bytes, precise: bool, treasury: bool) -> int:
      n, prev = 0, 0xff                       # prev starts as OP_INVALIDOPCODE
      for op, data in parse_prefix(script):   # opcodes before any parse failure
          if op == 0xc2:                      # OP_TSPEND
              if treasury: n += 1
          elif op in (0xac, 0xad, 0xbe, 0xbf):  # CHECKSIG(VERIFY), CHECKSIGALT(VERIFY)
              n += 1
          elif op in (0xae, 0xaf):            # CHECKMULTISIG(VERIFY)
              if precise and 0x51 <= prev <= 0x60:   # OP_1 .. OP_16
                  n += prev - 0x50
              else:
                  n += 20
          prev = op
      return n
  ```
] <alg:script-sigops>

`parse_prefix` yields the opcodes of the script that parse successfully
before its first parse failure (all of them if there is none); a malformed
script is counted up to the failure, not rejected. Opcodes are counted
wherever they appear, including in branches that would not be executed and
after an `OP_RETURN`. Push data is not inspected.

The *imprecise* count, `GetSigOpCount(script, treasury)`, is
`count_sigops(script, False, treasury)`: every multisignature opcode counts 20. The *precise*
count applies to P2SH spends.

#algorithm("Precise count for a P2SH spend", src: ("txscript/script.go · GetPreciseSigOpCount", "txscript/script.go · finalOpcodeData"))[
  ```python
  def precise_sigops(sig_script, pk_script, treasury) -> int:
      if not is_p2sh(pk_script):               # 23-byte untagged form only
          return count_sigops(pk_script, True, treasury)
      if len(sig_script) == 0 or not is_push_only(sig_script):
          return 0
      redeem = final_opcode_data(sig_script)   # b"" if unparseable or no data
      if len(redeem) == 0:
          return 0
      return count_sigops(redeem, True, treasury)
  ```
] <alg:script-precise-sigops>

In precise mode, a multisignature opcode counts the value of an immediately
preceding `OP_1`–`OP_16`; it counts 20 if the preceding opcode is anything
else, including `OP_0` and a numeric data push such as `01 11` (17). Despite
its name, the "precise" count is therefore an upper bound for key counts 17
to 20.

#rule("Transaction signature operation count", src: ("internal/blockchain/validate.go · CountTotalSigOps", "internal/blockchain/validate.go · countSigOps", "internal/blockchain/validate.go · countP2SHSigOps"))[
  The signature operation count of a transaction, given whether it is a
  coinbase, whether it is a vote, the UTXO view, and whether the treasury
  agenda is active ($"tr"$), is $A + B$, where:

  $A$ (the imprecise part):
  - if $"tr"$ and the transaction is a treasurybase, $A = 0$;
  - otherwise $A$ is the sum of `GetSigOpCount` over the signature scripts of
    all inputs (no inputs for a coinbase; all inputs except the first for a
    vote) plus the sum of `GetSigOpCount` over the public key scripts of all
    outputs.

  $B$ (the P2SH part):
  - if the transaction is a coinbase, or if $"tr"$ and it is a treasury spend
    or treasurybase, $B = 0$;
  - otherwise, for every input (all inputs except the first for a vote), the
    referenced output #MUST exist unspent in the view (`ErrMissingTxOut`); if
    its public key script is the 23-byte untagged P2SH form, add
    `precise_sigops(sig_script, pk_script, tr)`; other inputs add nothing.

  Every addition is performed in unsigned 32-bit arithmetic and #MUSTNOT
  overflow (`ErrTooManySigOps`).
] <rule:script-tx-sigops>

#pitfall[
  Spends of stake-tagged P2SH outputs contribute nothing to $B$, because only
  the untagged 23-byte form is examined; the signature operations of their
  redeem scripts are not counted anywhere. Signature operations in a redeem
  script are also never counted by the imprecise pass, because the redeem
  script is push data within the signature script. And `OP_TSPEND` counts as
  one signature operation once the treasury agenda is active, although the
  engine executes it as a no-operation, since the treasury spend's signature
  is checked by the treasury rules (#chref("treasury")).
]

== Other Consensus Predicates <sec:script-predicates>

Besides the engine, consensus code uses a few script predicates defined in
the same package.

#rule("Provably unspendable outputs", src: ("txscript/script.go · IsUnspendable", "internal/blockchain/utxoviewpoint.go · UtxoViewpoint.AddTxOuts"))[
  An output with amount $a$ and public key script $P$ is *provably
  unspendable* if any of the following holds, regardless of its script
  version:
  - $a = 0$;
  - $|P| > 16384$;
  - $|P| > 0$ and $P[0] =$ `0x6a` (`OP_RETURN`);
  - $P$ fails to parse under version 0 rules.

  Provably unspendable outputs are never added to the UTXO set
  (#chref("transactions")), so no input can ever spend them.
] <rule:script-unspendable>

#pitfall[
  This predicate ignores the script version and treats every zero-value
  output as unspendable. A zero-value output with script `51` (`OP_TRUE`), or
  a version-1 output whose script begins with `0x6a`, would pass the script
  engine but can never be spent, because it never enters the UTXO set. A
  script with `OP_RETURN` anywhere other than the first byte is not covered.
]

#rule("Strict null-data scripts", src: "txscript/consensus.go · IsStrictNullData")[
  A script $P$ with version $v$ is a *strict null-data script with required
  length* $ℓ$ if $v = 0$, $|P| ≥ 1$, $P[0] =$ `0x6a`, and either $|P| = 1$
  and $ℓ = 0$, or the remainder $P[1:]$ parses as exactly one opcode which
  is canonical under @alg:script-remove's `is_canonical_for_removal` and
  which is either a small-integer opcode (`OP_0` or `OP_1`–`OP_16`) with
  $ℓ = 1$, or an opcode at most `0x4b` (`OP_DATA_75`) whose data length is
  exactly $ℓ$.
] <rule:script-strict-nulldata>

The treasury rules use this predicate to check the `OP_RETURN` outputs of
treasurybase and treasury spend transactions (#chref("treasury")). A
companion predicate, *strict compressed public key encoding*, holds for
exactly the 33-byte strings beginning with `0x02` or `0x03`; it is used by the
treasury spend checks and by policy.

== Standard Script Classes <sec:script-standard>

The forms in this section are *policy*: dcrd's mempool and wallets recognize
them, but consensus never requires a script to be standard (except where the
stake and treasury rules require specific forms, which those chapters
specify). The mapping between addresses and these templates is in
#chref("addresses")\; standardness policy is in #chref("policy").

Recognition is defined for script version 0 only; a script with any other
version is non-standard. @tab:script-std lists the templates. In the
templates, `‖` is concatenation, `H` is a 20-byte hash, `K33` a 33-byte
compressed secp256k1 key (first byte `02` or `03`), `K65` a 65-byte
uncompressed key (first byte `04`) and `E32` a 32-byte Ed25519 key.

#figure(
  caption: [Standard version 0 script templates (policy)],
  table(
    columns: (auto, auto, 1fr),
    table.header([Class], [Bytes], [Template]),
    [`pubkey`], [35 / 67], [`21` ‖ `K33` ‖ `ac` #h(0.4em) or #h(0.4em) `41` ‖ `K65` ‖ `ac`],
    [`pubkey-ed25519`], [35], [`20` ‖ `E32` ‖ `51` ‖ `be`],
    [`pubkey-schnorr-secp256k1`], [36], [`21` ‖ `K33` ‖ `52` ‖ `be`],
    [`pubkeyhash`], [25], [`76 a9 14` ‖ `H` ‖ `88 ac`],
    [`pubkeyhash-ed25519`], [26], [`76 a9 14` ‖ `H` ‖ `88 51 be`],
    [`pubkeyhash-schnorr-secp256k1`], [26], [`76 a9 14` ‖ `H` ‖ `88 52 be`],
    [`scripthash`], [23], [`a9 14` ‖ `H` ‖ `87`],
    [`multisig`], [var.], [`OP_m` ‖ ($n$ pushes of `K33`) ‖ `OP_n` ‖ `ae`, $1 ≤ m ≤ n ≤ 16$],
    [`nulldata`], [1–260], [`6a`, or `6a` ‖ one canonical push of at most 256 bytes],
    [`stakesubmission-pubkeyhash`], [26], [`ba` ‖ `pubkeyhash`],
    [`stakesubmission-scripthash`], [24], [`ba` ‖ `scripthash`],
    [`stakegen-pubkeyhash`], [26], [`bb` ‖ `pubkeyhash`],
    [`stakegen-scripthash`], [24], [`bb` ‖ `scripthash`],
    [`stakerevoke-pubkeyhash`], [26], [`bc` ‖ `pubkeyhash`],
    [`stakerevoke-scripthash`], [24], [`bc` ‖ `scripthash`],
    [`stakechange-pubkeyhash`], [26], [`bd` ‖ `pubkeyhash`],
    [`stakechange-scripthash`], [24], [`bd` ‖ `scripthash`],
    [`treasuryadd`], [1], [`c1`],
    [`treasurygen-pubkeyhash`], [26], [`c3` ‖ `pubkeyhash`],
    [`treasurygen-scripthash`], [24], [`c3` ‖ `scripthash`],
  ),
) <tab:script-std>

Details of the less obvious templates:

- *Alternative-signature forms.* The signature type is pushed with a
  small-integer opcode: `51` (`OP_1`) for Ed25519 and `52` (`OP_2`) for
  EC-Schnorr-DCRv0. Type 0 is never standard. The Schnorr pay-to-pubkey form
  additionally requires the key's first byte to be `02` or `03`; the
  Ed25519 form imposes no condition on the 32 key bytes.
- *Multisig.* The first opcode is `OP_1`–`OP_16` giving $m$ (`OP_0` is
  rejected). It is followed by one or more opcodes whose data is a strict
  compressed key (any push opcode qualifies, not only `OP_DATA_33`; the run of
  keys ends at the first opcode whose data is not such a key), then a
  small-integer opcode equal to the number of keys $n$, with $n ≥ m$, and
  then `ae` (`OP_CHECKMULTISIG`) as the last and only remaining byte.
  Uncompressed keys are not standard in multisig. The 16-key maximum is
  narrower than the consensus limit of 20.
- *Null data.* After `6a`, exactly one opcode of byte value at most `0x60`
  that is canonical under `is_canonical_for_removal` of @alg:script-remove
  and whose data is at most 256 bytes (#const("MaxDataCarrierSizeV0")).
- *Precedence.* A script is assigned the first class that matches, in the
  order of @tab:script-std. The forms are mutually exclusive in practice, so
  the order rarely matters.

#note[
  dcrd also recognizes, for informational purposes only, the hash-based
  atomic swap contract below, intended to be used through P2SH. It is not a
  standard output class.
  ```
  IF SIZE <n> EQUALVERIFY SHA256 <32 bytes> EQUALVERIFY DUP HASH160 <20 bytes>
  ELSE <locktime> CHECKLOCKTIMEVERIFY DROP DUP HASH160 <20 bytes>
  ENDIF EQUALVERIFY CHECKSIG
  ```
]

== Test Vectors <sec:script-vectors>

All vectors in this section were produced by running dcrd's `txscript`
package at the reference commit. Hexadecimal strings are byte strings in
natural order; hashes are not reversed.

=== Numbers, Booleans and Hashes

#figure(
  caption: [Script number encodings],
  table(
    columns: (auto, auto, auto, auto),
    table.header([Value], [Encoding], [Value], [Encoding]),
    [$0$], [(empty)],[$-256$], [`00 81`],
    [$1$], [`01`],[$32767$], [`ff 7f`],
    [$-1$], [`81`],[$-32768$], [`00 80 80`],
    [$16$], [`10`],[$8388607$], [`ff ff 7f`],
    [$127$], [`7f`],[$-8388608$], [`00 00 80 80`],
    [$-127$], [`ff`],[$2147483647$], [`ff ff ff 7f`],
    [$128$], [`80 00`],[$-2147483647$], [`ff ff ff ff`],
    [$-128$], [`80 80`],[$2147483648$], [`00 00 00 80 00`],
    [$255$], [`ff 00`],[$-2147483648$], [`00 00 00 80 80`],
    [$-255$], [`ff 80`],[$4294967294$], [`fe ff ff ff 00`],
    [$256$], [`00 01`],[$549755813887$], [`ff ff ff ff 7f`],
  ),
) <tab:script-vec-num>

#figure(
  caption: [Script number decoding (maximum length 4 and 5)],
  table(
    columns: (auto, auto, auto),
    table.header([Element], [Max length 4], [Max length 5]),
    [(empty)], [$0$], [$0$],
    [`00`], [`ErrMinimalData`], [`ErrMinimalData`],
    [`80`], [`ErrMinimalData`], [`ErrMinimalData`],
    [`01 00`], [`ErrMinimalData`], [`ErrMinimalData`],
    [`ff 00`], [$255$], [$255$],
    [`ff 80`], [$-255$], [$-255$],
    [`7f`], [$127$], [$127$],
    [`ff`], [$-127$], [$-127$],
    [`00 80`], [`ErrMinimalData`], [`ErrMinimalData`],
    [`ff ff ff 7f`], [$2147483647$], [$2147483647$],
    [`ff ff ff ff`], [$-2147483647$], [$-2147483647$],
    [`00 00 00 80 00`], [`ErrNumOutOfRange`], [$2147483648$],
    [`ff ff ff ff 7f`], [`ErrNumOutOfRange`], [$549755813887$],
    [`00 00 00`], [`ErrMinimalData`], [`ErrMinimalData`],
  ),
) <tab:script-vec-dec>

#figure(
  caption: [Boolean interpretation],
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    table.header([Element], [Value], [Element], [Value], [Element], [Value], [Element], [Value]),
    [(empty)], [false], [`00`], [false], [`80`], [false], [`00 80`], [false],
    [`80 00`], [true], [`00 00 80`], [false], [`00 01`], [true], [`01`], [true],
  ),
) <tab:script-vec-bool>

#figure(
  caption: [Hash opcode outputs],
  table(
    columns: (auto, auto, 1fr),
    table.header([Opcode], [Input], [Output]),
    [`OP_RIPEMD160`], [(empty)], [#hex("9c1185a5c5e9fc54612808977ee8f548b2258d31")],
    [`OP_RIPEMD160`], [`"abc"`], [#hex("8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")],
    [`OP_SHA1`], [(empty)], [#hex("da39a3ee5e6b4b0d3255bfef95601890afd80709")],
    [`OP_SHA1`], [`"abc"`], [#hex("a9993e364706816aba3e25717850c26c9cd0d89d")],
    [`OP_SHA256`], [(empty)], [#hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")],
    [`OP_SHA256`], [`"abc"`], [#hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")],
    [`OP_BLAKE256`], [(empty)], [#hex("716f6e863f744b9ac22c97ec7b76ea5f5908bc5b2f67c61510bfc4751384ea7a")],
    [`OP_BLAKE256`], [`"abc"`], [#hex("1833a9fa7cf4086bd5fda73da32e5a1d75b4c3f89d5c436369f9d78bb2da5c28")],
    [`OP_HASH160`], [(empty)], [#hex("413320bee32a3bdb92b145d337316739d54a9287")],
    [`OP_HASH160`], [`"abc"`], [#hex("1625a1b44671b89a24386333ef9e00b207bca403")],
    [`OP_HASH256`], [(empty)], [#hex("d8ee5f957b78a961fb729098b4efb56440a14e05e3c55890f5edbc626380aaa6")],
    [`OP_HASH256`], [`"abc"`], [#hex("f1a44bb867d5ac7053d5e071d62d4513d5b243420d9863e2718823a161c1344a")],
  ),
) <tab:script-vec-hash>


=== Signature Hash

The vectors below use a sample transaction with version 1, two inputs and
two outputs. Input 0 spends output 1 of a transaction whose hash bytes are
`00 01 … 1f`, in the regular tree, with sequence `ffffffff`; input 1 spends
output 0 of `20 21 … 3f`, in the stake tree, with sequence `fffffffe`. The
inputs' witness fields (value 5000000000 and 100000000 atoms, block heights
100 and 200, block indexes 2 and 3, signature scripts `51` and `52`) appear in
the full serialization but do not affect the signature hash. Output 0 pays
1000 atoms to script version 0 `76 a9 14 01 02 … 14 88 ac`; output 1 pays 2000
atoms to `6a`. The lock time is `0x01020304` and the expiry `0x05060708`. The
subscript is output 0's script, used here simply as a 25-byte example.

#vector[Signature hash: the sample transaction][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Full serialization], [#hex("0100000002000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0100000000ffffffff202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0000000001feffffff02e80300000000000000001976a9140102030405060708090a0b0c0d0e0f101112131488acd0070000000000000000016a04030201080706050200f2052a010000006400000002000000015100e1f50500000000c8000000030000000152")],
    [Transaction hash (internal order)], [#hex("f3deadbbf50b1c407d09bc893408432844a0685df21ea15c4a73a9eba6480c5a")],
    [Subscript], [#hex("76a9140102030405060708090a0b0c0d0e0f101112131488ac")],
  )
]

#vector[Signature hash: SIGHASH_ALL (`0x1`), input 0][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Prefix serialization], [#hex("0100010002000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0100000000ffffffff202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0000000001feffffff02e80300000000000000001976a9140102030405060708090a0b0c0d0e0f101112131488acd0070000000000000000016a0403020108070605")],
    [Prefix hash], [#hex("f3deadbbf50b1c407d09bc893408432844a0685df21ea15c4a73a9eba6480c5a")],
    [Witness serialization], [#hex("01000300021976a9140102030405060708090a0b0c0d0e0f101112131488ac00")],
    [Witness hash], [#hex("bb75f775cbeee9c804eb983c29fcc2d97a2264e6fa75a87a15a06dd4286982e5")],
    [Final serialization], [#hex("01000000f3deadbbf50b1c407d09bc893408432844a0685df21ea15c4a73a9eba6480c5abb75f775cbeee9c804eb983c29fcc2d97a2264e6fa75a87a15a06dd4286982e5")],
    [Signature hash], [#hex("f4ce6e37ab599bcd9c770d086c79749a77f99e4a50e774caf5ff50a123feff91")],
  )
]

#vector[Signature hash: SIGHASH_NONE (`0x2`), input 0][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Prefix serialization], [#hex("0100010002000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0100000000ffffffff202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f000000000100000000000403020108070605")],
    [Prefix hash], [#hex("8aa0fda4bf9cc8936b0eec1cabc6795b0de37badda0b26b7063d475d74bd967b")],
    [Witness serialization], [#hex("01000300021976a9140102030405060708090a0b0c0d0e0f101112131488ac00")],
    [Witness hash], [#hex("bb75f775cbeee9c804eb983c29fcc2d97a2264e6fa75a87a15a06dd4286982e5")],
    [Final serialization], [#hex("020000008aa0fda4bf9cc8936b0eec1cabc6795b0de37badda0b26b7063d475d74bd967bbb75f775cbeee9c804eb983c29fcc2d97a2264e6fa75a87a15a06dd4286982e5")],
    [Signature hash], [#hex("03319bed79cbb29b3c6fe90e4ff6e301071ddeb3568d16462ca5ffeed787d44b")],
  )
]

#vector[Signature hash: SIGHASH_SINGLE (`0x3`), input 1][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Prefix serialization], [#hex("0100010002000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f010000000000000000202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0000000001feffffff02ffffffffffffffff000000d0070000000000000000016a0403020108070605")],
    [Prefix hash], [#hex("1c60e4485f51debb2dcdc9893293a6b4e6290a3d66c57756ed95cb74b7548927")],
    [Witness serialization], [#hex("0100030002001976a9140102030405060708090a0b0c0d0e0f101112131488ac")],
    [Witness hash], [#hex("4902291a3dcd005c1a087f947d7d37cc0de0f06daa470a5d7713f8d53b093cc7")],
    [Final serialization], [#hex("030000001c60e4485f51debb2dcdc9893293a6b4e6290a3d66c57756ed95cb74b75489274902291a3dcd005c1a087f947d7d37cc0de0f06daa470a5d7713f8d53b093cc7")],
    [Signature hash], [#hex("4641bb9be1f590a5cae964b188317cf168e158d24cfa27c7280941c684e42dc2")],
  )
]

#vector[Signature hash: SIGHASH_ALL | SIGHASH_ANYONECANPAY (`0x81`), input 0][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Prefix serialization], [#hex("0100010001000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0100000000ffffffff02e80300000000000000001976a9140102030405060708090a0b0c0d0e0f101112131488acd0070000000000000000016a0403020108070605")],
    [Prefix hash], [#hex("12912c99d91053050096a5745dc0d45c829c73fd45f7fa9164649c8fada6b272")],
    [Witness serialization], [#hex("01000300011976a9140102030405060708090a0b0c0d0e0f101112131488ac")],
    [Witness hash], [#hex("3db60c902d6e97e3b0a3ec8b55a7c330392e4740a46a3b79a93445c680e58a45")],
    [Final serialization], [#hex("8100000012912c99d91053050096a5745dc0d45c829c73fd45f7fa9164649c8fada6b2723db60c902d6e97e3b0a3ec8b55a7c330392e4740a46a3b79a93445c680e58a45")],
    [Signature hash], [#hex("4a1ecb30301eb4a7445ffca36202deda5f9552479fd2b223e3589f8738dbbde3")],
  )
]

#figure(
  caption: [Signature hashes of the sample transaction for every hash type],
  table(
    columns: (auto, auto, 1fr),
    table.header([Input], [Hash type], [Signature hash]),
    [0], [`0x1`], [#hex("f4ce6e37ab599bcd9c770d086c79749a77f99e4a50e774caf5ff50a123feff91")],
    [0], [`0x2`], [#hex("03319bed79cbb29b3c6fe90e4ff6e301071ddeb3568d16462ca5ffeed787d44b")],
    [0], [`0x3`], [#hex("e8fb9b72477a691a3c5c05aa4147a3fb5feaa4e43940ead1107ef94de9392cd4")],
    [0], [`0x81`], [#hex("4a1ecb30301eb4a7445ffca36202deda5f9552479fd2b223e3589f8738dbbde3")],
    [0], [`0x82`], [#hex("487f799838a05a534aa50daa92487e17c2715cc1ada7ce48c3a9fa052d05740f")],
    [0], [`0x83`], [#hex("e2e9e2e61df3dc7a668dc0418f5e1fa4d56f77d2dd2a8a427780d8bc423e54f3")],
    [1], [`0x1`], [#hex("901d5f6eac2d838d4ca1f3cc5a4ea4e2c10394ac507a7a2bb891958412d03871")],
    [1], [`0x2`], [#hex("93deae66a64e67888a1a03a319923cd3f948f27a375ed00d926ac19365b3fa4d")],
    [1], [`0x3`], [#hex("4641bb9be1f590a5cae964b188317cf168e158d24cfa27c7280941c684e42dc2")],
    [1], [`0x81`], [#hex("9df281682b102567a25fb8d3ca09f392efe5ee5499d8c12c0254974c05b070c5")],
    [1], [`0x82`], [#hex("93c4e51c4dc384c723940f0b64f4ef450dee23d12f9806516d83470ea2fa399c")],
    [1], [`0x83`], [#hex("d71ccf15b435685367f77257aef4ac96a959838c42d4164de2a795da0a9254bb")],
  ),
) <tab:script-vec-sighash>


The `SIGHASH_ALL` prefix hash equals the transaction hash, as stated in
@sec:script-sighash. In the `SIGHASH_SINGLE` vector for input 1, output 0
appears blanked (`ff…ff`, version `0000`, script length `00`) and input 0's
sequence is 0. Signing input 2 of a two-output transaction with
`SIGHASH_SINGLE` has no defined hash (@rule:script-sighash-single); dcrd's
`txscript/testdata/sighash.json` contains such cases, together with real
mainnet transactions and undefined hash types, and all of its entries are
reproduced by @alg:script-sighash.

=== Signed Spends

#vector[Signed pay-to-pubkey-hash spend (input 0 of the sample transaction)][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Private key], [#hex("0000000000000000000000000000000000000000000000000000000000000001")],
    [Public key (compressed)], [#hex("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")],
    [HASH160 of public key], [#hex("e280cb6e66b96679aec288b1fbdbd4db08077a1b")],
    [Public key script], [#hex("76a914e280cb6e66b96679aec288b1fbdbd4db08077a1b88ac")],
    [Signature hash (ALL)], [#hex("5a5f06a3652928aae830f38a45325564e1973fb10073ef671df0be1e69466331")],
    [Signature element], [#hex("3045022100a944fc7a28deab0b5c3f07b834995b2d2d5f42d708d0d7a04e3bec572c5779b202202d2730e2e9116305e8e731c7de302e11f43c2e9f1d87e19dd21d8c165175bab001")],
    [Signature script], [#hex("483045022100a944fc7a28deab0b5c3f07b834995b2d2d5f42d708d0d7a04e3bec572c5779b202202d2730e2e9116305e8e731c7de302e11f43c2e9f1d87e19dd21d8c165175bab001210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")],
    [Result (consensus flags)], [valid],
    [Same, one bit of $R$ flipped (a bit that leaves the DER encoding valid)], [invalid: `ErrEvalFalse` (`OP_CHECKSIG` pushes false)],
    [Same, hash type byte `04`], [invalid: `ErrInvalidSigHashType` (encoding failure)],
  )
]

#vector[EC-Schnorr-DCRv0 via `OP_CHECKSIGALT` (type 2, same key)][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Public key script], [#hex("210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179852be")],
    [Signature hash (ALL)], [#hex("99b24bd56eb2ff75a229d24a2a0d11f3025380add7655abce1e64a2fe5ceebf4")],
    [Signature script], [#hex("415326e2256467605135e786593379842f6087245aa4fcd1fa428849e20a8cb412d59effa4e8366ebe1cfbc7bac65a04e1aa9946e0ec4b10e154800e05edcdee5a01")],
    [Result (consensus flags)], [valid],
  )
]

#vector[Ed25519 via `OP_CHECKSIGALT` (type 1)][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Public key script], [#hex("204cb5abf6ad79fbf5abbccafcc269d85cd2651ed4b885b5869f241aedf0a5ba2951be")],
    [Signature hash (ALL)], [#hex("d9fbdf699eafab052dad4c7c873444809717dd3643329adbe6e2c043c7b869c3")],
    [Signature script], [#hex("410a299ecbc9e4800db91797d9090b21fdd76aba7fcab02c5dba370cc5ef4b79472705d52fe57bfe9ed7a034663cc0301c191006e2790f134a38b2bb77ef57fc0101")],
    [Result (consensus flags)], [valid],
  )
]

#vector[2-of-3 multisignature, bare and through P2SH][
  #table(columns: (auto, 1fr), table.header([Item], [Value]),
    [Private keys], [1, 3 and 6 (as 32-byte big-endian scalars); signatures by keys 1 and 6],
    [Public key script], [#hex("52210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f817982102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f92103fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a146029755653ae")],
    [Signature script (no dummy element)], [#hex("483045022100f5600c0a319d9d71df82ccbee4d0dd08a6a1b9aa840b29700b86cecf4660ad1f022030475c9aa791e59d0ff7cb08df2112743fe28886127ea9d9ed12a9e3b21bb6a00147304402206194d7eecb75ef075cda4e46d50bf66caef91350b12ccc767dd13e2d7f7c2669022046f8c544e3c4a4cb031f8058be3bc2882fd2b9c556f9fad200df758b3ef165e201")],
    [Result], [valid],
    [Signatures in reverse order], [invalid: `ErrEvalFalse`],
    [With a leading `OP_0` dummy], [invalid under consensus flags: `ErrCleanStack` (valid without the clean-stack flag)],
    [P2SH public key script], [#hex("a914f86b5a7c6d32566aa4dccc04d1533530b4d64cf387")],
    [P2SH signature script], [#hex("483045022100f5600c0a319d9d71df82ccbee4d0dd08a6a1b9aa840b29700b86cecf4660ad1f022030475c9aa791e59d0ff7cb08df2112743fe28886127ea9d9ed12a9e3b21bb6a00147304402206194d7eecb75ef075cda4e46d50bf66caef91350b12ccc767dd13e2d7f7c2669022046f8c544e3c4a4cb031f8058be3bc2882fd2b9c556f9fad200df758b3ef165e2014c6952210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f817982102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f92103fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a146029755653ae")],
    [P2SH result], [valid; imprecise signature operations 0 + 0, precise (P2SH) count 3],
  )
]


=== Lock-Time Opcodes

In @tab:script-vec-lock the public key script is the listed opcode sequence
followed by `OP_DROP OP_1`, the signature script is empty, and the consensus
flags of a block with all agendas active are used.

#figure(
  caption: [`OP_CHECKLOCKTIMEVERIFY` and `OP_CHECKSEQUENCEVERIFY`],
  table(
    columns: (auto, auto, auto, auto, 1fr),
    table.header([Script], [Tx ver.], [Lock time], [Sequence], [Result]),
    [`100 CLTV`], [1], [100], [`0`], [valid],
    [`101 CLTV`], [1], [100], [`0`], [`ErrUnsatisfiedLockTime`],
    [`500000000 CLTV`], [1], [100], [`0`], [`ErrUnsatisfiedLockTime` (kind mismatch)],
    [`100 CLTV`], [1], [100], [`ffffffff`], [`ErrUnsatisfiedLockTime` (input final)],
    [`-1 CLTV`], [1], [100], [`0`], [`ErrNegativeLockTime`],
    [`4294967295 CLTV`], [1], [4294967295], [`0`], [valid (5-byte operand)],
    [`549755813887 CLTV`], [1], [4294967295], [`0`], [`ErrUnsatisfiedLockTime`],
    [`10 CSV`], [2], [0], [`0000000a`], [valid],
    [`11 CSV`], [2], [0], [`0000000a`], [`ErrUnsatisfiedLockTime`],
    [`10 CSV`], [1], [0], [`0000000a`], [`ErrUnsatisfiedLockTime` (version)],
    [`2147483648 CSV`], [1], [0], [`0000000a`], [valid (disable bit in operand)],
    [`10 CSV`], [2], [0], [`8000000a`], [`ErrUnsatisfiedLockTime` (disable bit in input)],
    [`4194314 CSV`], [2], [0], [`0000000a`], [`ErrUnsatisfiedLockTime` (kind mismatch)],
    [`4194314 CSV`], [2], [0], [`0040000a`], [valid],
    [`4294967306 CSV`], [2], [0], [`0000000a`], [valid (bits above 31 ignored)],
    [`-1 CSV`], [2], [0], [`0000000a`], [`ErrNegativeLockTime`],
  ),
) <tab:script-vec-lock>

=== Execution Behaviour

@tab:script-vec-exec gives representative cases. Scripts are written in the
short form of dcrd's test data: a decimal number is its minimal push, `'s'`
pushes the ASCII bytes of `s`, `0x…` inserts raw bytes, `<…>{k}` repeats the
enclosed tokens $k$ times, `'b'{k}` pushes a single element of $k$ copies, and
names are opcodes without the `OP_` prefix. An entry number refers to the
zero-based position in `txscript/testdata/script_tests.json`; the other rows
were run directly. Unless noted, no flags are set and the script version is 0.

#figure(
  caption: [Script execution vectors],
  table(
    columns: (auto, auto, auto, 1fr),
    table.header([Entry], [Signature script], [Public key script], [Result]),
    [541], [`0`], [`IF 'b'{2049} ENDIF 1`], [`ErrElementTooBig` (unexecuted push)],
    [542], [`0`], [`IF <NOP>{256} ENDIF 1`], [`ErrTooManyOperations` (unexecuted ops count)],
    [2239], [`0`], [`IF 0x50{255} ENDIF 1`], [valid (`0x50` is not counted)],
    [589], [`0`], [`IF ELSE 1 ELSE VERIF ENDIF`], [`ErrReservedOpcode`],
    [1838], [`0`], [`IF CODESEPARATOR ENDIF 1`], [`ErrDisabledOpcode`],
    [—], [`1`], [`0 IF VER ENDIF`], [valid (`OP_VER` unexecuted)],
    [547], [`0 IF 0x4c 0x00 ENDIF 1`], [(empty)], [valid (unexecuted non-minimal push)],
    [389], [`0x4c 0x00`], [`DROP 1`], [`ErrMinimalData`],
    [413], [`0x01 0x00`], [`1`], [valid],
    [433], [`0x01 0x00`], [`NOT DROP 1`], [`ErrMinimalData` (numeric use)],
    [524], [`1 0x01 0x80`], [`IF 0 ENDIF`], [valid (negative zero is false)],
    [606], [`1 0x05 0x0100000000`], [`VERIFY`], [valid (long boolean)],
    [508], [`0`], [`IF 0 ELSE 1 ELSE 0 ENDIF`], [valid (two `ELSE`s)],
    [543], [`1 IF`], [`1 ENDIF`], [`ErrUnbalancedConditional`],
    [1379], [`2147483647 DUP ADD`], [`4294967294 EQUAL`], [valid (5-byte result)],
    [1319], [`2147483647`], [`1ADD 1SUB 1`], [`ErrNumOutOfRange`],
    [1331], [`2 2MUL`], [`4 EQUAL`], [`ErrEvalFalse` (`OP_2MUL` is a no-op)],
    [1439], [`-7 3`], [`MOD -1 EQUAL`], [valid],
    [1484], [`1 31`], [`LSHIFT -2147483648 EQUAL`], [valid],
    [1485], [`1 32`], [`LSHIFT 0 EQUAL`], [valid],
    [—], [(empty)], [`-1 32 RSHIFT -1 EQUAL`], [valid],
    [1493], [`1 33`], [`LSHIFT 0 EQUAL`], [`ErrOverflowShift`],
    [—], [(empty)], [`65536 65536 MUL 0 EQUAL`], [valid (wrapping)],
    [920], [`'abcd' 3 1`], [`SUBSTR 'bc' EQUAL`], [valid],
    [925], [`'' 2147483647 2147483646`], [`SUBSTR '' EQUAL`], [valid],
    [2040], [(empty)], [`0 0 CHECKMULTISIGVERIFY DEPTH 0 EQUAL`], [valid],
    [2037], [`1`], [`<0 0 CHECKMULTISIGVERIFY>{255}`], [valid (255 operations)],
    [2038], [`1`], [`<0 0 CHECKMULTISIGVERIFY>{256}`], [`ErrTooManyOperations`],
    [2039], [`1`], [`<NOP>{3} <0 'a' … 't' 20 CHECKMULTISIGVERIFY>{12}`], [valid ($3 + 12 × 21 = 255$)],
    [1921], [`0`], [`0x21 <key 3> CHECKSIG`], [`ErrEvalFalse` (empty signature)],
    [—], [(empty)], [`3 CHECKSIGALT`], [valid (unassigned type)],
    [—], [(empty)], [`128 CHECKSIGALT`], [`ErrNumOutOfRange`],
    [—], [`'x' 'y'`], [`1 CHECKSIGALT NOT`, clean stack], [`ErrCleanStack` (`'x'` left behind)],
    [2246], [`1 3 DATA_2 ADD SSTX`], [`HASH160 DATA_20 0xdcbd…ff8f EQUAL`], [`ErrP2SHStakeOpCodes`],
    [2263], [`1 3 DATA_2 ADD TADD`], [`HASH160 DATA_20 0xdd89…fb05 EQUAL`, `TREASURY`], [`ErrP2SHStakeOpCodes`],
    [2267], [as 2263], [as 2263, no flags], [valid (`0xc1` is `OP_UNKNOWN193`)],
    [2088], [`NOP1`], [`NOP10`], [`ErrEmptyStack`],
    [—], [(empty)], [`RETURN`, version 1], [valid (not executed)],
    [—], [(empty)], [(empty), version 1], [`ErrEvalFalse` (construction)],
    [—], [`NOP`], [`HASH160 0x14 <20 zero bytes> EQUAL`, version 1], [`ErrNotPushOnly`],
    [—], [(empty)], [`0x4c`, version 1], [`ErrMalformedPush`],
  ),
) <tab:script-vec-exec>

For the P2SH output whose redeem script is the single byte `51`
(public key script #hex("a914f5a8302ee8695bf836258b8f2b57b38a0be14e4787")): the
signature script `01 51` is valid; `51`, `00`, the empty script and
`61 01 51` fail construction with `ErrNotPushOnly`; and `01 51 01 51` is valid
without the clean-stack flag but fails with it (`ErrCleanStack`).

=== Signature Operation Counts

#figure(
  caption: [Signature operation counts (treasury rules in effect unless noted)],
  table(
    columns: (1fr, auto, auto),
    table.header([Script], [Imprecise], [Precise]),
    [`DUP HASH160 <20> EQUALVERIFY CHECKSIG`], [1], [1],
    [`2 <K33> <K33> <K33> 3 CHECKMULTISIG`], [20], [3],
    [`0 CHECKMULTISIG`], [20], [20],
    [`17 CHECKMULTISIG` (17 is pushed as `01 11`)], [20], [20],
    [`16 CHECKMULTISIGVERIFY`], [20], [16],
    [`CHECKSIG CHECKSIGVERIFY CHECKSIGALT CHECKSIGALTVERIFY`], [4], [4],
    [`TSPEND`], [1 (0 without treasury rules)], [1],
    [`CHECKSIG 0x4c` (parse failure after the first opcode)], [1], [1],
    [`CHECKSIG 0x01 0xac` (`0xac` is push data)], [1], [1],
    [`0 IF CHECKSIG ENDIF`], [1], [1],
  ),
) <tab:script-vec-sigops>

=== Provably Unspendable Outputs

#figure(
  caption: [Provably unspendable outputs],
  table(
    columns: (auto, auto, auto),
    table.header([Amount], [Script], [Unspendable]),
    [0], [`51`], [yes],
    [1], [`6a`], [yes],
    [1], [`51 6a`], [no],
    [1], [`4c` (parse failure)], [yes],
    [1], [`51`], [no],
    [1], [(empty)], [no],
  ),
) <tab:script-vec-unspendable>

== Error Kinds <sec:script-errors>

@tab:script-errors maps every script error kind that can arise in consensus
validation to the rule that produces it. The kinds `ErrInvalidIndex`,
`ErrUnsupportedScriptVersion`, `ErrScriptUnfinished` and
`ErrInvalidProgramCounter` indicate misuse of the reference implementation's
interface and cannot arise from transaction data;
`ErrP2SHTreasuryOpCodes` is defined but never produced (treasury tags in
redeem scripts produce `ErrP2SHStakeOpCodes`); `ErrDiscourageUpgradableNOPs`
and `ErrNotPushOnly` from the push-only flag arise only under policy flags.

#figure(
  caption: [Script error kinds and the rules that produce them],
  table(
    columns: (auto, 1fr),
    table.header([Error kind], [Rule]),
    [`ErrMalformedPush`], [@rule:script-parse, @rule:script-construction, @rule:script-p2sh-eval],
    [`ErrScriptTooBig`], [@rule:script-construction],
    [`ErrNotPushOnly`], [@rule:script-construction],
    [`ErrP2SHStakeOpCodes`], [@rule:script-construction, @rule:script-p2sh-stake],
    [`ErrEvalFalse`, `ErrEmptyStack`, `ErrCleanStack`], [@rule:script-final, @rule:script-p2sh-eval, @rule:script-construction],
    [`ErrUnbalancedConditional`], [@rule:script-end-of-script, @rule:script-conditionals],
    [`ErrStackOverflow`], [@rule:script-stack-size],
    [`ErrDisabledOpcode`, `ErrTooManyOperations`, `ErrElementTooBig`], [@rule:script-opcode-processing, @rule:script-checkmultisig, @rule:script-cat],
    [`ErrReservedOpcode`], [@rule:script-opcode-processing, @rule:script-reserved],
    [`ErrMinimalData`], [@rule:script-minimal-push, @rule:script-numeric-operands],
    [`ErrNumOutOfRange`], [@rule:script-numeric-operands],
    [`ErrInvalidStackOperation`], [@sec:script-opcodes (all opcodes), @rule:script-pick-roll],
    [`ErrVerify`, `ErrEqualVerify`, `ErrNumEqualVerify`], [@sec:script-op-flow],
    [`ErrCheckSigVerify`, `ErrCheckMultiSigVerify`, `ErrCheckSigAltVerify`], [@sec:script-signatures],
    [`ErrEarlyReturn`], [@tab:script-flow-ops],
    [`ErrNegativeSubstrIdx`, `ErrOverflowSubstrIdx`], [@rule:script-substr, @rule:script-left-right],
    [`ErrNegativeRotation`, `ErrOverflowRotation`], [@rule:script-rotate],
    [`ErrNegativeShift`, `ErrOverflowShift`], [@rule:script-shift],
    [`ErrDivideByZero`], [@tab:script-arith-ops],
    [`ErrNegativeLockTime`, `ErrUnsatisfiedLockTime`], [@rule:script-cltv, @rule:script-csv],
    [`ErrInvalidSigHashType`], [@rule:script-hashtype],
    [`ErrSigTooShort` … `ErrSigHighS` (16 kinds)], [@rule:script-der],
    [`ErrPubKeyType`], [@rule:script-pubkey-encoding],
    [`ErrInvalidPubKeyCount`, `ErrInvalidSignatureCount`], [@rule:script-checkmultisig],
    [`ErrInvalidSigHashSingleIndex`], [@rule:script-sighash-single (fails only via `OP_CHECKMULTISIG`)],
  ),
) <tab:script-errors>
