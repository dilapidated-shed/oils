# YSH in D

This directory is an independent D translation of YSH. The translation target is the language and its tests, not the generated C++ emitted by `mycpp`.

The translation remains incomplete. The November 19 `getopts` continuation
passes **58 CLI/module suites and 57 library suites**. Its strict paired gate
passes 28 unchanged original cases and 59 additional contracts in native D and
the actual minimal Oils reference. Three original reset expectations fail in
both implementations and remain visible in the full 31-case table. The new
contracts cover byte-oriented option clusters, arbitrary-precision option
indices, partial writes, readonly variables, typed arguments, temporary bindings,
redirection effects and child failure boundaries. The retained version,
environment, Kitchen consumer and repaired negation gates also pass.
The full local matrix records **898/1,119 native matches and 221 failures**,
two more matches than the preceding checkpoint, with no native regressions or
timeouts. The reference records 1,045 matches and 74 failures on this host;
one prompt fixture assumes its temporary path is below `/home`, which this
workspace does not satisfy. Shared read remains 62/64 native and 63/64 reference.
Exact source identities and compatibility results are recorded in
[PORTING.md](PORTING.md) and [the current host receipt](qualification/il0-getopts-2026-11-19/receipt.tsv).

Scoped extra descriptors now reach native builtins and external processes with
ordered duplication, nested restoration and closed-fd handling. Terminal read
supports silent input, prompts and unbuffered delimiter/count input; PTY tests
check restoration after normal input and a trapped exit. `read -t 0` follows the
reference readiness probe. Positive timeouts remain unimplemented in both D and
the retained reference. Native mapfile/readarray and unset shell-array expansion
complete the preceding input slice. Persistent `exec` redirections now own their
Files beyond the command scope. Actual native exec replacement preserves PID,
supports `--` and `-a`, and retains ignored signal dispositions. All six
unchanged shared exec cases pass through the final runtime and actual Oils.
The native PID test rejects a fork-and-wait imitation. Native `ulimit` now queries
and sets all seven retained resources, with reference units, soft/hard selection,
infinity and checked integer conversion. All 16 unchanged shared ulimit cases
pass in D. Kernel tests verify actual limits and SIGXFSZ enforcement in child
processes. Builtin output is flushed before the next command, and retained local
assignment operands preserve spaces and literal patterns. These results do not
qualify a complete shell or managed package. Native `time` now measures the
whole following pipeline in the current frame, prints the reference's fixed
real/user/sys report, and counts shell CPU without adding child CPU. Three
unchanged shared timing cases pass in both D and Oils. Native tests cover
status/control flow, keyword boundaries, redirection ownership, nonrecursive
lookahead and same-header here-document body selection. Native `times` now reports
cumulative self and reaped-child user/system CPU counters using the target's
POSIX tick rate and exact C header ABI. Its unchanged shared fixture passes in
both D and Oils. Native tests check real CPU work, cumulative totals, tick
conversion, argument evaluation and output failures. Native `umask` now queries
and sets the actual process mask, including numeric and symbolic modes. Its
current full 24-case fixture records 22 passes and the same two failures as the
retained reference: `-S` and `-p` are parsed but ignored there. The strict 22-case gate
passes in both implementations. Kernel tests check created file/directory modes,
fork/exec inheritance, source/subshell scope and restoration after ordinary parse
errors. Strict write-and-flush diagnostics now repair the shared reporter/`try`
boundary. Failed reporting unwinds inner redirects before the outer `try`
reports status 1, preserving previously seeded `_error` and `_status` registers.
The parsed `json`, `json8` and `pp` paths use the same builtin I/O boundary.
Unhandled raw CLI I/O exits 2. This qualifies the tested paths rather than every
manual builtin handler or complete stderr wording.

