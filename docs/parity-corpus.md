# Solver parity corpus consumption

This package's `WeightedSquaredErrorScorer` (and the `CompositionSolver` fast
path) deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError`
solver and the earliest-wins selection of `ColorMatching.IlluminantMatching` so
the macOS client and the `color_matching` server always agree on color
selection. The **solver parity corpus** is the shared source of truth that
catches silent divergence in tie-breaking, missing-measurement exclusion, or
channel weighting.

> Note: the issue asks for this guide to live in (or be linked from) the
> top-level `README.md`. This document is the canonical copy; the README link
> is added when the implementation change lands.

## Where the corpus lives

- **Upstream (source of truth):** [`viamin/color_matching`](https://github.com/viamin/color_matching)
  commits the corpus at `priv/parity/v1/corpus.json` (issue #111, PR #112).
  Upstream regenerates it with `mix parity.generate`, and its CI proves the
  committed bytes are byte-identical to a fresh build with
  `mix parity.generate --check`.
- **This repo (vendored copy consumed by tests):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`

The copy is vendored because the `color_matching` gitlink in this repo is not
initialized as a submodule — tests must run from this checkout alone.

## How the corpus is consumed

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
decodes the fixture and replays every scenario through the Swift solver:

1. **Score tables** — every palette candidate is scored with
   `WeightedSquaredErrorScorer` against the scenario target and weights; the
   result must match the recorded per-candidate score exactly, including the
   `"excluded"` marker for missing-measurement exclusions.
2. **Selection** — the earliest-wins argmin must equal the recorded
   `selected_index` / `selected_hex_color`, with the recorded winning `error`.
3. **Ties** — the set of indices tied at the winning score must equal
   `tied_indices`, `tie_broke` must agree, and the *earliest* tied index must
   be the one selected.
4. **Solver fast path** — each scenario (whose target can be expressed as
   source grids) also replays through `CompositionSolver` as a 1×1 output;
   selection, per-cell error, and excluded-candidate count must match.

Unknown weight keys (e.g. the corpus's `ultraviolet` scenario) are ignored,
matching the server's treatment of unknown light sources.

## Refreshing the corpus

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Refresh whenever the upstream corpus changes. The corpus is stamped with an
`algorithm_version` (currently `1`); the test pins the version it understands,
so a corpus whose stamp changed fails `testCorpusMetadataMatchesSupportedSolverSemantics`
on purpose — a stamp bump means *every* expectation moved and this client must
be updated (and re-verified) in step, not silently re-baselined.

## Generated OpenAPI client (companion contract)

The second enforced contract from #39 is the API shape. The server publishes
an OpenAPI 3 document at `GET /api/v1/openapi.json` (viamin/color_matching#110,
PR #113). The implementation change for #39 is tracked by
`GeneratedClientAdoptionTests.swift`, which requires:

- `ColorComposerCore/Package.swift` declares `swift-openapi-generator` (plugin)
  and `swift-openapi-runtime` (library),
- the OpenAPI document is committed under `ColorComposerCore/` (outside
  tests/build output),
- generated client sources under `ColorComposerCore/Sources/` import
  `OpenAPIRuntime`, with `PaletteAPIClient` wrapping the generated client.

The migration must not change observable wire behavior: URLs
(`/api/v1/printer_profiles`, `/api/v1/colors?printer_profile_id=N`), the
trimmed bearer token header, the `PaletteAPIError` status mapping, and
snake_case envelope decoding are pinned by `PaletteAPIClientTests.swift`; the
fetch → disk-cache → offline-fallback pipeline (per-server/profile color
caching, offline-stale `fetchedAt` marker, cached profile fallback) is pinned
by `PaletteFetchCachingTests.swift` and `ProfileColorCacheTests.swift`.
