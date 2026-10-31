# Issue #39 verification plan

This test-writing change pins the test contract for adopting the generated
`color_matching` client and its solver parity corpus.

| Criterion | Smallest credible verification | Status in test phase |
| --- | --- | --- |
| Generated OpenAPI client serves current endpoints | Focused `PaletteAPIClient` transport/decoding tests against generated operation models | Deferred to implementation phase |
| Per-server/profile cache, offline-stale badge, and cached profile fallback remain intact | Existing cache unit tests plus an app-level offline fallback system test | Existing cache tests cover cache scoping; app-level check deferred |
| Solver selections match the parity corpus, including ties | `WeightedSquaredErrorParityTests.testMatchesCommittedColorMatchingParityCorpus` loads the committed v1 JSON and checks every score, exclusion, selection, error, and tie index | Added; execution blocked because this container has no `swift` executable |
| Corpus consumption is documented | README section naming the upstream corpus and its refresh procedure | Deferred: the red-phase allowlist permits only `docs/` documentation, not README edits |

## Corpus source and refresh procedure

The fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is copied byte-for-byte from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

When `color_matching` changes its `algorithm_version`, regenerate the upstream
file with `mix parity.generate`, replace this fixture with the committed
upstream result, and run the focused parity test. The implementation phase must
also add this procedure to the root README.
