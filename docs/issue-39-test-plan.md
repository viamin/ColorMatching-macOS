# Issue 39 verification plan

This test-writing change establishes the smallest durable checks for the
contracts in issue #39. The implementation change must keep the tests below
in the normal `ColorComposerCore` test suite.

| Criterion | Verification | Status in this test-writing change |
| --- | --- | --- |
| Typed client consumes the published `/api/v1` contract | Focused `PaletteAPIClient` request/response tests using the generated-client wrapper, including bearer-token and 401 mapping | Pending implementation; the existing tests are the baseline request behavior. |
| Per-server/profile cache, cached profiles, and offline-stale behavior remain intact | Existing `ProfileColorCacheTests` covers scoped durable cache entries. Add/retain `ColorCatalog` integration coverage around transport failure, cache fallback, and offline-stale presentation when the generated wrapper is wired in. | Pending implementation; UI/catalog behavior needs inspectable integration evidence. |
| Solver matches the server, including ties, exclusions, and weights | `WeightedSquaredErrorParityCorpusTests.testReplaysCommittedWeightedSquaredErrorParityCorpus` replays every committed backend scenario and invokes `CompositionSolver` for source-grid-representable selections. | Added in this change. |
| Corpus consumption is documented | README identifies the committed fixture, upstream source, and refresh command/review procedure. | Pending implementation; this phase may only change tests and LID documentation. |

## Corpus source and refresh contract

The fixture at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is copied from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (algorithm version 1). Refresh it only from the
backend's committed generated corpus after reviewing its algorithm-version
stamp and scenario diff. The eventual README documentation must direct
maintainers to regenerate upstream with `mix parity.generate`, copy the
resulting fixture, and run the core suite.

The fixture is intentionally data-driven: it includes strict winners,
earliest-index tie cases, missing candidate/target exclusions, zero-weight
channels, unknown weights, all-excluded cases, and single-channel matching.
