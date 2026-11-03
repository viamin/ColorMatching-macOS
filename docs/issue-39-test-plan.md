# Issue #39 verification plan

This tests-only change establishes the verification contract before the generated-client migration is implemented.

| Acceptance criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client serves profiles and colors | Focused `PaletteAPIClient` unit tests with a URL-protocol transport, asserting the generated operation requests and decoded `/api/v1` envelopes. | To be added with the generated client. |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Permanent `ColorCatalog` system-style tests exercising a successful fetch followed by transport failure, including a second server with the same profile id. | Existing cache unit coverage; UI/catalog regression coverage to be added in implementation. |
| Solver matches the parity corpus, including ties | Permanent package test replaying the committed upstream v1 corpus against `WeightedSquaredErrorScorer`. | Added: `WeightedSquaredErrorParityTests`. |
| Corpus consumption is documented | README links to the upstream corpus and gives its pinned refresh procedure. | To be added in implementation; this phase may only change tests and `docs/`. |
| PR notes capture API-shape and parity findings | Inspectable PR description with test output and the discovered shapes/findings. | External evidence; not available until the implementation PR is opened. |

The fixture is copied verbatim from `viamin/color_matching` `priv/parity/v1/corpus.json` (algorithm version 1; SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`). Refresh it only after updating the server corpus: copy the new version into `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/`, update the version assertion, and run `swift test` from `ColorComposerCore`.
