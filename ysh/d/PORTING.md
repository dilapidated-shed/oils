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

For example, upstream \`===\` and \`!==\` belong in compatibility tests during the translation.  They must not silently become the preferred syntax of ICKY/ICK or of a later character-rich frontend.  Native spellings such as \`≟\` and \`≠\` are a separate frontend decision after semantic parity is explicit.

The evaluator should receive semantic operator IDs rather than punctuation strings once the lexer/parser translation reaches that layer.

## Translation surface

The port is not limited to \`ysh/\`.  YSH deliberately shares substantial shell machinery with OSH, so the complete D YSH executable must translate the shared path it actually reaches.

### Entry and shell assembly

- \`bin/ysh\`
- YSH dispatch in \`bin/oils_for_unix.py\`
- \`core/shell.py\`
- main loop, startup, errors, options, and interactive setup reached by YSH

### Generated language/runtime data

Translate or generate D equivalents for the declarations YSH reaches, including:

- \`core/value.asdl\`
- \`core/runtime.asdl\`
- \`frontend/syntax.asdl\`
- generated IDs, option/builtin IDs, argument types, and related tables

### Lexing and parsing

- YSH expression lexer rules
- \`ysh/grammar.pgen2\`
- \`ysh/expr_parse.py\`
- \`ysh/expr_to_ast.py\`
- the command/word parsing machinery YSH shares with OSH
- source locations and parse errors

The completed D program must parse ordinary YSH source itself.  Feeding a Python-produced AST to D is not the endpoint.

### YSH evaluator/runtime

Every implementation module under \`ysh/\` is in scope:

- \`expr_eval.py\`
- \`expr_parse.py\`
- \`expr_to_ast.py\`
- \`func_proc.py\`
- \`regex_translate.py\`
- \`val_ops.py\`

Build-generation scripts may be replaced by D-native build/generation machinery rather than transliterated if they are not part of the running shell.

### Shared execution machinery

Anything reached by the YSH shell remains in scope even when its historical home is \`osh/\` or \`core/\`, including:

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

- every \`spec/ysh-*.test.sh\` test must be runnable against the D executable;
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

The checked user-function item is an executable first slice, not completion of
the unchecked functions/procs/closures surface. It does not yet cover named or
variadic parameters, typed signatures, proc word arguments, block closures,
named/variadic parameters, typed signatures, proc word arguments, block
closures, `for` loops, exceptions, loop levels, or general function-body
command evaluation. The checked branch/loop paths cover only `if`/`else if`/
`else` and `while`/`break`/`continue` on the D command parser.
