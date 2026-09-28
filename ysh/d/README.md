# YSH in D

This directory is an independent D translation of YSH. The translation target is the language and its tests, not the generated C++ emitted by \`mycpp\`.

The first slice deliberately starts in expression/value land. It is small enough to execute and compare while still exercising real YSH semantics.

## Source map

The implementation currently follows these sources on the Oils/Grease line:

- \`core/value.asdl\` — YSH data values: \`Null\`, \`Bool\`, \`Int\`, \`Float\`, \`Str\`, \`List\`, \`Dict\`
- \`ysh/val_ops.py\` — truthiness, scalar stringification, exact equality
- \`ysh/expr_eval.py\` — numeric coercion, arithmetic, \`++\`, lazy \`and\`/\`or\`, comparisons
- \`ysh/func_proc.py\` — initial D user-function declaration, call, default, and lexical-frame path
- \`builtin/io_ysh.py:Write\` and \`spec/ysh-builtins.test.sh\` — scalar output arguments and basic output options
- \`ysh/grammar.pgen2\` — literal syntax and operator precedence
- \`frontend/lexer_def.py\` — decimal integer/float spelling used for numeric string coercion

## Implemented in the first slice

- \`null\`, booleans, decimal integers, floats, single-quoted strings, and list literals
- arbitrary-precision D \`BigInt\` values
- unary \`+\`, unary \`-\`, and \`not\`
- \`+\`, \`-\`, \`*\`, \`/\`, \`//\`, \`%\`, \`**\`
- \`++\` for strings and lists; dictionary merge exists in the value/evaluator layer
- lazy \`and\` and \`or\`, returning operands as YSH does
- \`<\`, \`>\`, \`<=\`, \`>=\`, \`===\`, \`!==\`, including chained comparisons
- YSH numeric-string coercion such as \`'40' + 2\`
- YSH precedence for power: \`-2 ** 2\` is \`-(2 ** 2)\`
- YSH integer division/remainder rules: \`//\` truncates toward zero; \`%\` rejects a negative divisor
- YSH's rule that exact equality is not defined on \`Float\`
- positional user functions with definition-time immutable defaults, lexical capture, and \`return (expr)\`
- nested \`if\` / \`else if\` / \`else\` command blocks, including return flow from selected branches
- parenthesized or bare-expression \`while\` blocks with \`break\` and \`continue\`
- expression \`for\` loops over Lists, Dicts, and Ranges, including index/key/value bindings
- scalar words, \`$var\`/\`$[expr]\`, and \`@List\`/\`@[expr]\` through \`write\`, with \`--sep\`, \`--end\`, and \`-n\`
- common \`echo\` output with scalar substitutions and \`-n\`

## Deliberately not in this slice

The expression slice above was the original boundary. Later parser/runtime slices now include variable declarations and mutation, dictionaries, bitwise operators and ranges, calls, positional user functions, conditional command blocks, \`while\`, expression \`for\` over List/Dict/Range values, scalar substitutions/list splices through \`write\`, and common \`echo\` output. The function path does not yet claim full \`ysh/func_proc.py\` parity or general function-body command support. Compound word parsing, word splitting, the \`echo -e\` escape mode, JSON/J8 output, shell-word/glob/stdin loop forms, procs, regexes, redirections, processes, and OSH compatibility machinery remain outside the translated boundary.

Untranslated syntax continues to fail closed; each new feature should arrive with its corresponding YSH behavior tests rather than guessed scaffolding.

## Build and run

The acceptance compiler is the Mars/Icky-DMD line in \`dilapidated-shed/ick\`, with its matching pinned druntime and Phobos. The workflow in \`.github/workflows/ysh-d.yml\` reconstructs that toolchain from exact commits, compiles all translated modules directly with Icky DMD, runs their unittests, and then runs the CLI smoke cases.

LDC remains a bootstrap compiler for building Icky DMD; it is not the compiler used to accept the translated YSH source.

A successful CLI smoke prints:

\`\`\`text
7
\`\`\`
The command-line printer is only a stable diagnostic representation for the D port. It is not yet the full YSH/J8 display layer.

## Integer representation

\`core/value.asdl\` specifies \`BigInt\`, while the current Python/C++ \`mops\` implementation still uses an int64-sized representation and explicitly says it wants to become heap-allocated integers. This D slice uses \`std.bigint.BigInt\` directly. That is closer to the declared value model, but it means overflow-boundary parity with the current implementation is a question for explicit compatibility tests rather than an accidental property of the port.

## Translation rule

When behavior is unclear, prefer this order of evidence:

1. YSH specification and grammar
2. YSH/OSH spec tests
3. typed Python implementation
4. generated/native C++ as implementation evidence

Do not mechanically transliterate generated C++ into D.
