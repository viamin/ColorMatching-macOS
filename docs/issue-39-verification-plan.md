# Issue #39 — verification plan (test-writing phase)

Maps every acceptance criterion of #39 (generated OpenAPI client + solver
parity corpus) to its smallest credible verification. This run is the
red-phase/tests-only pass: implementation lands in a follow-up run, so
tests that expose missing deliverables are expected to fail now and must
go green with it.

## Criterion → verification map

| # | Criterion (deliverable) | Verification | Where |
| --- | --- | --- | --- |
| AC-1 | `swift-openapi-generator` + `swift-openapi-runtime` in `ColorComposerCore`; typed client generated from the OpenAPI document; `PaletteAPIClient` migrated/wrapped with disk-cache/offline behavior intact | Focused unit tests: structural preconditions (`OpenAPIClientMigrationTests`, red until landed) + wire-contract pins that must survive the migration (`PaletteAPIClientContractTests`, green now) | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientMigrationTests.swift`, `PaletteAPIClientContractTests.swift` |
| AC-2 | Preserve behavior: per-server/profile color caching, offline-stale badges, cached profile fallback | Existing permanent suites pin the core semantics (`ProfileColorCacheTests`, `PaletteAPIClientTests`); the contract tests above pin the fetch path that feeds the cache | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`, `PaletteAPIClientTests.swift`, `PaletteAPIClientContractTests.swift` |
| AC-3 | Solver parity test target loading the committed corpus, asserting exact `WeightedSquaredErrorScorer` selection parity incl. ties | Permanent unit test: corpus harness + committed-corpus run (`SolverParityCorpusTests`); corpus-presence test is the red-phase signal | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` |
| AC-4 | Document corpus consumption (location + refresh) | LID doc under `docs/` (README insertion happens with the implementation run; `README.md` is outside this phase's allowlist) | `docs/solver-parity-corpus.md` |
| AC-5 | PR description records migration notes, `/api/v1` shape findings, parity results | Checklist scaffold prepared in docs for the implementation run to fill with actual findings | `docs/openapi-generated-client.md` |
| AC-6 | Exit criterion: `swift test` green with corpus test + generated client; cache/offline behavior verified | Cannot be satisfied in this phase by design (implementation is a separate run); no Swift toolchain exists in this container, so results recorded as not run here | `tmp/paid-agent-verification.json` |

## Expected state at this PR head (red phase)

- `SolverParityCorpusTests.testCommittedCorpusExists` — **fails**: the
  corpus from viamin/color_matching#111 is not committed yet (dependency
  not merged). This is the missing-behavior signal.
- `SolverParityCorpusTests` corpus-run/coverage tests — skip while the
  corpus is absent; the harness self-checks are green against
  hand-computed cases (including the Elixir doctest, a tie, exclusions,
  zero-weight handling, and an all-excluded target) and a mutation test
  proves the harness can fail.
- `OpenAPIClientMigrationTests` — **fails**: manifest lacks the OpenAPI
  packages; no spec is committed (depends on viamin/color_matching#110).
- `PaletteAPIClientContractTests` — green against the current
  hand-rolled client; these are the acceptance contract for the
  migration.

## Notes

- The parity corpus path, schema, tie semantics, and refresh procedure
  are specified in `docs/solver-parity-corpus.md`; the corpus is consumed
  as a black-box fixture, so the implementation run only needs to commit
  the upstream-generated file (no production code changes for AC-3).
- Ties are asserted twice: scorer-level (earliest rankable winner) and
  solver-level (1×1-grid `CompositionSolver.solve`), since the solver's
  contiguous fast path re-implements selection and could drift from the
  scorer protocol.
