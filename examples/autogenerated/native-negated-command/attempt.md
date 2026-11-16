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

## Initial qualifier correction

The first published qualifier at `3e1de799b5ca490e4f457d283e2d8358d003a642`
incorrectly expected empty reference stdout for bare `-n`. The retained
`frontend/flag_def.py` defaults `--ast-format` to `abbrev-text`, and
`core/shell.py` prints the AST during parse-only operation. Both binaries must
receive the explicit supported `-n --ast-format none` selection for the quiet
parse contract. This is a test-oracle defect, not a runtime failure; the empty
output assertions remain strict. Owner run `43795133190` preserves the initial
attempt. The other Grease qualification programs contain no paired `-n` probes
with this assumption.

The actual compiled `3e1de799` artifact also exposed a parameter-type mistake
in the qualifier: proc word arguments are `Str`, so comparing `expectedStatus`
with integer `2` using typed exact equality selects the wrong stderr branch.
A real CLI control printed `false true` for comparisons to `2` and `'2'`.
The qualifier uses numeric shell `test` for that status branch, preserving
required diagnostics for invalid input and empty stderr for valid input.

## Measured next dependency

Owner run `43795340812` at `720a873639d5c3d629bf1724d61eb137d72d5e1c`
compiled and passed the native suites, six CLI controls, paired ENV controls,
all existing inherited/shared gates and unchanged Kitchen transfer fixture.
The new paired gate then stopped at default `! true | false`: native D ran it,
while the actual reference reported `strict_errexit`, `OILS-ERR-300`.
Artifact `14194277010` preserves those streams. The original qualifier did not
save that failing reference status before asserting; an initial report of
status 2 was an unsupported assumption and is corrected. Canonical `e_die`
raises `FatalRuntime(1)`; the final collection records actual statuses before
checking them.

The reference's `_HasManyStatuses` recursively classifies command AST shapes,
including redirect/sentence wrappers, singleton and multi-stage pipelines and
AndOr children. The D source-dispatch model does not retain that reusable
structural status shape. A token blacklist would not implement this rule.
The final qualifier preserves required default pipeline/compound refusal
controls, collects all valid/invalid probes and both unchanged updater parses,
then exits nonzero for any divergence. No `set +e` replacement or runtime
guard approximation clears those failures.

Separately, the updater's imported repository helper exposes unquoted `@`
case-pattern and bracket-command parsing gaps in uncalled function bodies.
The exact reducers `f() { case $x in a@b*) true ;; esac; }` and
`f() { [ -n x ]; }` remain dependencies. Whole updater execution, default
strict-errexit parity and complete qualification remain unverified.
