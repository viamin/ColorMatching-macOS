# Solver parity corpus & generated OpenAPI client

Working notes for issue #39 (test phase). The README section promised by the
issue is added during the implementation run; this document is the source it
is ported from.

## Solver parity corpus

**Where it lives (source of truth):** the `color_matching` backend generates a
deterministic golden-vector corpus at `priv/parity/v1/corpus.json`
(`ColorMatching.Parity.Corpus`, upstream issue #111). Upstream CI verifies the
committed bytes with `mix parity.generate --check`, so the file never drifts
from the Elixir `ColorMatching.WeightedSquaredError` scorer +
`IlluminantMatching` earliest-index-wins selection.

**Where this app consumes it:** a byte-for-byte vendored copy at

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-corpus.json
```

replayed by `SolverParityCorpusTests.swift` (`swift test` in
`ColorComposerCore/`).

**How to refresh:**

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If `algorithm_version` in the corpus is no longer `1`, scoring semantics moved
upstream — do not just refresh; re-review the parity findings below first.

**What the parity test asserts (exactly):**

- per-candidate scores, including the `"excluded"` marker for candidates (or
  targets) missing a measurement on any positive-weight channel,
- the selected index/hex/error under earliest-index-wins tie-breaking (the
  `tie-*` scenarios pin that a later exact duplicate must **not** win),
- tie evidence (`tied_indices`, `tie_broke`),
- zero-weight channels neither exclude nor contribute
  (`zero-weight-channel-missing`), and unknown weight keys are ignored
  (`unknown-weight-ignored`),
- the same selections end-to-end through `CompositionSolver`'s optimized fast
  path on a 1×1 grid, for every scenario whose target measures all active
  channels.

Corpus values are dyadic rationals, so score comparisons are exact (`==`),
not tolerance-based. Pre-implementation cross-check: an independent Python
replay of the corpus with the Swift scorer's semantics matched all 12/12
scenarios exactly (ties, exclusions, weight handling included).

## OpenAPI document & generated client

**Where the spec comes from:** the server publishes it at
`GET /api/v1/openapi.json` (upstream issue #110; `ColorMatchingWeb.ApiSpec`).
The document is vendored inside the package (accepted locations are pinned by
`OpenAPIClientMigrationTests.swift`, canonical:
`ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`) and the
typed client is generated with `swift-openapi-generator` +
`swift-openapi-runtime`, both declared in `ColorComposerCore/Package.swift`
and enforced by `OpenAPIClientMigrationTests.swift`.

**Refresh:**

```bash
curl -fsSL "$COLOR_MATCHING_URL/api/v1/openapi.json" \
  -o ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json
```

**Migration notes / shape findings (spec vs. today's DTOs):**

- `GET /api/v1/colors` — spec marks `printer_profile` **required** in the
  response envelope; the hand-rolled `ColorsResponse` models it as optional
  and tolerates its absence. No breaking change (client is strictly more
  lenient), but the generated types will make it non-optional — callers
  already only use it for cache metadata.
- Color items: spec requires `id, name, hex, palette_id, sort_order,
  responses` and makes `rgb` optional, `palette_name` nullable. Today's DTO
  treats everything except `id`/`hex` as optional — again strictly lenient,
  no shape change required on the server.
- `GET /api/v1/printer_profiles` envelope (`printer_profiles` snake_case
  array) matches the existing decoder exactly.
- `PaletteAPIClientContractTests.swift` pins the current wire behavior
  (envelopes, `printer_profile_id` query, `Accept`/`Authorization` headers,
  401-vs-other-status error mapping, malformed-body handling) and must stay
  green across the migration; disk-cache/offline-stale behavior is covered by
  `ProfileColorCacheTests.swift` and is untouched by the client swap.

## Acceptance-criterion verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated OpenAPI client adopted, `PaletteAPIClient` migrated/wrapped | `OpenAPIClientMigrationTests` (vendored spec + package deps; red until implemented) + `PaletteAPIClientContractTests` (wire behavior preserved; green before and after) |
| Disk cache / offline-stale / cached-profile fallback unchanged | Existing `ProfileColorCacheTests` suite (no regressions) |
| Parity corpus test asserting exact selections incl. ties | `SolverParityCorpusTests` replaying the committed fixture (permanent suite) |
| README documents corpus consumption | `human_or_external_evidence` — README diff in the implementation run, ported from this file |
| PR description records migration notes, `/api/v1` shape findings, parity results | PR body; findings captured in this file's "Migration notes" section |
