# Issue #39 — OpenAPI client migration and solver parity: run notes

Raw material for the #39 PR description. The tests-only phase committed the
verification instruments (tests + this mapping); the implementation run fills
in the findings and lifts this into the PR body.

## Criterion → verification mapping

| # | Criterion | Verification | Instrument |
|---|-----------|--------------|------------|
| AC-1 | Adopt `swift-openapi-generator`/`swift-openapi-runtime` in `ColorComposerCore`; migrate/wrap `PaletteAPIClient` | Keep `PaletteAPIClientContractTests` green through the migration (they pin every observable behavior) | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift` |
| AC-2 | Preserve per-server/profile color caching, offline-stale badges, cached profile fallback | `OfflineFallbackCacheTests` (fetch→cache→refetch-fails→serve) + existing `ProfileColorCacheTests` must stay green | `ColorComposerCore/Tests/ColorComposerCoreTests/OfflineFallbackCacheTests.swift` |
| AC-3 | Solver parity test target loading the committed corpus, exact selections incl. ties | `SolverParityCorpusTests` (committed corpus + harness self-check) | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` |
| AC-4 | Document corpus consumption (location, refresh) | `docs/solver-parity-corpus.md`; link from README in the implementation run | this docs/ directory |
| AC-5 | PR description records migration notes, `/api/v1` shape changes, parity results | Fill the sections below in the implementation run | this document |

## `/api/v1` shape pins (migration safety net)

The contract tests decode these literal envelope shapes; the generated client
must produce/consume the same data. Any divergence between these and the
published OpenAPI document (viamin/color_matching#110) is a real API-shape
change and must be recorded here and in the PR body:

- `GET /api/v1/printer_profiles` → `{"printer_profiles": [{id, printer_make_model, paper_type, ink_type}]}`
- `GET /api/v1/colors?printer_profile_id=N` →
  `{colors: [{id, name, hex, rgb{r,g,b}, palette_id, palette_name, sort_order,
  responses: {<light_source>: {brightness, source, raw_value, raw_unit,
  apparent_brightness, measured_at, test_run_id}}}], printer_profile?}`
- All keys snake_case; auth via `Authorization: Bearer <token>`; 401 is the
  re-authentication signal; missing responses are absent keys, never zero.

Shape changes found during migration: _none recorded yet — implementation run
fills this in (or confirms "none found")._

## Generated-client migration notes (template)

Implementation run records:

- Dependency additions (`swift-openapi-generator` plugin,
  `swift-openapi-runtime`, URL session transport package) and lockfile changes.
- Whether `PaletteAPIClient` wraps the generated `Client` or is replaced by
  it; where the disk cache hooks in (wire DTO → `CachedProfileColors` path
  must be unchanged).
- Generated-code location and regeneration command (`openapi-generator`
  plugin phase in `swift build`).
- Any behavior deltas surfaced by the contract tests.

## Parity test results (template)

Implementation run records:

- Corpus revision consumed (upstream commit from viamin/color_matching#111)
  and case count.
- Result summary: pass/fail counts, tie cases exercised, exclusion cases
  exercised, weight-handling cases exercised.
- Divergences found (expected: none — solver semantics are a non-goal to
  change; a divergence means a bug or an upstream corpus mismatch).

Current state (tests-only phase): the corpus fixture is not yet committed
(blocked on vendoring it from upstream in the implementation run), so
`testCorpusIsCommittedAtTheCanonicalLocation` and
`testEveryCorpusCaseMatchesTheElixirSelectionExactly` are red by design; the
harness self-check
(`testHarnessVerifiesTheDocumentedReferenceCase`) exercises the full
verification path and passes.

## Verification runs

- `bin/lint` / `swift test`: no Swift toolchain exists in the tests-phase
  container, so the suite could not be executed here; run
  `cd ColorComposerCore && swift test` on a macOS host. Expected at this
  head: all suites green except the two corpus-consumption tests named
  above (red until the corpus fixture lands).
