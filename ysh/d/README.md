# YSH in D

This directory is an independent D translation of YSH. The translation target is the language and its tests, not the generated C++ emitted by \`mycpp\`.

The first slice deliberately starts in expression/value land. It is small enough to execute and compare while still exercising real YSH semantics.

## Source map

The implementation currently follows these sources on the Oils/Grease line:

- \`core/value.asdl\` — YSH data values: \`Null\`, \`Bool\`, \`Int\`, \`Float\`, \`Str\`, \`List\`, \`Dict\`
- \`ysh/val_ops.py\` — truthiness, scalar stringification, exact equality
- \`ysh/expr_eval.py\` — numeric coercion, arithmetic, \`++\`, lazy \`and\`/\`or\`, comparisons
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

## Deliberately not in this slice

Variables, assignments, dictionary literal syntax, bitwise operators, shifts, ranges, calls, attributes, subscripts, functions, procs, regexes, command syntax, word evaluation, redirections, processes, and OSH compatibility machinery are still outside the translated boundary.

The omission is intentional: each of those should enter with its corresponding YSH tests rather than as guessed scaffolding.

## Build and run

From any checkout root:

\`\`\`sh
cd ysh/d
dub test --compiler=ldc2
dub run --compiler=ldc2 -- "1 + 2 * 3"
\`\`\`

The second command prints:

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
