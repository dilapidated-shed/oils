# Native child environment values

The genuine version repair at `b5da24fc85341be4409e6b1b22ab7e7731d574b0`
compiled through Icky DMD and passed all six CLI controls in owner run
`43789537062`. The unchanged Kitchen native-transfer fixture then reached its
first normal case and failed with status 3 before any transfer POST:
`ysh-d: ENV.GH_TOKEN must be a Str`. Artifact `14192007139` preserves the actual
binary `4762f4f859e19b2248425fe7c3dbb8aa8f83e6cc61625450c2a85a28bae2ca83`;
its ZIP SHA-256 is
`e6d58d3f26dfcf35137b9e3647951392b85c54374bd60be414079528630998d9`.

## Types and intended behavior

The existing D `Memory.childEnvironment` maps typed ENV values and exported
cells to native `string[string]` process arguments. The canonical
`core/state.py:_FillEnvObj` includes only `Str` members. Null, integer, boolean,
list and dictionary values remain typed in ENV but contribute no child entry.
An empty string is still a present string entry. Existing exported-cell/ENV
precedence remains the reference's precedence; scalar `getEnv` lookup is a
different operation and is not changed by this correction.

The D method rejected every non-string value while making its initial copy,
then copied the ENV overlay without filtering. Kitchen intentionally writes
`ENV.GH_TOKEN = null` and `ENV.GITHUB_TOKEN = null`; removing those fixture
statements or substituting empty credentials would hide the translation bug.
The repair filters both child-copy seams rather than changing that consumer.

## Verification

This extends the existing D implementation instead of replacing it with a
new helper/interpreter. Native unit controls cover present/empty strings,
non-string omission, unchanged typed values, exported-cell fallback/ENV string
precedence, disabled ENV contribution and retained scalar lookup errors.
The Grease semantic specimen uses fixed synthetic variable names and prints
only those names, never a process's complete environment. The same literal
program runs through actual native D and the existing Oils reference, with
literal expected stdout and empty stderr. The unchanged Kitchen fixture stays
required. The current pre-repair D artifact must reject this specimen; compiled
successor verification remains PENDING until the exact owner workflow runs.

No test, token, source identity or failure expectation is waived. The owner
build retains pinned Icky DMD/druntime/Phobos and its original conformance work.
This does not qualify all ENV object/prototype or scalar lookup semantics,
static/transitive C++ exclusion, Cat Food/FP managed admission or live transfer.
