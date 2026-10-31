# Solver parity corpus

`ColorComposerCore`'s `WeightedSquaredErrorScorer` deliberately mirrors the
Elixir `ColorMatching.WeightedSquaredError` solver on the `color_matching`
server. The parity corpus is the shared source of truth both test suites
replay, so silent divergence — tie-breaking, missing-measurement exclusion, or
channel weighting — is caught on either side (issue #39).

## Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  [viamin/color_matching](https://github.com/viamin/color_matching), generated
  deterministically by `ColorMatching.Parity.Corpus` and verified byte-stable
  by upstream CI (`mix parity.generate --check`). Introduced by upstream PR
  #112 (tracked as #111 in this repo's issue).
- **This repo (committed fixture):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
  — a byte-identical copy consumed by `SolverParityCorpusTests`.

## Corpus contract

Top-level stamps (asserted by `testCorpusIsStampedWithTheCurrentContract`):

| Key | Value |
| --- | --- |
| `algorithm_version` | `1` |
| `scorer` | `ColorMatching.WeightedSquaredError` |
| `selection` | `earliest-index-wins` |
| `missing_policy` | `excluded-when-any-positive-weight-channel-missing` |
| `light_sources` | `white, red, green, blue, lps` (canonical order) |

Each scenario carries a `weights` map (unknown light sources are ignored), a
`target` vector and `palette` vectors as `channels` maps (an absent channel
means *unmeasured*, never zero brightness), and `expected` results:
per-candidate `scores` (a number, or the string `"excluded"`), the winning
`selected_index` / `selected_hex_color` / `error`, and tie evidence
(`tie_broke`, `tied_indices`).

All values are dyadic rationals, so every assertion in the Swift replay uses
exact `Double` equality — no tolerance. When the corpus moves to
`algorithm_version: 2` (i.e. solver semantics changed upstream), upstream
relocates it to `priv/parity/v2/`; mirror the new directory here, bump the
fixture path and loader path in `SolverParityCorpusTests`, and update this
document.

## How the tests consume it

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
mirrors upstream `test/color_matching/parity/corpus_test.exs`:

1. **Scorer parity** — replays every scenario through `WeightedSquaredErrorScorer`:
   each candidate's score must match the corpus exactly (including
   `"excluded"` outcomes), selection must match `selected_index` with the
   earliest-index tie-break, and the tied-index set must recompute exactly.
2. **Solver parity** — replays each target-complete scenario through
   `CompositionSolver`'s contiguous-array fast path (the production selection
   path) and asserts the same selection, error, and excluded-candidate count.
   Scenarios whose *target* is missing a positive-weight channel are
   scorer-only: the app fails earlier, at source-grid validation.

## Refreshing the fixture

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

Then run `swift test` (or `bin/lint`) — the parity tests are the review. The
corpus is deterministic on the upstream side, so the refreshed bytes are
identical until `algorithm_version` changes.

The fixture is loaded relative to the test source (`#filePath`), so it works
without a resource declaration; a follow-up that touches `Package.swift` (the
generated-client migration does) may declare it properly with
`resources: [.copy("Fixtures")]` and switch loading to `Bundle.module`.

## Related: OpenAPI document for the generated client

The same server publishes an OpenAPI 3 document for `/api/v1` (upstream PR
#113, tracked as #110 in this repo's issue) at
`GET /api/v1/openapi.json` — no authentication required. Capturing it is the
input step for the `swift-openapi-generator` client migration:

```bash
curl -fsSL "$COLOR_MATCHING_SERVER/api/v1/openapi.json" \
  -o ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json
```

While `PaletteAPIClient` is still hand-rolled,
`PaletteAPIClientTests` pins the wire contract it speaks today (`/api/v1`
endpoints, `printer_profile_id` query, `Accept`/`Authorization` headers,
envelope shapes, error mapping) so the migration to the generated client can
be verified behavior-preserving.
