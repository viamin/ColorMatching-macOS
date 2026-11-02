# Issue #39 verification plan

This test-writing change maps each acceptance criterion to inspectable evidence before implementation.

| Criterion | Verification | Current status |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused API-client tests cover generated operation request/response mapping and existing cache fallback tests remain green. | Not run — requires upstream OpenAPI document from `viamin/color_matching#110`. |
| Cache and offline fallback are unchanged | Existing `ProfileColorCacheTests` plus `PaletteAPIClientTests` are the permanent focused regression coverage. | Not run — implementation phase. |
| Solver results match the parity corpus, including ties | `SolverParityCorpusTests.testWeightedSquaredErrorSelectionsMatchParityCorpus` loads the committed JSON fixture and verifies selected color, score, exact exclusions, and unmatched output per case. | Not run — this schema-compatible bootstrap fixture must be replaced with the canonical corpus from `viamin/color_matching#111`, which is not externally readable in this environment. |
| README explains corpus refresh | Human inspection of the README after implementation confirms the corpus location and refresh command/source. | Not run — README is outside the test-writing allowlist. |
| PR records API-shape and parity findings | Human/external review of the PR description against upstream issues #110 and #111. | Not run — upstream pull requests are not readable from this environment. |

The parity fixture is stored at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`. Replace its bootstrap contents with the canonical corpus from `viamin/color_matching#111`, preserving the format-version and case schema consumed by `SolverParityCorpusTests`.
