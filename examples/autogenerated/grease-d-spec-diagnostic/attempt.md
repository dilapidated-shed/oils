# Grease D spec diagnostic attempt

This D helper was written while recovering the D translation. The requested
implementation language was D. It was not an Idriç attempt or evidence about
Idriç, and it is retained as an experiment rather than an acceptance runner.

The values are fixture bytes, parsed cases, expected byte streams and statuses,
absolute executable paths, and per-case results. The central operations are
`readCases : Str -> List[SpecCase]` and an effectful case runner that writes the
unchanged source to a temporary directory, starts a bounded child process, and
compares stdout, declared stderr, and exit status. Its output is plain TSV plus
the actual streams. Unknown assertion encodings fail qualification. POSIX
processes, timeout, and filesystem access are required; no reference shell runs
the translated program.

The rebuilt initial checkpoint produced 292 passes and 827 failures across
1,119 cases. This was a diagnostic result, not whole-shell compatibility. The
helper does not select the reference's `our_shell` mode and was run before the
original Python 2 harness prerequisites were restored. Its counts cannot be
compared directly with the later inherited-harness counts.

The actual continuation now uses the repository's unchanged `test/sh_spec.py`,
with each fixture's declared YSH or default OSH mode and the original `spec/bin`
helpers. Python 2 is confined to that test harness and those external fixtures;
the D shell does not depend on it. This helper has therefore been removed from
the maintained D tools directory. Do not use it for admission or replace the
inherited assertions with its parser.

The next acceptance step belongs to the D runtime: implement the untranslated
command/word grammar and evaluators identified by the inherited harness. No
missing Idriç capability was established by this explicitly D experiment.
