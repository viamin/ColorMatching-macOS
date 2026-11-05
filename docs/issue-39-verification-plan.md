# Issue #39 verification plan

This test-writing PR establishes the checks that the implementation PR must
run. It does not make production changes.

| Criterion | Smallest credible verification | Status in this PR |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten transport while keeping the public client behavior | A focused `PaletteAPIClient` contract test covers the profile and color request/response boundary; implementation review inspects generated source and the OpenAPI input. | Pending the published `/api/v1/openapi.json` document and implementation. |
| Per-server/profile cache, offline-stale badge, and cached-profile fallback are unchanged | Existing `ProfileColorCacheTests` cover server/profile isolation and disk round trips. The implementation PR must add a focused `ColorCatalog` offline-fallback test if the adapter changes that seam. | Pending implementation test run. |
| Solver choices stay in lockstep with `color_matching` | `SolverParityCorpusTests.testReplaysCommittedColorMatchingParityCorpusExactly` replays every vector and checks individual scores, selected index/hex/error, exclusions, and exact tie evidence. | Added; not run because Swift is unavailable in this container. |
| Corpus consumption is documented | Update `README.md` to identify `Tests/ColorComposerCoreTests/Fixtures/color-matching-parity-v1.json` as the checked-in copy of `viamin/color_matching/priv/parity/v1/corpus.json`, and specify refresh by copying the generated upstream corpus byte-for-byte after its algorithm-version review. | Deferred by this run's test/docs-only boundary: `README.md` is outside its allowed LID paths. |
| PR records migration notes, API shape changes, and parity findings | Implementation PR description must state the generator/runtime versions, generated artifact location, observed `/api/v1` shape changes, and parity results for ties, exclusions, and weights. | Pending implementation. |

## Corpus provenance

Fixture source: `https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`

Source commit content SHA: `70e9999065c81334d1f2b5038a96c67cfd5d59d1`.
The checked-in fixture SHA-256 is
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

The fixture is `algorithm_version: 1` and deliberately covers earliest-index
tie breaking, positive-weight missing-measurement exclusions, zero-weight
missing channels, single-channel weighting, an ignored unknown weight, exact
matches, and all-candidate exclusion.

## Environment record

Dependency resolution and test execution could not start in this container:
`swift` is not installed (`swift: No such file or directory`). No database or
other infrastructure was started.
