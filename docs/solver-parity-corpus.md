# Solver parity corpus & generated-client contract — issue #39

This repo consumes two artifacts published by the `color_matching` backend:

1. an **OpenAPI document** for `/api/v1` (viamin/color_matching#110), consumed
   via a generated Swift client, and
2. a **solver parity corpus** (viamin/color_matching#111) that pins
   `WeightedSquaredError` selection behavior.

This document records where each lives in this repo, how to refresh them, and
how the acceptance criteria of issue #39 map to verification.

## Parity corpus

- **Location:** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/solver_parity_corpus.json`
- **Consumed by:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
- **Schema (version 1):** each case carries `weights` (per-channel, `0` =
  inactive), a `target` response vector, an ordered `palette` (id, hex,
  `responses` keyed by light name), and `expected`: `selected_id`
  (`null` when every candidate is excluded), `selected_score`,
  per-candidate `candidate_scores`, and `excluded_ids`.

The test asserts, for every case:

- each candidate's exact score (±1e-9) or its exclusion,
- the winning selection — **ties resolve to the earliest palette entry**,
  matching the Swift solver's strict `<` scan and the Elixir solver's
  first-minimum semantics,
- that the selection also comes out of the production `CompositionSolver`
   fast path on a 1×1 grid (so the corpus pins the real algorithm, not a
  test-side copy), and
- corpus hygiene: schema version, unique case ids, and at least one case of
  each kind — `tie`, `exclusion`, `zero-weight`, `all-excluded`.

### Parity semantics pinned by the corpus

- **Missing ≠ zero:** a candidate missing a required channel is *excluded*,
  never scored as brightness 0 (case `missing-required-response-excludes-candidate`
  makes the excluded candidate the would-be zero-score winner if missing were
  treated as zero).
- **Ties:** earliest palette entry wins, independent of color id (case ids are
  deliberately out of order in the tie case).
- **Weights:** per-channel weights multiply squared differences; weight `0`
  channels are ignored and not required of candidates or targets.
- **Target gaps:** a target missing a required channel excludes every
  candidate (selection `null`, cell left unmatched).
- **Reference value:** the Elixir `WeightedSquaredError` doctest total `0.205`
  is reproduced exactly.

### Refreshing the corpus

The committed file is a **hand-authored placeholder** built from the mirror
semantics above (upstream PR viamin/color_matching#111 was not yet published —
404 as of 2026-10-31). When it lands:

1. Export the corpus from the backend and map it onto schema version 1 (or
   extend the Codable models in `SolverParityCorpusTests.swift` and bump the
   supported `schema_version`).
2. Overwrite `solver_parity_corpus.json`; update `source`/`server_ref` to the
   producing commit/release.
3. `cd ColorComposerCore && swift test` must stay green with **zero assertion
   edits** — any mismatch is a solver-parity regression to investigate, not a
   test to adjust.

## Generated OpenAPI client (implementation-phase notes)

The behavior `PaletteAPIClient` must preserve across the migration to
`swift-openapi-generator`/`swift-openapi-runtime` is pinned by:

- `PaletteAPIClientTests.swift` — endpoints (`GET /api/v1/printer_profiles`,
  `GET /api/v1/colors?printer_profile_id=N`), `Accept: application/json`,
  trimmed bearer token (omitted when blank), `401 → .unauthorized`,
  other non-2xx `→ .badStatus`, undecodable 2xx body `→ .malformedResponse`,
  and envelope decoding (snake_case keys, responses absent-not-zero).
- `APIDecodingTests.swift` — wire-shape decoding including unknown
  light-source keys dropped in domain conversion and hex fallback when `rgb`
  is omitted.
- `ProfileColorCacheTests.swift` (69 tests) — per-server/profile disk cache,
  namespace normalization, corrupt-file misses, and cached-profile fallback
  used for offline-stale badges. Untouched by the migration: `ProfileColorCache`
  consumes DTOs, not the transport.

`/api/v1` shape observations for the PR description: the current wire contract
shows **no shape changes needed** — envelopes are
`{"printer_profiles": [...]}` and `{"colors": [...], "printer_profile": {...}}`,
and `responses` is a map keyed by light-source name where absence means
"unmeasured". The implementation phase adds the OpenAPI document +
`swift-openapi-generator` plugin/`swift-openapi-runtime` dependency to
`ColorComposerCore/Package.swift` (out of scope for the tests-only run that
committed this file) and either migrates or wraps `PaletteAPIClient` so the
DTO surfaces — and therefore the cache layer — stay byte-compatible.

## Acceptance-criterion verification map

| Criterion | Verification |
| --- | --- |
| Generated OpenAPI client; `PaletteAPIClient` migrated | Contract pinned by `PaletteAPIClientTests` (+ `APIDecodingTests`); wiring lands in the implementation phase |
| Behavior preserved (cache, offline-stale, fallback) | `ProfileColorCacheTests` (pre-existing, 69 tests) + client contract tests above |
| Solver parity corpus test target | `SolverParityCorpusTests` + `Fixtures/parity/` corpus |
| Corpus documented (README) | This file + `Fixtures/parity/README.md`; README.md section lands with the implementation phase |
| PR records migration notes & parity findings | Sections above
