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

## Current host checkpoint: directory stack and shell bindings, 2026-10-21

The inherited diagnostic now reports **714 assertion matches and 405 failures
across 1,119 cases**. It gains eight matches over
`8d76a06405994d2b7a4f422608e569f85381686f` and loses no prior match.
The initial serial run recorded 713 matches, 404 failures and two timeouts.
Whole-fixture repeats of ysh-assign and ysh-env, at the unchanged three-second
limit, reproduced neither timeout: assignment case 20 matched and environment
case 9 failed its assertions. Both initial and repeat rows are retained.
Fixtures, harness, allowances and the test-only oracle are unchanged.

Shvar translates builtin/pure_ysh.py's temporary LocalOnly binding context.
It evaluates the fragment in the current frame, restores overridden variables
across structured errors and returns, removes temporary names and retains
other bindings created by the body. It accepts retained Command arguments.

The native directory stack follows builtin/dirs_osh.py. Cd replaces its top
entry; cd blocks push and pop through the same stack as pushd/popd. A pushd
inside a block therefore affects restoration. Dirs implements clear, numbered,
per-line and literal-path views with reference flag priority. Pwd uses saved
logical state, with physical resolution on request. Tests exercise symlinks,
stack mutation, failed restoration after dirs -c and nonlocal unwinding.

Shell special parameters share native state: status, argument count, root PID,
background PID slot, option letters and positional values. Expression status
is a Str, unbraced numeric parameters consume one digit, and bare $name is
rejected in expressions. Array-to-string rules distinguish quoted $* from
scalar $@/$*, including strict_array. Root PID remains stable in captures.
Background job execution itself remains untranslated.

Eval matches **28/31**, scope **12/26**, bugs **12/20** and blocks **9/16**.
These counts do not qualify complete subsystems or the whole translation.
Pinned Icky DMD compiles source tree
`49ab3699a1877b24550296135388d50826d3618f`; host binary SHA-256 is
`cb461eb12ae88f7927f9ceec79bfa129ef8e5dcbc629a7ce64686956d1319237`.
All 28 CLI/module suites, 27 library suites and the existing owner smoke pass.
Shared specs, static-transitive AI-CI, managed admission and physical targets
remain unqualified. Modules/reflection, full shell words/builtins, jobs/traps
and interactive behavior still need translation.

See [host qualification](qualification/inherited-host-directory-2026-10-21.tsv),
[suite results](qualification/inherited-suites-directory-2026-10-21.tsv),
[final case results](qualification/inherited-cases-directory-2026-10-21.tsv),
[initial case results](qualification/inherited-cases-directory-initial-2026-10-21.tsv)
and [whole-fixture repeats](qualification/inherited-cases-directory-repeat-2026-10-21.tsv).

## Previous host checkpoint: attribute blocks and IFS splitting, 2026-10-21

The unchanged inherited harness reports **706 assertion matches and 413
failures across 1,119 cases**, with no timeouts. This serial run adds 24
matches over `26d556166350bab093c1fc654864f1f880444f91` and loses no previous
match. The fixtures, three-second limit, expected failures and test-only
reference environment are unchanged. The full translation remains incomplete.

Literal command blocks retain the reference's first-word attribute classification:
a static initial uppercase word with a lowercase character enables bare
declarations. Quoted static names and leading environment bindings follow the
same rule; dynamically expanded names do not enable it. Branches, loops,
functions and retained Command values preserve the parsed lexical context.
Dynamic eval, source and command substitution start their own context.

The native IFS splitter follows osh/split.py's incremental byte state machine,
including whitespace/non-whitespace delimiters, escaped bytes, invalid UTF-8,
empty literal fragments and split limits. split/shSplit use explicit IFS or
reference dynamic cell lookup; maybe converts Null/Str into a word list. The
reference's default global IFS is initialized. Ordinary shell-word expansion
does not yet consume this splitter on every path.

Foreground pipelines retain their ordered per-stage statuses. Ordinary commands
do not overwrite that array, and isolated capture changes remain in the child.
Frame-variable display uses insertion order and exposes the enclosure marker.
Tests cover parser boundaries, deferred execution, dynamic IFS lookup with
dynamic_scope disabled, pipeline isolation and quoted/temporary-binding names.

Eval matches **26/31**, function builtins **9/10**, procs **32/38**, namespaces
**3/7** and assignment options **4/5**. Previous complete fixture matches are
retained. These are assertion counts, not complete subsystem qualification.