Native `shift` retains the reference's signed arbitrary-precision cursor,
including accepted negative counts, silent excessive-shift status 1 and
unchanged typed `ARGV`. Shell functions, source, eval and regex replacement save
or share the complete positional frame according to their reference scopes.
Braced indices stay arbitrary precision until cursor cancellation and actual
array bounds are checked, including indices beyond 2^64 and leading zeroes.
Native `getopts` now retains the original interpreter's global byte cursor,
including its non-resetting behavior when OPTIND or argv changes. It preserves
the reference's diagnostic, silent-mode, stale OPTARG and partial-write order.
The actual minimal reference accepts one trailing LF in a destination name
through its Python regex fallback; this scoped quirk is retained. A stale
cluster cursor's internal failure exits 1 without running EXIT traps, while an
ordinary readonly failure still runs them.

Simple commands now prepare expanded words and eager typed arguments once,
then evaluate redirect operands and install descriptors, then evaluate prefix
bindings and dispatch. Lazy arguments remain unforced. OSH temporary variable
frames and YSH ENV overlays follow their separate retained scope rules.
The next measured ordinary builtin gap is `hash -r`: D exits 3 for the
untranslated builtin while the actual reference returns 0.

The October 27 checkpoint's 39 CLI/module suites, 38 library suites, original
owner smoke and producer controls remain historical evidence. The final
November 19 runtime's actual Icky Lua producer and all thirteen controls pass.
The preceding reporter/shift and umask controls remain historical evidence. The
producer uses the exact pinned compiler and private verified GCC13 support
mounted at the original path inside a namespace with a read-only root. A clean
same-host rebuild reproduces the current executable bytes. Interactive
operation, full shared-shell parity, independent ai-ci acceptance and Cat Food
delivery remain incomplete; the binary stays
`ysh-d`.

## Source map

The implementation currently follows these sources on the Oils/Grease line:

- `core/value.asdl` — YSH data values: `Null`, `Bool`, `Int`, `Float`, `Str`, `List`, `Dict`
- `ysh/val_ops.py` — truthiness, scalar stringification, exact equality
- `ysh/expr_eval.py` — numeric coercion, arithmetic, `++`, lazy `and`/`or`, comparisons
- `ysh/func_proc.py` — initial D user-function declaration, call, default, and lexical-frame path
- `builtin/io_ysh.py:Write` and `spec/ysh-builtins.test.sh` — scalar output arguments and basic output options
- `builtin/io_osh.py:Echo` and `spec/ysh-builtins.test.sh` — ordinary output words and the `-n` option
- `ysh/grammar.pgen2` — literal syntax and operator precedence
- `frontend/lexer_def.py` — decimal integer/float spelling used for numeric string coercion

## Implemented in the first slice

- `null`, booleans, decimal integers, floats, single-quoted strings, and list literals
- arbitrary-precision D `BigInt` values
- unary `+`, unary `-`, and `not`
- `+`, `-`, `*`, `/`, `//`, `%`, `**`
- `++` for strings and lists; dictionary merge exists in the value/evaluator layer
- lazy `and` and `or`, returning operands as YSH does
- `<`, `>`, `<=`, `>=`, `===`, `!==`, including chained comparisons
- YSH numeric-string coercion such as `'40' + 2`
- YSH precedence for power: `-2 ** 2` is `-(2 ** 2)`
- YSH integer division/remainder rules: `//` truncates toward zero; `%` rejects a negative divisor
- YSH's rule that exact equality is not defined on `Float`
- positional user functions with definition-time immutable defaults, lexical capture, and `return (expr)`
- nested `if` / `else if` / `else` command blocks, including return flow from selected branches
- parenthesized or bare-expression `while` blocks with `break` and `continue`
- expression `for` loops over Lists, Dicts, and Ranges, including index/key/value bindings
- scalar words, `$var`/`$[expr]`, and `@List`/`@[expr]` through `write`, with `--sep`, `--end`, and `-n`
- common `echo` output with scalar substitutions and `-n`
- first conventional command-position `alias`/`unalias` support, including same-line visibility and recursive expansion guards
- concatenated literal/`$var` words and simple double-quoted variable substitution

## Deliberately not in this slice

