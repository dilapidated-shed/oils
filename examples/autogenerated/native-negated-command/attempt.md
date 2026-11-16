# Native negated shell commands

The unchanged Cat Food updater at source blob
`c0344624dfea2bb85d0f74807ff5c716294ec4cc` fails parse-only under the actual
`fe73c4c55faa3378cb9c5b7f136b54c403bfd8f0` native D artifact. Its source SHA-256
is `a426b3b8d2aebd4318c054715033457bebe00a09bd4bf04ece5a325e34655b45`.
The reducer `! true >/dev/null` exits 2 with
`Not an Eggex character class: dev`; the non-negated command parses.

## Types and intended behavior

Shell negation consumes a shell pipeline, preserves command word and redirect
grammar, and inverts its status with errexit suppressed. It does not consume a
YSH expression (`osh/cmd_parse.py:ParsePipeline` is the retained grammar).
The existing D `CommandScanner` and `commandFragment` retain
shell tokens, nested compound commands and here-document bodies as source.
The existing expression collector instead calls `consumeDelimitedAtom` even
when its tuple wrapper is disabled. A slash after a redirect then enters Eggex.

This repair reuses the existing command scanner at both parse-only and execution
negation seams. It is part of the existing D translation, not a new helper
interpreter. Native controls cover redirect paths, status inversion, pipeline
ownership, compound commands, here-documents, errexit exemption and rejection
of malformed commands. A Grease qualifier runs the same real CLI controls in
native D and the separate actual Oils reference. The unchanged updater remains
an additional parse consumer; no wrapper, token, source dialect or fixture is
rewritten to make it pass.

## Verification boundary

The pre-repair executable is
`f1fd464659172d302f9efc8ce9b86b1a25cc6d1597998f477aec16424fef0f27`,
owner run `43791153450`, artifact `14192632401`. Compiled successor verification
is PENDING until the exact retained Icky DMD owner workflow runs. The preceding
six version controls and paired ENV controls retain their successful evidence.
Further updater parser/runtime failures are separate measured dependencies.
No whole-language result, independent static/transitive C++ closure, managed
admission, source-host execution or live updater acceptance follows from
parse-only success.