Pinned Icky DMD compiles source tree
`c0a06982f05642edf8f708a7a4d8ed34f598baf8`; host binary SHA-256 is
`5e32adc4f6be1bdaab4cc03c9c39d305e0e4494a570db7ffaef7ff24caef14b8`.
All 27 CLI/module suites, 26 library suites and the existing owner smoke pass.
Dynamic dependencies remain libc, libgcc_s and the loader. Shared specs,
static-transitive AI-CI, managed admission and physical targets remain
unqualified. Full shell words/builtins, modules/reflection, jobs/traps and
interactive behavior still need work.

See [host qualification](qualification/inherited-host-attribute-2026-10-21.tsv),
[suite results](qualification/inherited-suites-attribute-2026-10-21.tsv), and
[case results](qualification/inherited-cases-attribute-2026-10-21.tsv).

## Previous host checkpoint: native I/O and evaluation scopes, 2026-10-21

The unchanged inherited harness reports **682 assertion matches and 437
failures across 1,119 cases**, with no timeouts. This serial run adds 33
matches over `e652a7b7aed2973755ec564898593d4c263769ac` and loses no previous
match. The test-only reference build was also repaired, so these gains are
not attributed solely to D implementation changes. The whole-language
translation and inherited acceptance remain incomplete.

Native capture forks an isolated evaluator and drains stdout/stderr together
with POSIX poll/read. A test exceeds both pipe capacities to check deadlock
behavior. CaptureAll retains byte streams and terminal status; captureStdout
removes NUL/trailing LF and wraps failure as structured status 4. Command
substitution shares the process boundary while retaining its own status rule.
All language evaluation remains in D; capture never invokes a reference shell.

Eval/evalExpr now accept dollar0, positional and temporary variable bindings;
command eval also supports captured-frame execution and dictionary capture.
Bindings restore before frame collection and across errors. Frame cells use
insertion order, preserving declaration order without sorting returned names.
Lazy command arguments retain individual positional/named expression closures.
Lazy spreads remain explicitly untranslated. ParseCommand validates source,
captures lexical/module frames and converts syntax errors to structured errors.

The io glob APIs use the target libc ABI through ImportC. Shell filtering
applies dotglob, GLOBIGNORE, no_dash_glob and globskipdots; libcGlob omits those
filters. This does not complete ordinary shell-word glob/brace expansion.
Stdin is a distinct value; each loop snapshots its active input stream, strips
only LF and reports read errors. Redir/fopen execute their fragment in the
current frame. Raw-line and byte-count reads use the descriptor directly so
following bytes remain available to other commands. Pending trap execution
during EINTR, full OSH read behavior and other builtin forms remain open.

The I/O-method fixture matches **9/9**, eval **17/31**, for **19/20**, assignment
**19/22** and procs **31/38**. Regex APIs remain **40/40**, regex **29/29**,
strings **29/29**, functions **26/26**, case **18/18**, contexts **8/8**, and
control flow **9/9**. These counts do not establish complete subsystem coverage.

The owning reference `build/py.sh minimal` now succeeds, including extension
tests, after supplying its readline headers under a separate host prefix.
Explicit inherited calls to REPO_ROOT/bin/osh reach that test oracle instead
of failing on missing generated modules. The fixtures and harness are
unchanged, including their three-second limit and expected failures. The D
binary has no dependency on this Python build or its extensions.

Pinned Icky DMD compiles source tree
`ae714686abce2f20a41d4b965a5f33e097896e7d`; host binary SHA-256 is
`89823e19744dd3f3e7ec22083a659965bd4073907a8f7ff74ed705da91d4fd3e`.
All 25 CLI/module suites, 24 library suites and the existing owner smoke pass.
Dynamic dependencies remain libc, libgcc_s and the loader. Shared specs,
static-transitive AI-CI, managed admission and physical targets remain
unqualified. Capitalized attribute blocks, full shell words/builtins,
modules/reflection, jobs/traps and interactive behavior still need work.

See [host qualification](qualification/inherited-host-io-stream-2026-10-21.tsv),
[suite results](qualification/inherited-suites-io-stream-2026-10-21.tsv), and
[case results](qualification/inherited-cases-io-stream-2026-10-21.tsv).

## Previous host checkpoint: retained control and call frames, 2026-10-21

The unchanged inherited harness reports **649 assertion matches and 470
failures across 1,119 cases**, with no timeouts in this serial full run. That
adds 38 matches over published source
`6d1db98c2fbe9f4d8e5bef961e937daae4c5c592`, with no previous match regressed.
The whole-language translation and inherited acceptance remain incomplete.

Shell-compatible function definitions now have their own argument lists,
dynamic word lookup, lexical expression lookup, local bindings and proc
boundaries. Typed calls and shell calls share runtime status, regex captures,
contexts, shell arguments and directory state while unwinding local, global
and option frames. Captures retain their defining lexical/module frames.
Retained for/while/until commands parse structurally, including nested do/done
and here-document data; no shell runtime interprets their source.

