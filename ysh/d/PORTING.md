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

The single surviving runtime acceptance dependency is the inherited YSH spec
suite running against this D executable. Its immediate entrypoint gap is a real
`-n FILE` parse-only mode that performs no execution; the current CLI only
provides expression, `-c`, file, and stdin execution. This also prevents a valid
parse-only benchmark comparison. Do not implement `-n` by executing the program
or by passing its parse to Python/C++.

The full parser, alias expansion, options, proc/function signature and closure
parity, jobs/signals/traps, modules, regex/Eggex, interactive behavior, and
mutation-sensitive iteration still require inherited-spec coverage. Smoke tests
do not discharge this dependency. No completed `greased` or replacement for
ordinary YSH is claimed.

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
