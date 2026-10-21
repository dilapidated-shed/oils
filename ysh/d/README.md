# YSH in D

This directory is an independent D translation of YSH. The translation target is the language and its tests, not the generated C++ emitted by `mycpp`.

The translation remains incomplete. The latest host qualification ran all 1,119
cases in the 80 inherited YSH fixtures and the focused Grease alias fixture:
706 assertion matches, 413 failures. The unchanged original harness, fixture
hashes and per-case results are recorded in [PORTING.md](PORTING.md) and
[the qualification ledger](qualification/inherited-host-attribute-2026-10-21.tsv).

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
the earlier partial D runtime on Linux x86_64; that producer receipt has not
been rerun for the current continuation. These results do not qualify a managed
Grease package or discharge the remaining inherited-spec dependency.

The latest continuation adds real concurrent source pipelines and isolated
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

The `ysh-d` entrypoint enables `ysh:all` before applying CLI overrides. The same
binary, invoked as `osh-d`, supplies the reference's default OSH option state
for inherited tests that explicitly enable YSH features. This diagnostic mode
does not establish a complete OSH port. `shopt` prints and queries real option
cells, and scoped blocks unwind them across returns and errors.

Untranslated syntax continues to fail closed; each new feature should arrive with its corresponding YSH behavior tests rather than guessed scaffolding.

## Build and run

The acceptance compiler is the Mars/Icky-DMD line in `dilapidated-shed/ick`, with its matching pinned druntime and Phobos. The workflow in `.github/workflows/ysh-d.yml` reconstructs that toolchain from exact commits, compiles all translated modules directly with Icky DMD, runs their unittests, and then runs the CLI smoke cases.

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
