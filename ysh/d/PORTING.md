# Whole-hog YSH -> D translation

The target is the complete YSH implementation in D.

The expression evaluator in this branch is only the first translated slice.  It is not a reduced YSH, a compatibility shim, or the intended endpoint.

## Definition of done

The D executable must be able to run YSH without importing, embedding, spawning, or falling back to the Python implementation or the mycpp-generated C++ implementation.

For the YSH execution path, every reachable implementation component must end in one of these states:

- translated to D;
- generated directly as D from the same declarative source used by Oils (ASDL, grammar tables, option definitions, etc.); or
- left as an explicit operating-system/library boundary such as POSIX/libc/readline.

"Implemented enough for the current tests" does not count as complete translation.

## Compatibility before redesign

The first pass preserves upstream YSH syntax and behavior, including spellings we may not want in the later language.

For example, upstream `===` and `!==` belong in compatibility tests during the translation.  They must not silently become the preferred syntax of ICKY/ICK or of a later character-rich frontend.  Native spellings such as `≟` and `≠` are a separate frontend decision after semantic parity is explicit.

The evaluator should receive semantic operator IDs rather than punctuation strings once the lexer/parser translation reaches that layer.

## Translation surface

The port is not limited to `ysh/`.  YSH deliberately shares substantial shell machinery with OSH, so the complete D YSH executable must translate the shared path it actually reaches.

### Entry and shell assembly

- `bin/ysh`
- YSH dispatch in `bin/oils_for_unix.py`
- `core/shell.py`
- main loop, startup, errors, options, and interactive setup reached by YSH

### Generated language/runtime data

Translate or generate D equivalents for the declarations YSH reaches, including:

- `core/value.asdl`
- `core/runtime.asdl`
- `frontend/syntax.asdl`
- generated IDs, option/builtin IDs, argument types, and related tables

### Lexing and parsing

- YSH expression lexer rules
- `ysh/grammar.pgen2`
- `ysh/expr_parse.py`
- `ysh/expr_to_ast.py`
- the command/word parsing machinery YSH shares with OSH
- source locations and parse errors

The completed D program must parse ordinary YSH source itself.  Feeding a Python-produced AST to D is not the endpoint.

### YSH evaluator/runtime

Every implementation module under `ysh/` is in scope:

- `expr_eval.py`
- `expr_parse.py`
- `expr_to_ast.py`
- `func_proc.py`
- `regex_translate.py`
- `val_ops.py`

Build-generation scripts may be replaced by D-native build/generation machinery rather than transliterated if they are not part of the running shell.

### Shared execution machinery

Anything reached by the YSH shell remains in scope even when its historical home is `osh/` or `core/`, including:

- command evaluation
- word evaluation
- variable/state/frame handling
- functions, procs, closures, and control flow
- redirections and file descriptors
- pipelines, processes, jobs, signals, traps
- globbing and splitting where YSH exposes them
- command and expression substitution
- source/eval
- environment handling
- options
- modules and namespaces

This is shared implementation code, not a reason to defer the feature to the later OSH port.  The later OSH translation may reuse the D machinery, but YSH must be complete on its own path first.

### Builtins and methods

All builtins, functions, and methods exposed by YSH are in scope, including the YSH-specific modules and the OSH-origin builtins that YSH intentionally retains.

### Data and display languages

The portions of J8/JSON/data-language code used by YSH, value printing, diagnostics, and source-location reporting are in scope.

### Interactive shell

YSH completion, prompt handling, history/readline integration, and interactive execution are part of the whole translation.  A batch-only D interpreter is not the endpoint.

## Test acceptance

The acceptance target is the existing YSH behavior suite, not a new miniature test suite invented for the D port.

At minimum:

- every `spec/ysh-*.test.sh` test must be runnable against the D executable;
- shared spec tests exercised by upstream YSH must also run against D;
- relevant unit tests for translated modules need D equivalents or differential coverage;
- Python/C++ and D outputs/statuses are compared where the specification leaves behavior unclear.

Temporary expected failures must be listed explicitly with the untranslated subsystem that causes them.  The list must trend to zero.

## Port ledger

Each PR should mark translated surface in a ledger rather than implying completion from a working vertical demo.

Current state:

- [x] D package and executable test harness
- [x] first data-value representation
- [x] first expression evaluator slice
- [x] shared D lexer foundation used by expression and command parsing
- [x] frame/cell state with global, local, and lexical-enclosure lookup
- [x] first command parser entry for var/const/setvar/setglobal
- [x] VarDecl and ordinary Mutation evaluation, including destructuring/swaps
- [x] scope-aware, two-phase variable/list/dict mutation places
- [x] compatibility equality tokens normalize to semantic comparison operators
- [x] first user-function path: declaration, positional/default binding, lexical capture, calls, and `return (expr)`
- [x] first branching command path: `if`, `else if`, `else`, nested blocks, and returned values
- [x] first loop-control path: `while`, `break`, and `continue` with nested command blocks
- [x] first expression-iterator path: `for` over List, Dict, and Range values with index/key/value bindings
- [x] first literal shell-word iterator path: `for` over static words with optional index binding
- [x] first builtin output path: scalar `write` words, `$var`/`$[expr]`, `@List`/`@[expr]`, `--sep`, `--end`, and `-n`
- [x] common `echo` output path with scalar words and `-n`
- [x] first command-position alias/unalias slice, with newline-bound visibility and cycle guard
- [x] concatenated literal/scalar-substitution words and simple double-quoted `$var` substitution
- [ ] complete ASDL/data-model coverage
- [ ] full YSH lexer
- [ ] full YSH expression parser
- [ ] command/word parser path
- [ ] complete expression evaluator
- [ ] variables, cells, frames, scope, environment
- [ ] assignment and places
- [ ] calls, functions, procs, closures
- [ ] objects, methods, prototypes
- [ ] regex/Eggex
- [ ] command evaluation and word evaluation
- [ ] substitutions
- [ ] redirections, pipelines, processes, jobs, signals, traps
- [ ] all YSH-visible builtins/functions/methods
- [ ] modules/namespaces/source/eval
- [ ] J8/JSON and display/error path
- [ ] completion, prompt, history, interactive shell
- [ ] full YSH spec-suite differential run
- [ ] zero Python/C++ fallback on the YSH execution path

Only the final item closes the whole-hog translation.

## Current host checkpoint: decoding, Places and here-documents, 2026-10-21

The unchanged inherited harness reports **435 assertion matches and 684
failures across all 1,119 cases**. This is 47 additional matches over the
published source `ba5a2f7f817320b4204e08df0b4fcfdeac39f459`, with no previous
match regressed after repeating the timeout described below. The complete D
runtime remains unfinished. Shared shell specs, interactive execution,
independent AI-CI and managed admission remain unqualified.

Translated `data_lang/j8.py` decoding directly to D: JSON/J8 objects, lists,
scalars, strict numeric tokenization and reference integer bounds, J8 comments
and string prefixes, binary escapes, Unicode validation, surrogate pairs and
unpaired JSON escapes, complete-input checks and positioned errors.
`json read`/`json8 read` return status 1 on decoding failure and leave the
destination unchanged. `fromJson()`/`fromJson8()` raise structured status-4
errors with byte positions. All 57 passing JSON/J8 cases use the original
64-case fixture; seven failures still reach retained shell arithmetic/arrays,
Eggex, objects and the upstream excessive-nesting case.

Places capture the current frame independently of intervening function calls.
`read --all`/`read --line`, the JSON readers and `Place.setValue()` use the
captured frame. The reference's disabled dangling-place check has not been
silently enabled. Container places remain outside the translated surface.

The command lexer records here-document delimiters, removes delimiter quoting,
and preserves bodies as source data rather than tokenizing their contents as
commands. Quoted/unquoted bodies, tab stripping, ordered documents and pipeline
fragments share this path. Expansion occurs when applying the redirection;
parse-only mode validates without evaluating substitutions. This does not
establish a complete shared shell lexer or arbitrary descriptor handling.
ANSI-quoted words/expressions, the missing common J8 escapes and JSON encoding
of unpaired surrogate bytes are also translated. `join()` now shares the
reference list-stringification behavior. ASDL data/cell diagnostics reuse
measured layout and preserve their separate field notation.

Pinned Icky DMD compiles the exact D source tree
`03f8d61f24cc7b5fe49333a192be7c75cdb4ce0c`; the host executable has SHA-256
`baebdf9e19f6c17dd7bbe15e000871e360ef64f73a54defb9bfd7446166a4f66`.
All 18 CLI/module test suites and 17 library suites pass. The full owner smoke
sequence is checked with its declared runner temporary directory.

The first concurrent inherited run timed out in `ysh-expr-bool:4`; a separate
full-fixture retry also timed out. The previous binary and the current binary
both match the unchanged case in isolated diagnostics, and the current binary
subsequently passes the original three-second limit in both an isolated case
and a full-fixture repeat. The initial timeout results are retained; the final
ledger uses that full-fixture repeat. No timeout is reclassified as a pass.

