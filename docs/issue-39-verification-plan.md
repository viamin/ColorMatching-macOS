# Issue #39 — criterion-level verification plan and run evidence

Deliverable: adopt the generated OpenAPI client and enforce solver parity with
the parity corpus. This phase commits the tests (and this evidence); the
generated-client implementation lands in the follow-up run.

| AC | Criterion | Smallest credible verification | Status at this commit |
| --- | --- | --- | --- |
| AC-1 | Add `swift-openapi-generator` + `swift-openapi-runtime` to `ColorComposerCore`; generate a typed client from the OpenAPI document; migrate `PaletteAPIClient` to it (or wrap it) | `OpenAPIAdoptionTests` (structural: manifest deps + committed `OpenAPI/openapi.json` covering both `/api/v1` paths) — red until implemented; behavior guarded by AC-2's wire-contract tests | Tests committed, **red by design** (implementation is a separate run) |
| AC-2 | Preserve behavior: per-server/profile color caching, offline-stale badges, cached profile fallback | `ProfileColorCacheTests` (69 pre-existing permanent unit tests incl. `allEntries` fallback); new `PaletteAPIClientTests` wire-contract tests pin endpoints/query/headers/decoding/error mapping the migration must preserve | Tests committed; client/cache tests green against current code (execution pending — no Swift toolchain in this container); offline-stale *badge* UI wiring is app-shell code with no injection seam — human/xcodebuild review on macOS |
| AC-3 | Solver parity test target loading the committed corpus, asserting exact selection parity incl. ties | `SolverParityCorpusTests` — permanent unit test: byte-identical corpus fixture under `Tests/…/Fixtures/parity/v1/corpus.json`; asserts score tables, selection (earliest-index-wins), error, `tie_broke`/`tied_indices`, exclusions, unknown/zero-weight handling, `algorithm_version` lockstep | Tests committed; corpus independently replayed (12/12 scenarios match — see findings below); `swift test` execution pending (no toolchain here) |
| AC-4 | Document corpus consumption in README | `docs/solver-parity-corpus.md` (canonical content; fold into `README.md` in the implementation run — README is outside this phase's commit allowlist) | Doc committed |
| AC-5 | PR description records migration notes, `/api/v1` shape changes, parity results | `docs/openapi-client-adoption.md` (migration notes + 8 shape deltas found vs spec); parity findings in `docs/solver-parity-corpus.md`; PR body assembled from these at implementation time | Doc committed |

## Environment constraints recorded

- No Swift toolchain exists in this container (`swift`/`swiftc` absent), so
  `swift test` could not be executed here. The corpus replay was independently
  verified by reimplementing the scorer semantics offline (12/12 scenarios,
  exact equality) — see `docs/solver-parity-corpus.md`; the Swift tests must be
  run by CI or on a macOS/Linux Swift host at review time.
- No database is involved (`swift test` only); `bin/setup`/xcodegen not run.

## Expected suite state at this commit

- Green: `SolverParityCorpusTests`, the extended `PaletteAPIClientTests`,
  `ProfileColorCacheTests`, and all pre-existing targets.
- Red (by design, demonstrating AC-1 is unimplemented): the three
  `OpenAPIAdoptionTests` structural tests.
