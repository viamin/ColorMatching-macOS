# Solver parity corpus consumption

The macOS client's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver, and `CompositionSolver`'s
deterministic selection mirrors `ColorMatching.IlluminantMatching.best_match/4`
(lowest score wins, earliest palette index wins ties). The
[`color_matching`](https://github.com/viamin/color_matching) server publishes a
deterministic golden-vector corpus that both test suites replay so silent
divergence — in tie-breaking, missing-measurement exclusion, or channel
weighting — is caught by CI on either side.

## Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  `viamin/color_matching`, added by
[color_matching#112](https://github.com/viamin/color_matching/pull/112)
(commit [`a82aec5`](https://github.com/viamin/color_matching/commit/a82aec5441d2a7b0100e8c8ab81d573e11ace9b0)).
  Regenerate upstream with `mix parity.generate`; upstream CI verifies the
  committed bytes with `mix parity.generate --check`.
- **This repo (vendored copy):** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`,
  byte-identical to the upstream file, consumed by
  `SolverParityCorpusTests` in the same directory.

## What the parity test asserts

`SolverParityCorpusTests` loads the vendored corpus and, for every scenario:

1. **Metadata** — `algorithm_version` (currently `1`), scorer name
   (`ColorMatching.WeightedSquaredError`), selection policy
   (`earliest-index-wins`), and missing-data policy
   (`excluded-when-any-positive-weight-channel-missing`) match what this client
   implements. When `algorithm_version` changes upstream, every expectation in
   the corpus has moved: refresh the fixture and the pinned version together.
2. **Score table** — every palette color re-scored through
   `WeightedSquaredErrorScorer` matches the recorded score exactly, including
   `"excluded"` outcomes for missing measurements on positive-weight channels.
3. **Selection** — the earliest-index-wins winner matches `selected_index`,
   `selected_hex_color`, `error`, `tie_broke`, and `tied_indices` exactly,
   including the corpus's deliberate tie scenarios.
4. **Solver fast path** — scenarios whose target carries every
   positive-weight channel are replayed through `CompositionSolver` with a
   1×1 grid, pinning the optimized path (and `excludedCandidateCount`) the app
   actually runs. A corpus scenario whose *target* is missing an active channel
   cannot be expressed through the solver (source grids always supply a target
   value), so that policy is covered at the scorer level.

The test also guards the corpus itself: a refreshed corpus must still contain
at least one tie case, one exclusion case, and one no-selection case, and its
palette indices and score tables must be self-consistent.

Scores are compared with exact `==`. All corpus magnitudes are dyadic
rationals (channel values in eighths/sixteenths, weights in quarters), so every
partial sum is exactly representable and summation order cannot change the
result. Exact equality *is* the parity contract — do not loosen it, and keep
corpus values dyadic-friendly when adding scenarios upstream.

Weight keys outside the five canonical light sources (e.g. the corpus's
`ultraviolet` entry) are dropped before scoring, mirroring the Elixir
`filter_weights/1` and the client's fixed `LightingCondition` set.

## How to refresh the vendored corpus

The fixture must stay byte-identical to upstream. To trial a freshly
downloaded corpus without committing it:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o /tmp/corpus.json

PARITY_CORPUS_PATH=/tmp/corpus.json swift test \
  --filter SolverParityCorpusTests   # run from ColorComposerCore/
```

To adopt it, copy the same bytes over the fixture and commit:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

The `algorithm_version` metadata test fails loudly after a semantics change
upstream; treat that as a coordinated update, not a one-line fixture bump.

## Related: OpenAPI document and the API client migration (#39)

`color_matching` publishes an OpenAPI 3 document at `GET /api/v1/openapi.json`
([color_matching#113](https://github.com/viamin/color_matching/pull/113)).
The plan tracked by issue #39 is to generate a typed client from that document
(`swift-openapi-generator` + `swift-openapi-runtime`) and migrate
`PaletteAPIClient` onto it without changing observable behavior.

The wire contract that migration must preserve is pinned by
`PaletteAPIClientTests`:

- endpoints `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=N`,
- `Accept: application/json`, `Authorization: Bearer <trimmed-token>` (omitted
  for missing/blank tokens),
- envelope keys `printer_profiles` / `colors` / `printer_profile` with
  snake_case fields (a missing `printer_profile` key decodes as `nil`),
- and the error mapping: HTTP 401 → `unauthorized`, other non-2xx →
  `badStatus`, undecodable 2xx body → `malformedResponse`.

The disk cache and offline fallback that sit behind the client — per
`(server, profile)` color caching, stale-fetched-at markers, and the cached
profile picker fallback — are covered by `ProfileColorCacheTests` and must
remain green through the migration. A `/api/v1` shape audit at the time of
writing found no differences between the published spec and the shapes the
client decodes today.

### Implementation note

The vendored corpus is read from disk (resolved relative to the test source
file), so no resource declaration is required; SwiftPM may print an
"unhandled file" warning for `Fixtures/` until `Package.swift` declares it:

```swift
.testTarget(
    name: "ColorComposerCoreTests",
    dependencies: ["ColorComposerCore"],
    path: "Tests/ColorComposerCoreTests",
    resources: [.copy("Fixtures")]
)
```

The same `Package.swift` edit is the natural place to add the
`swift-openapi-*` plugin/dependency for the generated client.

## Acceptance-criteria → verification map (#39)

| Criterion | Smallest credible verification |
| --- | --- |
| Generated OpenAPI client; `PaletteAPIClient` migrated (or wrapped) | Wire-contract pins in `PaletteAPIClientTests` (paths, query, headers, envelope keys, error mapping) stay green through the migration |
| Per-server/profile color caching, offline-stale badges, cached profile fallback | Existing `ProfileColorCacheTests` suite (disk cache, `(server, profile)` keying, staleness marker `fetchedAt`, corrupt/foreign-server misses) stays green; app-side orchestration in `ColorCatalog` unchanged by the wrap |
| Solver parity test replaying the committed corpus, ties included | `SolverParityCorpusTests` (this document): scores, selection, tie evidence, exclusions, solver fast path — exact equality |
| README documents corpus consumption | Link this document from `README.md` (implementation phase; README edits are outside the tests-only phase allowlist) |
| PR records migration notes, `/api/v1` shape findings, parity results | This document records the shape audit (no differences found between the published spec and the shapes decoded today); parity results: all 12 scenarios replay exactly (5 tie cases, 2 no-selection cases, 4 exclusion cases) |
