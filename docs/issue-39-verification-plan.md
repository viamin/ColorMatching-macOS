# Issue 39 verification plan

The committed fixture at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json` was copied from [`viamin/color_matching`](https://github.com/viamin/color_matching/blob/47057afd58f7d46b4d4b740ca7d2d08947774471/priv/parity/v1/corpus.json). Refresh it by running `mix parity.generate` in that repository, reviewing the generated JSON, replacing this fixture with the new committed upstream version, and updating the parity test's expected algorithm version when it changes.

| Criterion | Verification | Status in test-writing run |
| --- | --- | --- |
| Typed generated OpenAPI client replaces direct `/api/v1` calls while retaining the wrapper behavior | Focused API-client compatibility tests for printer-profile and color requests, authentication, non-2xx mapping, and response decoding; inspect generated source and package manifest in implementation review. | Existing focused API-client tests are the regression baseline; generated-client assertions require implementation. |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Permanent unit/service tests in `ProfileColorCacheTests.swift` plus a manual app-flow inspection of the offline-stale badge and profile picker. | Existing unit coverage; human inspection required after migration. |
| Weighted scorer agrees exactly with the upstream corpus, including ties | Permanent unit/service test `SolverParityCorpusTests.testV1CorpusReplaysScorerSelectionsScoresAndTiesExactly`, using committed `Fixtures/solver-parity-v1.json`. | Added in this run. |
| README explains corpus location and refresh process | Inspect README content and upstream corpus revision in implementation review. | Requires implementation-phase documentation edit. |
| PR records migration notes, shape changes, and parity findings | Inspect PR description against generated-client diff, OpenAPI document, and parity test output. | Requires PR authoring. |
