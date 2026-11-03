# Issue #39 verification plan

This is the tests-only (red-phase) change set. It deliberately does not modify
production sources, package dependencies, generated OpenAPI output, or
`README.md`; those changes are reserved for the implementation phase.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client replaces/wraps `PaletteAPIClient` | Compile the package with generated client sources and run URLProtocol contract tests for profiles and colors. Inspect the dependency and generated-source commit diff. | Deferred to implementation |
| Disk cache and offline fallback stay unchanged | Run existing cache scoping tests plus focused `ColorCatalog` transport-failure fallback tests, including stale badge state and cached-profile fallback. | Deferred to implementation |
| Solver parity corpus | `WeightedSquaredErrorParityTests.testCommittedParityCorpusMatchesScorerSelectionAndScores` replays the committed upstream v1 corpus. | Added |
| Corpus consumption documentation | Inspect the README for upstream corpus location, pinned version/checksum, and refresh command. | Deferred to implementation |
| PR migration and parity findings | Inspect the PR description for API-shape notes and tie/exclusion/weight parity results. | Deferred to PR creation |

## Corpus source and refresh contract

The fixture is a verbatim copy of
`https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`
from `viamin/color_matching#111`. The implementation phase must document the
same source and an explicit refresh/checksum workflow in the README.

The corpus is intentionally decoded by the test rather than translated into
Swift literals, so newly added scenarios and metadata shape changes surface as
test failures.

