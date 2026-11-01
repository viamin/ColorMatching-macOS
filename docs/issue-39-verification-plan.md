# Issue #39 verification plan

This test-writing change defines the executable contract for the generated-client
migration and weighted-squared-error parity work.

| Criterion | Smallest credible verification | Status in this test-writing PR |
| --- | --- | --- |
| Generated OpenAPI client replaces direct `/api/v1` decoding while preserving client behavior | Focused `PaletteAPIClient` transport tests for generated request paths, decoding, bearer authorization, and error mapping | Pending implementation tests |
| Per-server/profile cache and offline-stale/profile fallback remain intact | Existing focused cache and client tests; implementation run adds a regression test only if generated-client boundary changes it | Existing coverage to be evaluated in implementation run |
| Solver selections match the parity corpus, including ties | `WeightedSquaredErrorParityCorpusTests` loads the committed corpus and exercises the public `CompositionSolver` | Added here |
| README explains corpus consumption and refresh | Human review of README wording and the committed corpus source/revision | Pending implementation documentation |
| PR describes migration and parity findings | Inspectable PR description, including API-shape comparison and test output | External evidence; pending PR creation |

The parity corpus is intentionally exercised through `CompositionSolver`, not a
private scorer method, so it verifies eligibility filtering, earliest-wins tie
handling, channel weighting, and unmatched output as users receive them.
