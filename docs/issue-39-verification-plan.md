# Issue #39 verification plan

This is the red test phase for generated-client adoption and solver parity.
The implementation phase must preserve this plan and turn every pending item
green.

| Criterion | Smallest credible verification | Current state |
| --- | --- | --- |
| Generated typed `/api/v1` client replaces or wraps hand-written decoding | Focused `PaletteAPIClientTests` using the generated transport and OpenAPI response fixtures; assert paths, bearer authorization, and typed profile/color conversion. | Pending implementation test updates. |
| Per-server/profile disk cache and offline-stale/profile fallback stay intact | Existing permanent `ProfileColorCacheTests` cover server namespaces and cached profile data. Add a focused `PaletteAPIClient` integration test at the client/cache boundary for a failed refresh returning cached, stale data. | Pending implementation test. |
| Swift solver matches the committed server corpus, including ties, exclusions, and weights | Permanent `SolverParityCorpusTests.testWeightedSquaredErrorMatchesServerParityCorpusExactly`; fixture is the byte-for-byte corpus from `viamin/color_matching` `priv/parity/v1/corpus.json` (blob `70e9999065c81334d1f2b5038a96c67cfd5d59d1`). | Red: fixture must be committed at `ColorComposerCore/Tests/ColorComposerCoreTests/Resources/parity/v1/corpus.json`. |
| README explains corpus location and refresh | Inspect the committed README update: it must name the upstream corpus URL, blob/revision policy, local fixture destination, and refresh command/process. | Pending implementation documentation. |
| PR records API shape and parity findings | Inspect the PR description against upstream OpenAPI document and the green corpus test output. | Human/external evidence required. |

## Corpus refresh procedure

Download `https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`, review the diff, and replace the local fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Resources/parity/v1/corpus.json`.
Then run `swift test` from `ColorComposerCore`. Never fetch the corpus during a
test run.