The expression slice above was the original boundary. Later slices include
declarations and mutation, dictionaries, functions and procs, loops, word
substitution, external execution, ENV, pipelines, command and file redirections,
read/source/eval, and selected JSON/J8 and collection operations. The workflow
smoke sequence covers these implemented paths. It does not establish complete
YSH compatibility.

The first alias slice covers named-command/unalias behavior, not the complete
inherited alias grammar (including trailing-space expansion and every compound
context). The focused Grease spec's command condition and descriptor redirects
now execute unchanged. This focused transcript is **not** a full spec-suite pass
or proof of complete option-group semantics.

The remaining acceptance dependency and current source ownership are recorded
in [PORTING.md](PORTING.md). The D CLI now provides a nonexecuting `-n FILE`
path, but the inherited YSH behavior suite has not passed against it.
Conventional aliases must follow the Grease reference frontend;
readable spellings must remain separate from changes in runtime meaning.

The CLI now keeps `-c` program text separate from its following argument words.
With a file invocation, following words populate the global `ARGV` list and
`$0` retains the complete file path, including spaces. Script/stdin/`-c` modes
return the last command's status instead of unconditional success. The legacy
single-argument expression diagnostic remains available. These entrypoint
repairs do not establish complete Grease compatibility. The producer continuation
now implements `set -e/-u/-o pipefail` and their disabling forms, command
conditions and negation, ordered descriptor redirections, expression command
substitution, and braced parameter/pattern removal. The unchanged FP IL-0
qualifier and its thirteen runtime/source-substitution controls execute through
the partial D runtime on Linux x86_64; the October 25 continuation reruns the
real producer and all thirteen controls successfully. These results do not qualify a managed
Grease package or discharge the remaining inherited-spec dependency.

The October 25 continuation adds native batch jobs, wait/fork builtins,
deferred traps, source-line tracking, and quote-aware IFS/glob expansion.
The combined inherited run is 799 matching cases and 320 failures out of 1,119,
with every match from the concurrent 777-case checkpoint preserved. The port
remains incomplete and named ysh-d; see [PORTING.md](PORTING.md).

Earlier continuations add real concurrent source pipelines and isolated
command substitutions, reference-derived option metadata and scoped option
cells, YSH startup defaults, expression-context failure propagation, and
distinct proc-status versus function-value returns. `ENV.PATH` and the exact
child environment now control native execution. The option table describes
reference availability; storing an option cell is not a claim that all of its
parser or runtime consumers have been translated.

The case continuation adds both YSH and retained shell-style case syntax,
lazy expression/word patterns, fragment-level quoting and POSIX fnmatch, and
an initial Eggex AST/ERE path with captures and conversion functions. All 18
unchanged case fixtures pass. The unmodified list/math standard-library files
now load. A subsequent continuation adds first-class Eggex values, frozen
splices/converters, regex comparisons, search/leftMatch and named capture
methods. Case acceptance does not qualify the entire regex subsystem.

The data-output continuation adds reference JSON/J8 indentation and
type/cycle handling, toJson/toJson8, diagnostic cycle markers, and measured
pretty printing for translated data values and ranges. Expression display and
`pp value` share that printer. The inherited function fixture now passes all
26 cases. The subsequent decoder implements strict JSON and J8 input, error
positions, and codec functions. Captured-frame Places and here-documents now
support the shared read paths. JSON/J8 passes 59/64 inherited cases; retained
shell arrays/arithmetic and objects still leave failures in that fixture.
Identity comparisons, glob comparisons and floatsEqual are translated; the
remaining heap-value display, terminal styles and value variants need work.
The regex fixture passes 29/29, regex APIs 40/40, and strings 29/29. Native
double-bracket conditions, retained if/then/fi, typed/named/block proc arguments,
captured Command/Expr values, and lazy replacements now support those cases.
Objects have own properties, prototype lookup, bound methods, and invokable
procs; 13/15 object assertions match. The eight context cases pass. Retained
shell arrays have distinct values and assignment/expansion paths. These are
still partial subsystems: full arithmetic, shell grammar and builtins,
namespaces/modules, reflection, I/O iteration, interactive behavior, and
independent acceptance remain open.

