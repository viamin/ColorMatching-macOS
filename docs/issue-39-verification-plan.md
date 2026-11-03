# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in tests-only phase |
| --- | --- | --- |
| Generated OpenAPI client calls the existing palette endpoints | Focused `PaletteAPIClient` request/response tests against a mocked `URLSession` | Existing coverage; generated-client migration is implementation work |
| Per-server/profile cache, offline-stale state, and cached-profile fallback remain intact | Existing focused `ProfileColorCacheTests`; add app-level `ColorCatalog` fallback tests before migration | Cache scoping is covered; fallback-state verification is implementation work |
| Swift solver matches backend selections | Permanent `WeightedSquaredErrorParityCorpusTests` loading the committed #111 corpus | Red: upstream corpus is inaccessible in this environment |
| README explains corpus refresh | Inspect the README change and ensure the corpus test loads that documented path | Implementation work |
| PR records migration and parity findings | Human review of the PR description | Not automatable |

The corpus must be committed at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
Its JSON schema is enforced by `WeightedSquaredErrorParityCorpusTests` and records
candidate IDs, scores, weights, targets, and response vectors. The test compares
the selected candidate ID and score exactly for every case, including ties and
cases where candidates are excluded for missing active measurements.

This test-writing environment cannot read `viamin/color_matching#111`: both the
available GitHub connector and direct GitHub API request returned 404. The
implementation run must import the actual committed upstream artifact rather than
synthesizing a replacement.
