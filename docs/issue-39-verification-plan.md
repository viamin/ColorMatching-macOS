# Issue #39 verification plan

This tests-only change establishes the regression contract for the generated
OpenAPI-client migration and the backend solver parity corpus. The referenced
backend PR is not accessible from this container, so the committed fixture is
a seed contract rather than a claim that it is the published artifact.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated client serves existing profile and color calls | `PaletteAPIClientTests` request-level tests; implementation phase adds generated-client wiring assertions | Existing behavior covered; migration wiring pending |
| Per-server/profile disk cache and offline fallback stay intact | `ProfileColorCacheTests` server namespace and cached-entry tests; app-model fallback behavior needs an implementation-phase integration test | Existing cache contract covered; UI fallback verification pending |
| Solver matches parity corpus, including ties/exclusions/weights | `WeightedSquaredErrorParityCorpusTests` reads the committed fixture and runs `CompositionSolver` | Harness covered; replace seed fixture with the published corpus |
| Corpus refresh is documented in README | Human inspection of README after implementation phase | Pending: README is outside the tests-only allowlist |
| PR records generated-client and parity findings | PR description | External/human evidence pending |

## Corpus refresh procedure

The fixture is `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
Before implementation merges, replace this seed with the published
`viamin/color_matching#111` corpus unchanged, retain its schema/version
metadata, and run the parity test. Thereafter, refresh it whenever that source
changes, before updating the README refresh instructions in the implementation
phase.