See [host qualification](qualification/inherited-host-decode-2026-10-21.tsv),
[suite results](qualification/inherited-suites-decode-2026-10-21.tsv), and
[case results](qualification/inherited-cases-decode-2026-10-21.tsv).

## IL-0 acquisition continuation, 2026-10-19

The retained D translation has been rebuilt on Ubuntu 24.04 x86_64 through the
existing exact Icky DMD pin `ccf61ab82659b9eadee2d05b489fb195956cef88`, matching
druntime `74917954b53f7f35b13e61b4438c7253834929ed` and Phobos
`7b158eba80b97dfcdd8931bcaea1ad0ca35ceb95`. The isolated compiler bootstrap uses
LDC 1.36.0; it does not compile the maintained translated shell directly. The
actual final D executable's inspected dynamic dependencies contain no C++
runtime. This finding does not promote an incomplete D interpreter to Grease.

Executing the actual IL-0 qualifier exposed an earlier CLI defect: a file with
arguments was parsed as an expression. Also, `-c` joined later argument words
into executable source. The entrypoint now binds only the designated source
argument, initializes global `ARGV` and separate `$0`, and returns the final
command status. Quoted/unquoted script identities preserve spaces. Successful
`echo`/`write` clear a preceding failure status after expanding their arguments.
This repair has CLI/module tests and the unchanged owner CLI smoke sequence.

The earlier acquisition attempt reached its first statement and failed with
`ysh-d: set: Executable file not found: set`. The next required translation is
the shell's own `set` builtin, including real `errexit`, `nounset` and `pipefail`
behavior, followed by whatever later consumer/inherited-spec failures actual
execution demonstrates. Ignoring those options or routing source to another
shell is not a repair. The parse-only CLI and all untranslated surfaces below
remain open; full inherited-spec compatibility has not passed. No Cat Food
default, complete Grease package, managed installation or IL-0 admission is
claimed. Partial CI artifacts retain 90 days of diagnostic availability and
include their dependency inspection instead of expiring after seven days.

The unchanged inherited Grease alias case also fails: its ordinary command
condition and descriptor redirections reach `multiple redirects in one command
are not translated yet`. Its extracted statements have not been simplified to
claim a pass. Scoped local evidence is retained in
[`qualification/il0-acquisition-2026-10-19.tsv`](qualification/il0-acquisition-2026-10-19.tsv).

The checked items are initial executable slices, not completion of the unchecked
subsystems. The current branch also implements initial proc positional/rest and
ARGV binding, named/rest func parameters, external commands with child ENV,
command substitution, pipelines, whole-command file and here-string redirects,
source/eval, read, echo escape handling, and selected JSON/J8 and collection
operations. These paths are exercised by the existing workflow smoke sequence;
they do not establish full upstream semantic parity.

## Current acceptance boundary

The current Grease reference is Oils `grease/main`, selected by Grease's
`source/` gitlink. Keep aliases and readable frontend spellings there, in
`frontend/option_def.py`, `frontend/lexer_def.py`, and the inherited parser.
D is a translation backend for that same reference, not a second redesigned
language surface. Its first compatibility pass must preserve the reference
alias behavior, including `spec/grease-alias.test.sh`, rather than inventing
different declaration semantics.

