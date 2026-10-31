# Solver parity corpus

The macOS app's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching), including the
`IlluminantMatching.best_match/3` selection policy (lowest score wins, the
earlier palette index wins exact ties). The parity corpus is the shared
source of truth that keeps the two implementations from silently diverging.

## Where the corpus lives

- **Upstream (authoritative):** [`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json)
  in the `color_matching` repository, generated deterministically by
  `mix parity.generate` (landed via viamin/color_matching#112, the parity
  corpus dependency of this issue). The server's CI verifies the committed
  bytes against a fresh generation.
- **This repo (committed fixture):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json`
  — a byte-identical copy of the upstream file. The fixture is verified by
  its SHA-256 on refresh; do not edit it by hand.

## What the parity test asserts

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
replays every corpus scenario and asserts **exact** agreement (scores are
compared with `==`, not a tolerance — all corpus values are exact binary
fractions, so both languages compute bit-identical doubles):

- per-candidate scores, including the `"excluded"` marker for
  missing-measurement exclusion on any positive-weight channel,
- the selected palette index and hex color (earliest-index-wins ties),
- the winning error, `tied_indices`, and `tie_broke` evidence,
- the same selection when replayed through `CompositionSolver`'s fast path
  (a 1×1 grid per scenario) for every scenario whose target the solver can
  represent,
- that unknown light-source weights (e.g. `ultraviolet`) are ignored, matching
  the Elixir `filter_weights/1` step.

## Refreshing the corpus

The corpus only moves when the server's solver semantics change; upstream
bumps `algorithm_version` (currently `1`) when that happens.

```bash
curl -fo ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json
```

After refreshing, update the expected `algorithmVersion` and the pinned
tie/no-selection scenario ids in `SolverParityCorpusTests.swift` if they
changed, then run:

```bash
cd ColorComposerCore && swift test
```

A failing parity test after a refresh means this app's scorer genuinely
diverges from the server's new semantics — fix the app side (never the
fixture) or coordinate a semantics change with the server repo.

## `/api/v1` shape notes (from the published OpenAPI spec)

The server publishes an OpenAPI 3 document at `GET /api/v1/openapi.json`
(viamin/color_matching#113; schemas in `ColorMatchingWeb.ApiSchemas`).
Findings relevant to this app, recorded for the generated-client migration:

- Endpoints this app uses are documented as `GET /api/v1/printer_profiles`
  and `GET /api/v1/colors` (query `printer_profile_id`), both under the
  `bearerAuth` security scheme. Both are JSON-only (`Accept: application/json`).
- The colors envelope marks **`printer_profile` as required**; the app
  decodes it as optional and tolerates its absence (pinned by
  `OpenAPIContractTests`/`PaletteAPIClientTests`). No action needed for the
  migration, but the generated types will model it as non-optional — the
  wrapper must keep accepting an omitted profile.
- Color items require `id`, `name`, `hex`, `palette_id`, `sort_order`,
  `responses`; `rgb` and `palette_name` are optional. The app's DTOs already
  treat exactly `rgb`/`palette_name` (plus `name` in practice) leniently.
- The `light_source` enum is `white|red|green|blue|lps`, matching
  `LightingCondition` raw values.

This document covers corpus consumption for the test-writing phase; the
generated OpenAPI client wiring (`swift-openapi-generator` +
`swift-openapi-runtime`, and the README section pointing here) lands with the
implementation change.
