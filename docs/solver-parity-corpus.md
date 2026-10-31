# Solver parity corpus & OpenAPI contract

How this app consumes the two published contracts of the `color_matching`
service: the **solver parity corpus** (viamin/color_matching#112, issue #111)
and the **OpenAPI 3 spec** for `/api/v1` (viamin/color_matching#113, issue #110).

## Solver parity corpus

### Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  [`viamin/color_matching`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json),
  generated deterministically by `mix parity.generate` (byte-identical
  regeneration is enforced in upstream CI). The corpus carries an
  `algorithm_version` stamp (currently `1`); a bump means the algorithm
  changed and client parity must be re-reviewed.
- **Vendored copy (what the tests load):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json` —
  a byte-for-byte copy so `swift test` never needs network access.

### How to refresh the vendored copy

```sh
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json
```

Upstream regeneration is deterministic, so the download only differs when the
algorithm actually changed. After refreshing, run `swift test` —
`SolverParityCorpusTests` will fail loudly if the Swift scorer no longer
agrees with the server's `ColorMatching.WeightedSquaredError`.

### What the parity test enforces

`SolverParityCorpusTests` (`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`):

- **Metadata gate** — `algorithm_version` must be `1`, corpus light sources
  must be exactly the client's `LightingCondition` cases, the missing-policy
  must stay `excluded-when-any-positive-weight-channel-missing`, and
  selection must stay `earliest-index-wins`.
- **Per-candidate scores, exactly** — every scenario's `expected.scores`
  (numbers, or the literal `"excluded"`) must match `WeightedSquaredErrorScorer`
  with exact `==`; all corpus values are exact binary fractions, so any
  mismatch is real drift, not float noise.
- **Selection & tie evidence** — selected index, selected hex, winning error,
  `tied_indices`, and `tie_broke` must match, with earliest-index-wins on
  exact ties (the scenarios intentionally include two-, three-, and
  multi-way ties).
- **Solver fast path** — complete-target scenarios are also replayed through
  `CompositionSolver` on 1×1 grids, so the selection code the app runs (not
  just the scorer) is held to the corpus. Target-side missing channels are a
  scorer-layer concern (source grids always supply values) and are covered by
  the scorer-level replays.

Parity status at the time of vendoring (corpus `algorithm_version` 1):
**12/12 scenarios agree exactly**, including all tie cases, both no-selection
cases, zero-weight-channel handling, and the unknown-light-source weight
("ultraviolet" is ignored, matching the client's fixed `ChannelWeights` fields).

## OpenAPI spec & generated client

The service publishes an OpenAPI 3 spec at `GET /api/v1/openapi.json`
(no auth pipeline on that route). The plan (issue #39) is to add
`swift-openapi-generator` + `swift-openapi-runtime` to `ColorComposerCore`
and generate a typed client from that document, migrating `PaletteAPIClient`
onto it (wrapping it, so disk-cache/offline-stale behavior stays intact).

Until then, `PaletteAPIClientMigrationContractTests` pins the current wire
contract so the migration cannot silently change observable behavior:
exact request paths (`/api/v1/printer_profiles`,
`/api/v1/colors?printer_profile_id=N`), `Accept`/bearer headers, the
401 → `.unauthorized` (re-auth) path, non-2xx → `.badStatus`,
undecodable body → `.malformedResponse`, and envelope decoding — including
the embedded `printer_profile` that feeds the offline cached-profile
fallback. Disk-cache and per-server/profile isolation behavior is pinned by
`ProfileColorCacheTests`.

### `/api/v1` shape findings (vs the published spec, as of upstream #113)

Compared against `ColorMatchingWeb.ApiSchemas` behind
`GET /api/v1/openapi.json`:

- `PrinterProfilesResponse` is `{printer_profiles: [PrinterProfile]}`;
  upstream marks `id`, `printer_make_model`, `paper_type`, `ink_type` all
  **required**. The Swift `PrinterProfileDTO` types the three strings as
  optional — a lenient superset that still decodes every spec-valid payload,
  but the generated client will surface them as non-optional.
- `ColorsResponse` is `{printer_profile, colors}`, both required. Per-color
  required fields are `id`, `name`, `hex`, `palette_id`, `sort_order`,
  `responses`; `rgb` is optional and `palette_name` is nullable — matching the
  optionality `PaletteColorDTO` already assumes. No shape change is required
  for the client to adopt the generated types.
- `responses` is typed upstream only as `object` with
  `additionalProperties: true` — the per-key structure (`brightness`,
  `source`, `raw_value`, …) lives in the app's `ColorResponseDTO`. A wrapper
  around the generated client must keep that hand-written decode (the
  generated client will see an untyped JSON dictionary).