The existing host qualification compiled the branch with pinned Icky DMD,
passed nine module test suites, and passed the full existing CLI smoke sequence:
[2026-10-06 receipt](https://github.com/dilapidated-shed/oils/actions/runs/37470158621).
The bounded repairs corrected a D identifier shadow, subprocess stream ownership,
redirect lifetime, and shared double-quoted expression interpolation.

The surviving whole-shell runtime acceptance dependency is the inherited YSH
spec suite running against this D executable. The earlier immediate entrypoint
gap, nonexecuting `-n FILE`, is repaired in the continuation below. The parser
does not execute source or pass its parse to Python/C++. Full parser and runtime
compatibility remain open; no paired benchmark acceptance follows from this
bounded repair.

The full parser, alias expansion, options, proc/function signature and closure
parity, jobs/signals/traps, modules, regex/Eggex, interactive behavior, and
mutation-sensitive iteration still require inherited-spec coverage. Smoke tests
do not discharge this dependency. No completed `greased` or replacement for
ordinary YSH is claimed.

A bounded D alias slice handles definition, invocation, listing, removal and self-recursion suppression for unquoted command names. It preserves same-line parse visibility. Command conditions and standard-descriptor redirects now execute the unchanged focused alias case; trailing-space/compound alias expansion and option-group parity still need inherited-spec acceptance.

The alias reference is now integrated from Oils grease/main
dd39aa720c386f9ad007fb96f6475c6afbce297c, the merge of
[dilapidated-shed/oils PR #6, “Grease: keep command aliases available”](https://github.com/dilapidated-shed/oils/pull/6).
This brings the reference implementation and exact focused spec into this branch;
it does not pretend the D backend already passes that spec.

The tested partial D executable at 6db04a02228ad4328f75f79c0ad477c02723767c
passed the pinned compiler/runtime, nine module suites and full existing smoke
sequence in [the artifact-producing receipt](https://github.com/dilapidated-shed/oils/actions/runs/37475808606).
The actual paired benchmark gate passes the empty program on both runtimes,
then rejects D on `--ast-format none -n FILE`: exit 3, unexpected 'none' at
byte 13. C++ passes that parse-only case. The benchmark's hashes and result are
preserved in [dilapidated-shed/grease PR #45, “Integrate current aliases and greasecpp versus greased benchmarks”](https://github.com/dilapidated-shed/grease/pull/45).
No timing or runtime winner follows from this failed compatibility gate.

## IL-0 producer continuation, 2026-10-19

The existing D implementation now executes the unmodified
`qualify-icky-lua.grease` and `negative-controls.grease` from Flexible Pipes
`68c53d0daa64ec998701060abaaf225752ea1e93`. This is bounded diagnostic host
execution through a partial D candidate, not managed Grease admission.

The translated surface added here is:

- actual enabling/disabling of errexit, nounset and pipefail; conditional and
  negated-command exemptions; nested suppression and proc propagation;
- command-form `if` conditions and quoted executable names;
- ordered input/output/error redirection and descriptor duplication, preserving
  the distinction between `>file 2>&1` and `2>&1 >file` and restoring streams;
- command substitution in expressions and braced parameter/pattern removal;
- URL and linker-option words without turning command commas into expression
  tuples when negating a command.

Eleven module/CLI test suites cover these cases; the existing owner CLI smoke
sequence also passes. Actual pinned ICK builds the modified Lua interpreter and
embedded object, both run the literal symbolic probe, the embedded bytes match,
and all thirteen retained negative controls pass, including same-version stock
Lua, hidden source changes, forged receipts and relocation with spaces. The
focused inherited Grease alias case executes unchanged and yields its expected
transcript. This does not prove that the still-partial `shopt` implementation
enables every option in `ysh:all`.

At that producer checkpoint, the whole-shell boundary remained open: parse-only
execution, concurrent source pipelines and command-substitution isolation were
still missing. Those three paths now have D implementations and bounded tests,
as described below. The inherited suite has not passed. Complete options and
aliases, jobs, signals, traps, modules, regex and interactive behavior remain
unfinished. Unsupported `set` flags/names and descriptor operations fail rather
than becoming no-ops.

Keep the executable named `ysh-d`. No complete Grease package, static/transitive
C++ exclusion verdict by independent AICI, Cat Food admission, managed FP
receipt, consumer migration, Android or physical-device PASS follows from these
host results. The retained runtime branch remains the sole successor; do not
reopen or merge the parked PR as completed whole-hog translation on this evidence.

## Parser, process and option continuation, 2026-10-20

The current continuation compiles directly with the same pinned Icky DMD,
druntime and Phobos. A fresh disposable Ubuntu 24.04.3 Linux x86_64 host passed
14 CLI/module suites, 13 library-module suites, generated-option consistency
and the owner workflow's smoke sequence. Two smoke cases now explicitly disable
errexit while inspecting an expected failed-command status; the alias smoke
handles a missing alias in a command condition. Their old assumptions depended
on the previous no-op `shopt`. The inherited fixtures and their assertions were
not edited.

The translated behavior includes:

- a shared nonexecuting parser entry for file, stdin and `-c`, including
  uncalled bodies, untaken branches, defaults and nested substitutions;
- short-circuit command lists, command-form while conditions and final status;
- concurrent POSIX producer processes, streaming pipes, last-stage bindings,
  rightmost pipefail status, SIGPIPE normalization and child reaping; a proc
  still stops at its first failed command within each stage under errexit;
- process-isolated command substitution, with concurrent draining and no
  variable/container/cwd leakage;
- native execution using the shell's actual `ENV.PATH` and environment,
  descriptor snapshots before remapping, and native 126/127 failures;
- D option metadata generated directly from `frontend/option_def.py`, YSH
  startup defaults, CLI overrides, actual shopt set/unset/query/printing and
  scoped overlays;
- the reference's stricter option overlay during expression and assignment
  evaluation, distinct automatic failure versus explicit exit, catchable
  structured errors and the shared `_error` register;
- distinct proc status returns and func typed returns, syntax checks at
  definition time, callee-before-argument evaluation and shared typed-argument
  parsing for the translated paths;
- source/eval final status, zero status for empty programs and explicit exits
  that propagate through source rather than being rewritten as runtime errors;
- single-resolution augmented places, base-prefixed integer literals,
  approximate scalar equality, initial shell-array literals, lazy braced
  defaults and floating-point overflow/underflow.

The option metadata's `implemented` flag belongs to the reference definitions.
It is not a D completeness flag. Many parser and evaluator consumers of those
options are still untranslated. The retained source is still named `ysh-d`.

The **unchanged original** `test/sh_spec.py` ran all 1,119 cases from 80
`spec/ysh-*.test.sh` fixtures plus `spec/grease-alias.test.sh`, with each file's
declared YSH or default OSH mode. Its host-only Python 2.7.13 and the original
`spec/bin` helpers are test prerequisites, not D-shell runtime dependencies.
The results are **326 assertion matches and 793 failures**. No expected-failure
allowance was added. PASS is the harness's assertion result, not a claim that
every covered implementation path has been reviewed or translated.

The source tree, executable digest and test boundaries are in
[`inherited-host-2026-10-20.tsv`](qualification/inherited-host-2026-10-20.tsv).
The fixture hashes and totals are in
[`inherited-suites-2026-10-20.tsv`](qualification/inherited-suites-2026-10-20.tsv),
and every failing case remains explicit in
[`inherited-cases-2026-10-20.tsv`](qualification/inherited-cases-2026-10-20.tsv).
The earlier handwritten spec diagnostic is preserved as an experiment under
`examples/autogenerated/grease-d-spec-diagnostic`; its single-mode counts are
not comparable to the restored original harness.

At the 2026-10-20 checkpoint, remaining blockers included:

- command/word grammar: `case` prevents the unmodified list and math standard
  libraries from loading; quote-sensitive word/glob/splitting behavior,
  here-documents and multiline commands remain incomplete;
- funcs/procs/closures: the inherited func suite is 24/26; typed/named/block
  proc parameters and command/expression/place closures remain untranslated;
- data/display: full JSON/J8 decoding and formatting, typed values and pretty
  printing are incomplete;
- objects/type objects/prototypes, module/source semantics and reflection;
- Eggex/regex, jobs, traps, completion, prompt/history and interactive behavior.

The augmented-assignment suite is 12/12, the Grease alias fixture is 1/1, and
shopt is 8/9. Its remaining `--table` fixture is an upstream TODO with a declared
failure allowance; the D run still records it as FAIL rather than making the
request a no-op. Definition-time syntax validation and corrected missing-name
statuses also expose earlier apparent passes that failed for the wrong reason,
including missing builtins and unparsed standard-library function bodies.
Those gaps have not been hidden by restoring permissive behavior.

Whole-shell and shared-spec acceptance remain BLOCKED. This continuation has no
hosted CI receipt, managed FP/AICI acceptance, release/package admission or
target-device acceptance. The earlier producer controls have not been rerun
against this continuation. No completion, migration, merge or reopening of the
parked integration request follows from these local results.

## Case continuation, 2026-10-21

Both case syntaxes now parse and execute in D. YSH arms support exact typed
expression equality, lazy alternatives, shell patterns with per-fragment
quoting and libc fnmatch, Eggex patterns, and `(else)`. Retained shell syntax
supports optional pattern parentheses, empty actions, nested case commands,
`;;`, `;&`, and `;;&`. Structural operator discovery reuses the case parser
instead of counting pattern pipes/parentheses as command operators. Every
arm's syntax is checked even when another arm is selected.

Eggex case patterns have a D AST and a lazy POSIX ERE lowering/matching path:
literal strings, primitive and named classes, character classes/ranges,
string splices, alternation, groups, captures, repeat counts and reference
flags. Match registers retain byte offsets and names; capture conversion
functions resolve before matching and run on group retrieval. ImportC reads
the target's libc declarations from `<regex.h>` and `<fnmatch.h>`; no regex
ABI layout is guessed and no shell source is delegated to another runtime.
First-class Eggex values, Eggex-value splices, the full regex API and the full
word grammar remain open. This is not complete regex acceptance.

The original inherited case fixture passes **18/18**. The unmodified
`stdlib/ysh/list.ysh` and `math.ysh` files now load. The recursive LRU-cache
function test now computes the expected values and fails only on compact
versus indented JSON output; the other function-suite failure is the missing
typed prefix in expression display. These remain real failures.

Pinned Icky DMD passed 16 CLI/module suites, 15 library-module suites, generated
option consistency, and the existing owner smoke body. The unchanged original
harness reran all 1,119 cases: **356 assertion matches, 763 failures**, with
30 additional assertion matches and no regression from the 2026-10-20 ledger.
Five complete fixtures pass: case, augmented assignment, dictionaries, reserved
syntax, and Grease aliases. Expected-status-only matches still do not prove
that their implementation paths are complete.

Exact source/binary identities, fixture hashes and all per-case results are in
[`inherited-host-case-2026-10-21.tsv`](qualification/inherited-host-case-2026-10-21.tsv),
[`inherited-suites-case-2026-10-21.tsv`](qualification/inherited-suites-case-2026-10-21.tsv),
and [`inherited-cases-case-2026-10-21.tsv`](qualification/inherited-cases-case-2026-10-21.tsv).
The larger acceptance gaps remain word expansion and multiline/heredoc syntax,
full proc signatures and closures, JSON/J8 and display, object/type/module
behavior, regex values/APIs, jobs/traps and interactive execution. Shared-spec,
producer, managed/AICI and physical-device acceptance have not been rerun.
The continuation remains incomplete and unpublished.

## Data output and display continuation, 2026-10-21

JSON and J8 output now share a D translation of the reference instance printer
for translated values. The command default is two-space indentation, with
typed `space` and `type_errors` options; `toJson`/`toJson8` default to compact
output. The encoder rejects active container cycles while permitting shared
acyclic values. It buffers messages before writing, reports builtin codec
failures with status 1, and exposes function codec failures as structured
status 4. JSON maps nonfinite floats to null; J8 retains NAN/INFINITY. Diagnostic
printing shows cycle markers and non-data type tags.

The expression display path and `pp value` now use measured documents derived
from `display/pretty.py` and `pp_value.py`. The document algebra includes
groups, breaks, indentation, flat alternatives, suffix-width measures and the
reference list tabulation rule. Supported values use YSH string syntax,
identifier-aware dictionary keys and aligned type prefixes. Terminal width
comes from the output descriptor, with the reference fallback of 80 columns.
Locale startup initializes LC_CTYPE, and LC_COLLATE for OSH mode, while keeping
numeric conversion in the C locale. A CLI test verifies a multibyte regex
capture; string tests cover mixed Unicode/invalid bytes and control escapes.

The unchanged inherited function suite now passes **26/26**, including its
recursive LRU-cache computation and full indented JSON transcript. Case remains
18/18. The current source passed 17 CLI/module suites, 16 library-module suites,
generated metadata consistency and the owner workflow smoke. The smoke now
requests `space=0` explicitly for its intentionally compact JSON example.

The unchanged original inherited harness reports **388 assertion matches and
731 failures** across all 1,119 cases: 62 additional matches and no previous
pass lost relative to 2026-10-20. One initial run of
`ysh-builtin-error:17` timed out; both its isolated and complete-fixture
reruns produced an assertion failure without timing out. The initial timeout
diagnostic is retained separately. Its assertion diagnostic formatting remains
unfinished. The final per-case ledger retains the rerun's FAIL.

Current identities and complete case results are recorded in
[`inherited-host-2026-10-21.tsv`](qualification/inherited-host-2026-10-21.tsv),
[`inherited-suites-2026-10-21.tsv`](qualification/inherited-suites-2026-10-21.tsv),
and [`inherited-cases-2026-10-21.tsv`](qualification/inherited-cases-2026-10-21.tsv).
The earlier case-only ledgers remain separate above.

This does not complete JSON/J8 decoding or the entire value/display model.
JSON reading/fromJson, heredocs/word grammar, proc signatures/closures, object
and type values, module/reflection behavior, regex values/APIs, jobs/traps,
terminal styles and interactive behavior remain open. Reference object IDs
are not synthesized by the initial D pretty printer. No hosted CI,
shared-spec acceptance, managed/AICI admission or target-device acceptance
follows from this continuation. Publication remains blocked.
