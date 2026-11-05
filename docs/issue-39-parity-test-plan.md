# Issue 39 test plan

| Criterion | Verification | Status in test-writing run |
| --- | --- | --- |
| Generated OpenAPI client migrates palette/profile requests | Focused mocked transport tests will assert the generated client's request paths, parameters, authorization, and decoded values. | Deferred to implementation run: generated client is not yet present. |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Existing cache tests cover server/profile isolation; the implementation run must add focused client/app-model fallback tests where the generated transport is introduced. | Deferred to implementation run. |
| Solver selections exactly match the committed corpus, including ties | `WeightedSquaredErrorParityTests` replays every upstream corpus scenario, asserting each score, selected palette index and hex, selected error, and tied indices. | Added. |
| Corpus consumption is documented in the README | README must name the upstream corpus and refresh process. | Deferred: README is outside this run's permitted documentation allowlist. |

The fixture is copied verbatim from `viamin/color_matching` at
`priv/parity/v1/corpus.json`. Refresh it by obtaining the matching upstream
revision, running `mix parity.generate` in that repository, copying the
generated `priv/parity/v1/corpus.json` over the test fixture, and running
`swift test` in `ColorComposerCore`.
