# Issue 39 verification plan

This red-phase change establishes the test contract for generated API-client
adoption and solver parity.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Typed OpenAPI client is adopted | `SolverParityCorpusTests.testPackageDeclaresGeneratedOpenAPIClientDependencies` checks that the Swift package declares both required OpenAPI packages. Follow-up implementation tests will exercise the generated transport adapter. | Expected red |
| Per-server/profile disk cache and offline fallbacks are preserved | Existing `ProfileColorCacheTests` remain the focused regression suite; implementation must run them after wrapping the generated client. | Not run (Swift unavailable) |
| Solver selections match the server | `SolverParityCorpusTests.testReplaysServerAuthoredParityCorpus` replays the committed upstream v1 corpus through the scorer and solver. | Not run (Swift unavailable) |
| Corpus refresh is documented | The implementation-phase README change must identify the upstream corpus and copy/refresh command. | Deferred: README is outside the tests-only allowlist |

The vendored fixture is byte-for-byte sourced from
`viamin/color_matching` `priv/parity/v1/corpus.json` at the merged corpus
change (PR #112, issue #111). It intentionally covers exact ties,
earliest-wins selection, missing positive-weight channels, zero-weight
channels, single-channel weights, and all-excluded cases.
