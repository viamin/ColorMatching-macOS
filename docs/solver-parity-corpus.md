# Solver parity corpus & the `/api/v1` OpenAPI contract

This document describes how ColorMatching-macOS consumes the two published
contracts of the `color_matching` backend: the **solver parity corpus** and
the **OpenAPI 3 specification of `/api/v1`**. It is the companion to issue
#39 ("Adopt generated OpenAPI client and enforce solver parity with the
parity corpus").

## Solver parity corpus

### Where it lives

| What | Where |
| --- | --- |
| Committed fixture (this repo) | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json` |
| Upstream source of truth | `priv/parity/v1/corpus.json` in [viamin/color_matching](https://github.com/viamin/color_matching) (added by PR [#112](https://github.com/viamin/color_matching/pull/112)) |
| Parity tests | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` |
| Upstream counterpart | `test/color_matching/parity/corpus_test.exs`, generator `lib/color_matching/parity/corpus.ex` |

The fixture is a **byte-identical** copy of the upstream corpus (v1,
`algorithm_version: 1`, 12 scenarios; SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
Upstream CI regenerates the corpus with `mix parity.generate --check` and
fails on any drift, so a byte-identical copy here is provably in sync with
the Elixir solver at the pinned upstream commit.

### What the corpus contains

Each scenario carries a palette of response vectors (absent channel keys mean
*missing*, never zero), a target vector, per-channel weights (unknown light
sources such as `ultraviolet` must be ignored), and the expected outcome:

- per-candidate scores — a number, or the string `"excluded"`
- `selected_index` / `selected_hex_color` / `error` (`null` when every
  candidate is excluded)
- tie evidence: `tied_indices` (every index achieving the minimum score) and
  `tie_broke`

Corpus-level metadata pins the semantics under test:

```json
{
  "algorithm_version": 1,
  "scorer": "ColorMatching.WeightedSquaredError",
  "selection": "earliest-index-wins",
  "missing_policy": "excluded-when-any-positive-weight-channel-missing",
  "light_sources": ["white", "red", "green", "blue", "lps"]
}
```

### What the Swift tests assert

`SolverParityCorpusTests` mirrors the upstream Elixir replay test and adds a
solver-level replay:

1. **Corpus contract** — metadata matches the values above; scenario ids stay
   unique; tie, exclusion, and null-selection coverage never silently
   disappears.
2. **Scorer replay** — every candidate is scored with
   `WeightedSquaredErrorScorer` and compared with *exact* `Double` equality
   (corpus values are dyadic rationals, so any divergence is a real semantic
   change, not float noise). Selection uses strict less-than so **the
   earliest index wins ties**, and `tied_indices` is recomputed from the
   scores and must match the corpus exactly.
3. **Solver replay** — every scenario whose target is complete runs through
   `CompositionSolver` with 1×1 brightness grids, pinning the optimized fast
   path (the code the app actually runs) to the same selection and error, and
   asserting unmatched cells record infinite error. (A `BrightnessGrid`
   cannot represent "missing", so the intentionally target-missing scenario
   `missing-target-excluded` is covered at the scorer level only.)

### Refreshing the corpus

```bash
# in a checkout of viamin/color_matching at the commit you want to pin
mix parity.generate          # regenerate priv/parity/v1/corpus.json
mix parity.generate --check  # CI uses this; must be byte-identical

# then copy byte-for-byte into this repo
cp priv/parity/v1/corpus.json \
   ColorMatching-macOS/ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json
```

Rules of thumb:

- Upstream bumps `algorithm_version` whenever solver semantics change. If the
  metadata test fails after a refresh, re-review parity of
  `WeightedSquaredErrorScorer` / `CompositionSolver` against the new corpus
  *before* updating expectations — a failing replay is the signal that the
  mirrored algorithm drifted.
- Never hand-edit the fixture; only copy a freshly generated one.
- Keep the copy byte-identical (no reformatting) so `diff` against upstream
  is meaningful.

## Generated OpenAPI client (issue #39 deliverable)

The server publishes an OpenAPI 3 spec for `/api/v1` (upstream PR
[#113](https://github.com/viamin/color_matching/pull/113), served
unauthenticated at `GET /api/v1/openapi.json`, generated from
`ColorMatchingWeb.ApiSpec` via OpenApiSpex).

### Migration contract enforced by tests

`OpenAPIClientMigrationTests` defines the canonical layout the migration must
follow:

- `ColorComposerCore/Package.swift` declares both **swift-openapi-generator**
  (build-tool plugin) and **swift-openapi-runtime** (dependency).
- The OpenAPI document is committed at
  `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}`
  and describes the two operations `PaletteAPIClient` consumes
  (`printer_profiles`, `colors`).
- The wire shapes the disk cache depends on keep decoding (snake_case keys,
  nullable `rgb` / `palette_name`, free-form `responses` map), and the client
  keeps issuing `GET /api/v1/printer_profiles` and
  `GET /api/v1/colors?printer_profile_id=N` with `Accept: application/json`
  and a trimmed bearer token.

### Refreshing the vendored OpenAPI document

```bash
# from a running server (no auth required for this endpoint)
curl -o ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json \
  http://localhost:4000/api/v1/openapi.json

# or from a color_matching checkout without starting a server
MIX_ENV=test mix openapi.spec.json --spec ColorMatchingWeb.ApiSpec \
  --start-app=false --filename openapi.json
```

Then regenerate the client (`swift package generate-code` if using the
plugin's manual mode, or simply rebuild — the plugin runs as a build step).

### `/api/v1` shape findings (recorded for the PR description)

Findings from the published spec (`lib/color_matching_web/api_schemas.ex`)
vs. the hand-written DTOs in `APIModels.swift`:

- `ColorsResponse.colors[].rgb` is optional in the spec, and the controller
  emits `"rgb": null` when a stored hex cannot parse — the generated client
  must treat `rgb` as nullable/optional (the hand-written `RGBDTO?` already
  does).
- `palette_name` is explicitly `nullable: true`; `palette_id` and
  `sort_order` are required (the client is deliberately more lenient).
- `PrinterProfile` fields (`printer_make_model`, `paper_type`, `ink_type`)
  are required, non-nullable strings.
- `responses` is a free-form object (`additionalProperties: true`) whose keys
  are light-source names; absent keys mean *missing measurement* — the
  foundation of the exclusion policy above.
- The spec also covers endpoints the app does **not** consume (`palettes`,
  per-profile colors, `metamer_pairs`, captures, measurement uploads).
  Consuming them is out of scope for issue #39.
