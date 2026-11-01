# Solver parity corpus & OpenAPI contract consumption

Issue #39 connects this app to `color_matching` through two enforceable
contracts. This note records where each artifact lives in this repository and
how to refresh it; the README carries the user-facing summary of the same
information.

## Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver. The parity corpus published by
`color_matching` (viamin/color_matching#111) is vendored byte-for-byte at:

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/corpus.v1.json
```

`SolverParityCorpusTests` loads that file and replays every scenario through
`WeightedSquaredErrorScorer`, asserting per-candidate scores, exclusions,
selection, ties, and winning errors match the expected Elixir output exactly.

### Corpus shape (v1)

- Top-level metadata pins the contract the corpus exercises:
  `algorithm_version: 1`, `scorer: "ColorMatching.WeightedSquaredError"`,
  `selection: "earliest-index-wins"`,
  `missing_policy: "excluded-when-any-positive-weight-channel-missing"`,
  and the canonical `light_sources` list.
- Each scenario has `id`, `description`, `weights` (a light-source → weight
  map; unknown keys such as `ultraviolet` are ignored, mirroring wire
  decoding), `palette` (entries of `index`, `hex_color`, `channels`; an absent
  channel key means *unmeasured*, not zero), `target` (`channels`, may itself
  be missing a required channel), and `expected`:
  - `scores` — per-index score, either a number or the string `"excluded"`
  - `selected_index` / `selected_hex_color` / `error` — `null` when every
    candidate is excluded
  - `tied_indices` — every index achieving the minimum score
  - `tie_broke` — whether selection needed the earliest-index-wins rule

The committed corpus covers: distinct errors, three tie shapes, candidate- and
target-side exclusions, zero-weight channels, all-excluded, single-channel
weights, exact matches, unknown weight keys, and a large mixed palette. The
coverage test keeps those categories present if the corpus is regenerated.

### Refreshing the corpus

The corpus is generated upstream (`mix parity.generate` in `color_matching`)
and committed here so tests stay hermetic. To refresh:

```bash
curl -sS https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/corpus.v1.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If `algorithm_version` changes upstream, the metadata test fails on purpose:
review the generator diff, refresh the vendored copy, and update this note
together. A candidate corpus can be tried before committing by pointing
`COLOR_MATCHING_PARITY_CORPUS` at it:

```bash
COLOR_MATCHING_PARITY_CORPUS=/tmp/corpus.candidate.json swift test --filter SolverParityCorpusTests
```

## OpenAPI document and generated client

`PaletteAPIClient`'s `/api/v1` surface is generated from the OpenAPI document
published by `color_matching` (viamin/color_matching#110, built with
OpenApiSpex from the Phoenix routes) using `swift-openapi-generator` +
`swift-openapi-runtime`. The document is committed inside the package
(canonical location: `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`)
so the client builds hermetically; refresh it from a running server or via the
upstream `mix openapi.spec.json` task.

Two guardrails keep the migration honest:

- `GeneratedOpenAPIClientAdoptionTests` — the package manifest declares the
  generator plugin/runtime and the OpenAPI document stays committed.
- `PaletteAPIClientTests` — the wire contract (paths under `/api/v1`, the
  `printer_profile_id` query, `Accept`/`Authorization` headers, 401/bad-status/
  malformed-response error mapping, envelope decoding) is unchanged by the
  migration, as is the disk cache and offline-stale behavior covered by
  `ProfileColorCacheTests`.
