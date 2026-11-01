# OpenAPI client adoption — plan and verification map (issue #39)

This run adds the **tests and documentation** for adopting the generated
OpenAPI client and enforcing solver parity. The implementation (dependencies,
generated code, `PaletteAPIClient` migration) follows in the implementation
run; the tests below define and guard that work.

## Acceptance-criteria → verification map

| # | Criterion (from issue #39) | Verification | Kind |
| --- | --- | --- | --- |
| AC-1 | `swift-openapi-generator` + `swift-openapi-runtime` in `ColorComposerCore`; typed client generated from the OpenAPI document; `PaletteAPIClient` migrated/wrapped | `OpenAPIClientAdoptionTests` — manifest declares both packages (plugin applied), document committed at `ColorComposerCore/OpenAPI/color_matching.json`, describes `GET /api/v1/printer_profiles` + `GET /api/v1/colors` with the `printer_profile_id` query parameter and the snake_case envelope property names. **Red until the migration lands.** | Focused unit test (contract pins) |
| AC-2 | Preserve per-server/profile color caching, offline-stale badges, cached profile fallback | `PaletteAPIClientMigrationTests` (wire contract: paths, query, bearer token, 401/500/malformed mapping, envelope decoding) + `ProfileColorCacheMigrationTests` (offline read of a cached fetch still solves, `fetchedAt` round-trips exactly, `allEntries` fallback) on top of the existing `ProfileColorCacheTests` suite (cross-server isolation, integrity). **Green today; must stay green through the migration.** | Unit/service tests |
| AC-3 | Solver parity test target loading the corpus; selections match exactly, including ties | `WeightedSquaredErrorParityTests` + committed corpus fixture (see `docs/parity-corpus.md`). Asserts score values, exclusions, `best_match` tie policy, and the `CompositionSolver` fast path. | Permanent unit test |
| AC-4 | Document corpus consumption (where it lives, how to refresh) | `docs/parity-corpus.md`. README should link it when the implementation run touches the README. | Inspectable doc artifact |
| AC-5 | PR description records migration notes, `/api/v1` shape findings, parity results | Sections below are pre-staged for the PR body. | PR description (human) |

## Migration contract the tests enforce

- The OpenAPI document is committed at
  `ColorComposerCore/OpenAPI/color_matching.json` so the client generation is
  reproducible from the repo (source: viamin/color_matching#110).
- `swift-openapi-generator` (plugin) and `swift-openapi-runtime` (dependency)
  are declared in `ColorComposerCore/Package.swift`.
- Migrate **or wrap** — whichever keeps:
  - `GET /api/v1/printer_profiles` / `GET /api/v1/colors?printer_profile_id=N`
    request shapes,
  - bearer-token behavior (trimmed, omitted header when absent, `401` →
    `unauthorized`),
  - non-2xx → `badStatus`, undecodable body → `malformedResponse`,
  - and the `PaletteAPIClient` public surface used by `ColorCatalog.swift`.
- The disk cache (`ProfileColorCache`) is untouched by the wire-format swap:
  entries are stored as the DTOs the client decoded, keyed per
  (server, profile), and served offline with their fetch date.

## PR description notes (pre-staged)

### Generated-client migration notes

_To be completed by the implementation run:_ dependencies added, plugin
wired into the target, `PaletteAPIClient` migrated vs wrapped, and any
generated-type ↔ DTO bridging.

### `/api/v1` shape findings

The contract pins (`OpenAPIClientAdoptionTests`) assert the published spec
still names `printer_profiles`, `printer_profile_id`, `printer_profile`, and
`responses` exactly as the hand-written DTOs decode them today. A spec rename
fails those tests — record any such change here when found.

### Parity test results

The seed corpus (11 cases) pins: score-value parity with the Elixir doctest
(`0.205`), earliest-wins ties (symmetric, duplicate, and zero-weight-channel
ties), exclusion semantics (missing ≠ zero; a would-win-if-zero candidate is
excluded; all-excluded → `null` selection), and weight handling (optional
zero-weight channels, dominance, no normalization). Expected green against
the current scorer; any failure is a genuine parity bug to report here.
