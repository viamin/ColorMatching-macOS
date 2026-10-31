# Issue #39 — Verification Plan (tests-first run)

Adopt the generated OpenAPI client and enforce solver parity with the parity
corpus. This run is the **test-writing phase**: it commits the parity corpus,
the corpus-consuming test target, red structural tests for the generated-client
artifacts, wire-contract pinning tests for `PaletteAPIClient`, and this plan.
Implementation (Package.swift deps, OpenAPI document, generated client,
`PaletteAPIClient` migration, README section) lands in the follow-up
implementation run after `paid-tests-approved`.

## Acceptance criteria → smallest credible verification

| AC | Criterion | Verification | Kind | Artifact (this run) | Status at this head |
|----|-----------|--------------|------|---------------------|---------------------|
| AC-1 | `swift-openapi-generator` + `swift-openapi-runtime` in `ColorComposerCore`; typed client generated from the OpenAPI document; `PaletteAPIClient` migrated (or wraps it) | Structural red tests that fail until the artifacts exist (manifest wiring, committed spec, generator config) **plus** behavioral pinning of the client's public wire contract that must stay green through the migration | unit test (structural + behavioral) | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientContractTests.swift` (red), extended `PaletteAPIClientTests.swift` (green) | red — missing behavior demonstrated by failing tests |
| AC-2 | Preserve behavior: per-server/profile color caching, offline-stale badges, cached profile fallback | Existing permanent suite already pins the cache contract; new tests pin the API-client wire contract (errors, token, envelope shapes) the migration must not change | unit test | `ProfileColorCacheTests.swift` (existing), `PaletteAPIClientTests.swift` (existing + new) | pinning tests green; "unchanged through migration" only settleable post-migration |
| AC-3 | Solver parity test target loading the committed corpus; selections match exactly incl. ties | New permanent test target loads `Fixtures/solver_parity_corpus.json` and asserts per-target selected color id, score, excluded count, and unmatched cells at both scorer level and solver (fast-path) level | unit test (recurring parity rule — permanent) | `SolverParityCorpusTests.swift` + corpus fixture | committed; not executed here (no Swift toolchain in container — see Environment) |
| AC-4 | Document corpus consumption in README | `docs/solver-parity-corpus.md` carries the full content (location, schema, refresh); README link is a one-line edit deferred to the implementation run (README.md is outside this run's allowlist) | documentation | `docs/solver-parity-corpus.md` | docs written; README edit deferred |
| AC-5 | PR description records migration notes, `/api/v1` shape findings, parity results | Human/external criterion — PR body is written when the PR opens. A structured notes template is committed so findings are inspectable | human/external evidence | notes template in this file (below) | not run (PR not yet opened) |

## Environment

This container has **no Swift toolchain** (`bin/lint` detects this and skips
the build). `swift test` cannot be executed here. The committed tests are
expected to compile and pass on a macOS host (or Linux for the portable
subset); the corpus fixture arithmetic was cross-checked with an independent
Python mirror of `WeightedSquaredError` (see
`docs/solver-parity-corpus.md`).

## PR description notes template (fill in during implementation run)

```markdown
## Generated-client migration notes
- Dependencies added: swift-openapi-generator <ver>, swift-openapi-runtime <ver>
- OpenAPI document committed at: <path> (source: viamin/color_matching#110)
- Generated types: <path or "build-time via OpenAPIGenerator plugin">
- PaletteAPIClient now: <wraps generated Client / replaced by generated client>
- Disk-cache/offline-stale behavior preserved: <how verified>

## /api/v1 shape changes found
- <field/endpoint deltas between the handwritten DTOs and the published spec, or "none">

## Parity test results
- Corpus: <N> cases, <M> targets from viamin/color_matching#111 (ref <commit/tag>)
- swift test result: <green summary>
- Ties: <earliest-wins confirmed / deltas found>
- Exclusions: <missing-measurement exclusion confirmed; measured-zero participates>
- Weight handling: <zero-weight channels ignored; fractional weights match doctest 0.205>
```

## Non-goals respected

The solver algorithm and scorer semantics are untouched; no new API surfaces
beyond what `PaletteAPIClient` uses today are introduced by these tests.