The retained-control continuation adds shell functions, for/while/until loops,
dynamic shell-call frames, shared status/capture/argument state, deferred
function redirections and here-documents, and restoring cd blocks. Definition
checking follows the reference's var/setvar rules and nesting restrictions;
annotation syntax is parsed without adding type enforcement. Control flow
matches 9/9 inherited cases, assignment 18/22, procs 31/38 and scope 9/26.
Those counts leave the larger translation and inherited acceptance incomplete.

The I/O continuation adds isolated stdout/stderr capture, shell-filtered and
libc glob APIs, eval bindings and ordered frame capture, lazy typed arguments,
parseCommand, stdin iteration, and descriptor-based raw/byte reads. The I/O
method fixture matches 9/9 cases, eval 17/31, for 19/20 and assignment 19/22.
The test-only Python reference build is now available to fixtures that
explicitly request it; it is separate from the D language-execution path.

The attribute continuation preserves capitalized-command attribute blocks through
deferred execution and translates the reference's byte-based IFS splitter.
The split/shSplit/maybe functions, ordered pipeline status and frame-variable
display now execute natively. All 1,119 inherited cases were rerun with no
regression: eval matches 26/31, function builtins 9/10 and procs 32/38.

The directory continuation adds shvar binding restoration and a shared native
directory stack for cd blocks, pushd, popd and dirs. Pwd uses the shell's saved
logical directory. Shell special parameters now share native evaluation between
words and expressions. Eval matches 28/31 and scope 12/26; the full inherited
run and unchanged repeats retain all prior matches. Two initial timeouts and
their same-limit whole-fixture repeats are preserved in the ledger.

The `ysh-d` entrypoint enables `ysh:all` before applying CLI overrides. The same
binary, invoked as `osh-d`, supplies the reference's default OSH option state
for inherited tests that explicitly enable YSH features. This diagnostic mode
does not establish a complete OSH port. `shopt` prints and queries real option
cells, and scoped blocks unwind them across returns and errors.

Untranslated syntax continues to fail closed; each new feature should arrive with its corresponding YSH behavior tests rather than guessed scaffolding.

## Build and run

The current native module loader embeds the original `stdlib/` resources as
text through D import expressions. Builds require `-Jstdlib` in addition to
the source and pinned runtime import paths. The workflow includes this flag
and treats changes under `stdlib/` as material build inputs. The language
implementation remains incomplete; the module fixture matches 26/29 and the
retained Lua producer and all thirteen controls pass on this host checkpoint.

The acceptance compiler is the Mars/Icky-DMD line in `dilapidated-shed/ick`, with its matching pinned druntime and Phobos. The workflow in `.github/workflows/ysh-d.yml` reconstructs that toolchain from exact commits, compiles all translated modules directly with Icky DMD, runs their unittests, and then runs the CLI smoke cases.

The native CLI's `--version` output embeds the first line of the source-owned
`oils-version.txt` and explicitly names this partial D implementation. Builds
therefore require `-J.` as well as `-Jstdlib`. The
[version attempt](../../examples/autogenerated/native-cli-version/attempt.md)
records the actual retained-consumer failure and the focused source/host gate;
version output does not establish whole-language or managed-package admission.

LDC remains a bootstrap compiler for building Icky DMD; it is not the compiler used to accept the translated YSH source.

A successful CLI smoke prints:

```text
7
```
The command-line printer is only a stable diagnostic representation for the D port. It is not yet the full YSH/J8 display layer.

## Integer representation

`core/value.asdl` specifies `BigInt`, while the current Python/C++ `mops` implementation still uses an int64-sized representation and explicitly says it wants to become heap-allocated integers. This D slice uses `std.bigint.BigInt` directly. That is closer to the declared value model, but it means overflow-boundary parity with the current implementation is a question for explicit compatibility tests rather than an accidental property of the port.

## Translation rule

When behavior is unclear, prefer this order of evidence:

1. YSH specification and grammar
2. YSH/OSH spec tests
3. typed Python implementation
4. generated/native C++ as implementation evidence

Do not mechanically transliterate generated C++ into D.
