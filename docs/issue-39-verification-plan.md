# Issue #39 verification plan

| Criterion | Smallest credible verification | Evidence at implementation completion |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten transport while preserving API requests | Focused `PaletteAPIClient` service tests with a URL protocol fixture for both `/api/v1` operations, bearer authentication, status handling, and generated-model decoding | `PaletteAPIClientTests.swift` results and generated client/spec files |
| Disk cache, offline-stale behavior, and cached-profile fallback stay intact | Existing permanent cache service tests, plus an app-model/system-level offline refresh test where the UI state/badge can be inspected | `ProfileColorCacheTests.swift` and the new app-model/system test result |
| Solver selections retain server parity | Permanent corpus test that loads the committed `color_matching` #111 corpus, compares every score/exclusion, then runs the normal solver for each representable target | `WeightedSquaredErrorParityCorpusTests.swift` and its fixture |
| Corpus consumption is documented | README review against the committed fixture location and the upstream refresh command/revision | README diff and upstream corpus SHA |
| PR reports client migration and parity findings | Human inspection of the PR body against its required notes (shape changes, ties, exclusions, weights, test result) | PR URL/body |

The committed fixture is copied verbatim from `viamin/color_matching` `priv/parity/v1/corpus.json` (issue #111). It includes exact ties, excluded candidates, missing target channels, zero-weight channels, and unknown weight keys.
