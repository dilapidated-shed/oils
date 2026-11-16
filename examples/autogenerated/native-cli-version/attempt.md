# Native D CLI version identity

The retained Kitchen native-transfer fixture first executes the selected
executable's `--version` interface. On 2026-11-16, exact hosted D artifact
`14166313138`, executable SHA-256
`4e9ae57236a2f01d97a2bf1f515e632680cfdbc10259c154b3b37d04a0126550`,
failed there with status 2: `ysh-d: invalid shell flag: -`. This is separate
from its passing 79-case request-binding source suite and from managed admission.

## Types and intended behavior

The implementation extends the existing D CLI; it is not a new interpreter or
an Idriç substitute for that CLI. The existing source-owned `oils-version.txt`
contains the reference version on its first line. Formatting that version is a
pure `string -> string` operation. Printing it is an output action returning a
process status; output failure cannot become success. The additional identity
line explicitly names the incomplete native D translation.

CLI parsing records a `bool` version request while validating the other flags.
After option parsing, version output returns before file loading, stdin reading
or command execution. A `--version` word after `-c` remains ordinary source/argv
material. Invalid flags remain usage errors. The version bytes are embedded at
build time, so relocation never reads an unrelated current-directory version.
Independent review caught an initial ordering error: `--version -c` returned
before validating the missing command operand. The successor keeps that status-2
usage failure before version output, with a native unit and executed CLI control.

## Source and verification boundary

Starting source: `cc3cfdf2c21f50e4c3a2ef0a8a94fcc4868e0d29` on the existing
`d/ysh-first-slice` branch. Reference: `core/shell.py:ShellMain`,
`core/util.py:_PrintVersionLine`, `core/pyutil.py:GetVersion` and
`frontend/flag_def.py:MAIN_SPEC`. The native CLI retains a partial-implementation
identity rather than claiming to be the C++ reference or complete Grease.

The existing owner workflow is the build path: Icky DMD
`ccf61ab82659b9eadee2d05b489fb195956cef88`, druntime
`74917954b53f7f35b13e61b4438c7253834929ed`, Phobos
`7b158eba80b97dfcdd8931bcaea1ad0ca35ceb95`. LDC remains its existing isolated
bootstrap only. No compiler is installed on a managed target. The build embeds
the root metadata with `-J.` in addition to the existing `-Jstdlib` resources.

Before editing, the actual unmodified Kitchen fixture reproduced the version
failure. The successor adds native CLI unit controls and a Grease qualifier for
exact output, relocation, no command execution and retained usage/argv errors.
The workflow also runs the unchanged retained Kitchen fixture at
`32c3bf2d7c6268b50f1e48395dc972cfbafec7a9`; further consumer failures must remain
failures rather than being waived. Compilation and successor execution are
PENDING until the exact owner workflow completes. No local D compiler is present.

This repair does not implement `getopts`, close the remaining inherited
behavior gaps, establish static/transitive C++ exclusion, admit a managed
runtime, or reopen the parked whole-translation PR. Those are separate outcomes.
