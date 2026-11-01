# Solver parity corpus & OpenAPI document consumption

This app holds two unenforced contracts with the `color_matching` server
(viamin/color_matching): the solver must agree with the server's
`WeightedSquaredError` selection, and the palette client must speak the
server's `/api/v1` wire format. Both are now pinned in
`ColorComposerCore/Tests` (issue #39).

## Solver parity corpus

**Where it lives (source of truth):**
[`viamin/color_matching`](https://github.com/viamin/color_matching) commits the
corpus at [`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json)
(generated upstream by `mix parity.generate`, viamin/color_matching#112). It is
stamped with `algorithm_version: 1`, `scorer: ColorMatching.WeightedSquaredError`,
`selection: earliest-index-wins`, and
`missing_policy: excluded-when-any-positive-weight-channel-missing`.

**How this repo consumes it:** the corpus is committed verbatim as the raw
string constant `ParityCorpusV1Data.json` in
`ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpusV1Data.swift`
(byte-identical to the upstream file, so a refresh is a plain diff), decoded by
`ParityCorpus` (`ParityCorpus.swift`), and replayed by
`SolverParityCorpusTests`:

- every scenario's per-candidate scores must match **exactly** (corpus values
  are dyadic rationals, so exact double equality is meaningful),
- the selected index / selected hex must match, including **tie cases**
  (earliest-index-wins, 4 dedicated tie scenarios),
- missing-measurement **exclusions** must match (missing channel ⇒ excluded,
  never treated as zero brightness; target-side missing ⇒ no selection),
- **zero-weight channels** neither exclude nor contribute, and **unknown
  weight sources** (e.g. `ultraviolet`) are ignored,
- the full `CompositionSolver` pipeline (1×1 grids) must land on the same
  selection as the scorer for every scenario with a complete target vector.

**How to refresh:**

```bash
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json
# replace the raw string in ParityCorpusV1Data.swift with the fetched bytes (verbatim)
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

A changed `algorithm_version` stamp (or an upstream `v2` corpus directory) is a
deliberate contract change: the metadata test fails loudly until the corpus and
— if the algorithm changed — the scorer are consciously updated. Never edit the
corpus locally to make a failing parity test pass; the corpus is only ever
regenerated upstream.

**Parity status (v1, 12 scenarios):** all scenarios pass exactly — ties break
earliest-index-wins, exclusions match the
`excluded-when-any-positive-weight-channel-missing` policy, zero-weight and
unknown-source weights behave as above, and the solver pipeline agrees with the
scorer on every selection. No divergence found.

## OpenAPI document (generated client)

The server publishes an OpenAPI 3 spec at `GET /api/v1/openapi.json`
(viamin/color_matching#110, closed by #113) with a `bearerAuth` security
scheme. The app vendors the document at
`ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json` and
generates a typed client via `swift-openapi-generator` (build plugin) +
`swift-openapi-runtime`, with `PaletteAPIClient` migrated onto it (or wrapping
it) — pinned by `OpenAPIClientAdoptionTests`; the behavioral contract the
migration must preserve (URLs, `printer_profile_id` query, headers, envelope
decoding, `PaletteAPIError` mapping) is pinned by `PaletteAPIClientContractTests`.

**How to refresh the document:**

```bash
# with a color_matching server running locally
curl -fsSL http://localhost:4000/api/v1/openapi.json \
  -o ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json
cd ColorComposerCore && swift test
```

**/api/v1 shape findings vs. the current hand-rolled client** (recorded for the
issue #39 PR description):

- `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=N`
  shapes are unchanged; both remain snake_case with bearer auth — no wire
  change required for the migration.
- The spec's `ColorsResponse` marks `printer_profile` as **required**; the
  Swift DTO decodes it as optional. Benign client-side widening — no action.
- Upstream `responses` is `additionalProperties: true`; the Swift DTO types
  each entry as `ColorResponseDTO` with a required numeric `brightness`, so a
  response object lacking `brightness` fails the whole envelope decode
  (existing behavior, surfaced here for the record).
- A newer route `GET /api/v1/printer_profiles/:id/colors` exists with a
  *different*, minimal shape (`ProfileColorsResponse`). It is **not** adopted —
  a non-goal of issue #39; the app keeps `GET /api/v1/colors`.