Function redirects and here-documents bind at invocation. Header siblings and
runtime positional substitutions are retained. Brace groups execute in the
current frame. Cd blocks restore logical directory/PWD state across returns
and errors, and -P uses physical paths. Full directory-stack and startup-PWD
behavior remain open. Complete command-word boundaries prevent builtin and
keyword prefixes from consuming longer command names or aliases.

The reference VarChecker now rejects undeclared local setvar targets,
duplicate var/parameter names, const inside typed definitions, and mixed
nested shell/typed definitions. It checks source order within each definition;
command substitutions receive fresh checker state. Declaration, function and
parameter annotations follow the type-expression grammar without adding type
enforcement. An intermediate full run exposed an assignment regression after
shell-function support; the checker repairs it before this qualification.
D-only tests that intended global mutation now say setglobal. No inherited
fixture or failure allowance was changed.

Control flow matches **9/9**, assignment **18/22**, procs **31/38**, and scope
**9/26**. Functions remain **26/26**, case **18/18**, regex **29/29**, regex APIs
**40/40**, strings **29/29**, and contexts **8/8**. Objects remain **13/15**, for
**18/20**, and JSON **59/64**. These are assertion matches, not claims that the
associated implementation surfaces are complete.

Pinned Icky DMD compiles D source tree
`4a2a52e65fa29b54ece6f913a7946438de3a396b`; host binary SHA-256 is
`0c5675006f32614bc0884fbeceaea355319cc399edb4320ab1254dcf22bb7d3e`.
All 23 CLI/module suites, 22 library suites and the existing owner smoke pass.
Dynamic dependencies remain libc, libgcc_s and the loader. Shared specs,
static-transitive AI-CI, managed admission and physical targets remain
unqualified. I/O methods/iteration, builtins, modules/reflection, remaining
shell grammar, jobs/traps and interactive behavior still need translation.

See [host qualification](qualification/inherited-host-retained-control-2026-10-21.tsv),
[suite results](qualification/inherited-suites-retained-control-2026-10-21.tsv), and
[case results](qualification/inherited-cases-retained-control-2026-10-21.tsv).

## Previous host checkpoint: native control, calls and objects, 2026-10-21

The unchanged inherited harness now reports **611 assertion matches and 508
failures across 1,119 cases**: 95 additional matches over published source
`8787979709fb5f81ae73f24cdd9c5a88ad3e757a`, with no previous match regressed
after an original-limit repeat described below. This remains an incomplete
translation; the inherited acceptance requirement has not passed.

Retained double-bracket conditions have an unevaluated command AST, lazy
logical operands, quote-aware glob/ERE patterns, match registers and the
BASH_REMATCH expansion. Retained if/then/elif/else/fi now shares the branch
evaluator with brace-form if. Structural scanning treats compound commands
as opaque spans, including nested branches and here-document data, and all
branches receive syntax validation before evaluation. This does not complete
retained arithmetic conditions, file operators or the entire shell grammar.

Proc signatures now have word, typed positional, named and block groups,
defaults evaluated at definition, rest arguments, annotation syntax and
duplicate-name checks. Calls use the same typed-argument parser as functions
and builtins. The inherited named binder's remaining-key count comparison is
preserved. Captured Expr and Command values retain lexical/module frames.
Native io eval/evalExpr support their default call forms; their named options,
the remaining I/O methods and stdin iteration are not complete.

Str.replace implements literal and Eggex patterns, eager strings and lazy
expression templates, count limits, converted/named captures, temporary
positional arguments, lexical scope, and restoration on errors. Retained
shell arguments are distinct from ARGV. An earlier D-only producer test
incorrectly expected set -- to overwrite ARGV; it now checks the reference's
separate positional/list states. No inherited assertion was changed.

Obj values now implement own-property/prototype lookup, bound Func/BuiltinFunc
methods, mutating-method lookup, property mutation, property views/copies and
invokable procs with self binding. Builtin and bound functions have separate
value variants and stable builtin lookup across calls. Obj/ io namespaces use
the same object rules as user values. Ctx push/set/emit and append execute
natively; context stacks unwind after errors and propagate through calls.
Object reflection, index metamethods, complete method chaining and namespace
initialization remain open.

