# Issue #39 — criterion-to-verification map

Every acceptance criterion mapped to its smallest credible verification.
Status recorded per run in `tmp/paid-agent-verification.json`.

| # | Criterion | Verification | Where |
| --- | --- | --- | --- |
| AC-1 | `swift-openapi-generator` + `swift-openapi-runtime` in `ColorComposerCore`; typed client generated from the OpenAPI document | Structural unit test: manifest declares both products; document is committed and covers both consumed endpoints. Red until implemented, then a permanent regression gate | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientIntegrationTests.swift` |
| AC-2 | Behavior preserved: per-server/profile color caching, offline-stale badges, cached profile fallback | Characterization tests pin the `/api/v1` wire contract + error taxonomy the client must keep (transport vs auth vs status vs malformed — `ColorCatalog` only falls back to cache on transport errors). Cache namespacing/fallback already covered by the permanent `ProfileColorCacheTests` suite, which must stay green through the migration | `PaletteAPIContractTests.swift`, `ProfileColorCacheTests.swift` |
| AC-3 | Solver parity test target loads the committed corpus and asserts `WeightedSquaredErrorScorer` selections match exactly, including ties | Corpus fixture + parity tests: scorer-level best-match harness (selection, score, exclusions, tie sets, earliest-wins) plus solver fast-path cross-check on a 1×1 grid | `Fixtures/solver_parity_corpus.json`, `SolverParityCorpusTests.swift` |
| AC-4 | Corpus consumption documented (location, refresh) | Inspectable doc (this phase docs/; implementation run links it from README per the issue) | `docs/solver-parity-corpus.md` |
| AC-5 | PR description records migration notes, `/api/v1` shape findings, parity results | Human/PR-description criterion — checklist captured in `docs/generated-openapi-client.md` for the implementation run to lift into the PR; not settleable by automation here | `docs/generated-openapi-client.md` |

## Environment limitation

The dev container for this run is Linux with no Swift toolchain, and the
package targets macOS with Core Graphics dependencies — `swift test` cannot
execute here. Corpus arithmetic was verified independently (every case's
expected selection/score/exclusions/ties recomputed against the documented
algorithm) before committing the fixture. The committed tests must be
executed with `cd ColorComposerCore && swift test` on macOS (Xcode 16+) in
the implementation run.