Retained BashArray/BashAssoc values have distinct container representations,
sparse assignment, compound initialization, append and expansion paths.
Assignments on typed values are rejected by the actual retained assignment
path. Full shell arithmetic/index grammar, declarations and array operations
remain incomplete. Hash comment recognition now respects parameter, command
and expression boundaries, including ${#array[@]}. For-loop grammar checks and
the no_parse_bare_word consumer follow the retained parser.

Final focused assertion results are regex **29/29**, regex API **40/40**, strings
**29/29**, contexts **8/8**, objects **13/15**, procs **27/38**, for **18/20**,
JSON **59/64**, case **18/18**, func **26/26**, Dict **7/7**, and expression
arithmetic **30/30**. These are assertion counts, not complete subsystem
qualification. Shared specs, static-transitive AI-CI, managed admission and
physical targets remain unqualified.

The first full repeat recorded 610 matches, 508 failures and one timeout in
the boolean fixture's case 4, which launches the original Python comparison
programs. A complete repeat of that unchanged fixture at the original three
seconds passed case 4 and retained its existing case 5 failure. The final
ledger substitutes that complete fixture repeat; the initial case ledger is
preserved. An earlier intermediate run's eight changed expected-error outcomes
were repaired by implementing their missing operations, then all 81 fixtures
were repeated. No timeout or failure allowance was added.

Pinned Icky DMD compiles D source tree
`cd20799cccb1d61cfbd5e84f19976bf8979a54ad`; host binary SHA-256 is
`b468cb0770654e6572a2b6943b53e29f37637914792fcb245d4bf64c4e5a7ed0`.
All 22 CLI/module suites, 21 library suites and the full existing owner smoke
sequence pass. Dynamic dependencies remain libc, libgcc_s and the loader.
This is not a proof about every static/transitive dependency.

See [host qualification](qualification/inherited-host-native-control-2026-10-21.tsv),
[suite results](qualification/inherited-suites-native-control-2026-10-21.tsv),
[case results](qualification/inherited-cases-native-control-2026-10-21.tsv), and
[initial full-run results](qualification/inherited-cases-native-control-initial-2026-10-21.tsv).

## Previous host checkpoint: Eggex values and string grammar, 2026-10-21

The unchanged inherited harness reports **516 assertion matches and 603
failures across all 1,119 cases**, with no timeout. This adds 81 matches over
published source `f89091f29b70f47a0ae1188024eb5b3f0bf446e3`; no previous match
regressed. All remaining whole-shell requirements and independent acceptance
boundaries remain open.

Eggex literals now evaluate to D runtime values. Evaluation snapshots string
and Eggex splices and capture-conversion functions; ERE lowering remains lazy.
Flag compatibility is checked at evaluation, including canonical aliases and
translation preferences. POSIX matching supplies the reference's byte offsets,
named/positional captures, optional unmatched captures, and deferred conversion
on each group retrieval. `~` updates or clears the match register; `!~` preserves
it. `Str.search()`, `Str.leftMatch()` and Match group/start/end methods share
that implementation. Character-class terms retain the distinction between
byte escapes and Unicode escapes, including the reference's NUL/high-byte
errors. No Python, generated C++, or other interpreter evaluates these values.

Added identity and glob comparisons and floatsEqual(), preserved scalar alias
identity, and corrected the reference status of invalid approximate equality.
Encoding failures now identify their value type and cyclic container identity.
Regex case matching continues to use the same Eggex implementation.

Expression collectors ask the actual atom parser to consume Eggex and word
array literals, preserving internal semicolons and multiline data. Explicit
lexical string contexts keep shell-word quoting separate from expression
quoting. Parse options reach the expression, command and nested validators;
ANSI strings follow no_parse_osh, command prefixes follow parse_ysh_string,
and command triples follow parse_triple_quote. Added implicit triples and
explicit $-prefixed double quotes, triple-string concatenation rejection and
the here-string rule that omits its extra newline only for a triple-quoted
operand. String searches use byte slices rather than Unicode reverse traversal.

The focused results are regex **27/29**, regex API **23/40**, regex byte/Unicode
cases **13/15**, string **28/29**, and JSON/J8 **58/64**. Case remains 18/18 and
func remains 26/26. The outstanding regex cases require retained [[ ... ]]
conditions. Typed proc arguments and lazy expression replacement remain regex
API dependencies; retained if/then/fi remains a string-fixture dependency.
These counts are assertion matches, not a declaration of complete translation.

Pinned Icky DMD compiles D source tree
`591ccedd639bd8f9d41fe03e5ce4e7f9cb56012c`; host binary SHA-256 is
`c645a6029d6398a299b9895c3ce7624f3434465eb1ccc0a263d6984b64c7c381`.
All 19 CLI/module suites, 18 library suites and the full owner smoke sequence
pass. Earlier diagnostics (504 matches, including two string regressions) are
retained separately from the final run. Both regressions were repaired and the
entire unchanged suite was repeated; no earlier failure is relabeled a pass.

See [host qualification](qualification/inherited-host-regex-2026-10-21.tsv),
[suite results](qualification/inherited-suites-regex-2026-10-21.tsv), and
[case results](qualification/inherited-cases-regex-2026-10-21.tsv).

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
