# OpenAPI client migration notes (issue #39, deliverable 1)

Notes and findings for migrating `PaletteAPIClient` onto a generated
OpenAPI client (`swift-openapi-generator` + `swift-openapi-runtime`). The
code changes land in the implementation phase; this document records the
contract findings that phase must honor.

## Server OpenAPI publication status

- The `color_matching` backend publishes an OpenAPI 3 document at
  `GET /api/v1/openapi.json` — **public, no bearer token required** — via
  OpenApiSpex (`lib/color_matching_web/api_spec.ex`). Content on `main` as of
  commit `47057afd58f7d46b4b740ca7d2d08947774471` (2026-10-31).
- The upstream PR referenced by the issue (viamin/color_matching#110) was not
  open at the time of writing; the spec endpoint is already live on `main`.
- All other `/api/v1` routes sit behind optional bearer auth
  (`LPSM_API_TOKEN`), matching the client's token behavior.

## `/api/v1` shape findings (vs. current DTOs)

Compared the server's OpenAPI schemas (`lib/color_matching_web/api_schemas.ex`)
with `ColorComposerCore/Sources/ColorComposerCore/APIModels.swift`:

| Aspect | Server (OpenAPI) | Client today | Verdict |
| --- | --- | --- | --- |
| `PrinterProfile` fields | `id`, `printer_make_model`, `paper_type`, `ink_type` all required | all decoded as optionals | compatible superset |
| `ColorsResponse.color` required fields | `id`, `name`, `hex`, `palette_id`, `sort_order`, `responses` | `name`, `palette_id`, `sort_order`, `rgb`, `palette_name` optional | compatible superset |
| `palette_name` | nullable | optional | compatible |
| `rgb` | optional (`Rgb` object) | optional, hex fallback in `toDomain()` | compatible |
| `printer_profile` envelope | required in `ColorsResponse` | optional (tolerates absence) | compatible superset |
| Unknown fields | schema evolves freely | ignored by `Codable` | verified by test |

**No breaking `/api/v1` shape changes found.** Two server additions are
intentionally *not* consumed (per the issue's non-goals):

- `GET /api/v1/printer_profiles/:id/colors` returns a *reduced* color shape
  (`ProfileColorsResponse`: `name`/`hex`/`responses`, no `id`/`palette_id`/
  `sort_order`) — different from the `colors` array the client uses.
- `GET /api/v1/printer_profiles/:id/metamer_pairs`, `GET /api/v1/palettes`,
  capture/test-sheet endpoints — outside `PaletteAPIClient`'s current surface.

## Migration plan (implementation phase)

1. Add `swift-openapi-generator` (build plugin) and `swift-openapi-runtime`
   (dependency) to `ColorComposerCore/Package.swift`.
2. Fetch the OpenAPI document from a running server
   (`curl $SERVER/api/v1/openapi.json -o openapi.yaml`) and commit it under
   `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/`.
3. Generate the typed client; keep `PaletteAPIClient` as a thin wrapper so
   `PaletteAPIError` (`unauthorized` vs `badStatus` vs `malformedResponse`),
   token trimming, and the `PrinterProfileDTO`/`PaletteColorDTO` public
   surface stay identical.
4. Keep the disk cache (`ProfileColorCache`) keyed exactly as today — it
   stores wire-format DTOs (snake_case JSON), which the generated client must
   not alter.

## Tests that must stay green through the migration

These are the behavioral contract; the migration PR must not weaken them:

- `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`
  (existing) — 401 mapping, trimmed bearer token.
- `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift`
  (added with this change) — endpoint URLs, `Accept` header, query building,
  happy-path decoding of the server shapes, `badStatus`/`malformedResponse`
  mapping, `testConnection` semantics, unknown-field tolerance.
- `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`
  (existing, 69 tests) — per-server/profile disk cache, corruption misses,
  clear-cache, snake_case wire keys: the substrate for offline-stale badges
  and cached-profile fallback.

`.ephemeral-tests/openapi_spec_check.sh` (removed before merge) validates a
*live* server's published document against the client's expectations during
the migration PR.

## Verification status of this (tests-only) change

Executed on Linux (Swift 6.0.3, aarch64) via a harness mirroring `bin/lint`'s
non-Apple subset, excluding only `BrightnessGridSampler.swift` (CoreGraphics):

- **223 tests, 0 failures** — the full package test suite, including:
  - `SolverParityCorpusTests` — 5/5 (corpus metadata, risk coverage, exact
    scorer scores, selection + ties, solver fast-path replay)
  - `PaletteAPIClientContractTests` — 10/10
  - `PaletteAPIClientTests` — 2/2 (after a one-line fix: the handler closure
    needed explicit `self.` for `printerProfilesResponse()` under Swift 6
    toolchains)
  - `ProfileColorCacheTests` — 69/69 (disk-cache substrate unchanged)

Tooling findings for the implementation phase:

- `PaletteAPIClient.swift` itself compiles and its tests pass on Linux — the
  `bin/lint` Linux harness's exclusion of it (with `BrightnessGridSampler`)
  is stale and makes the harness fail to compile `PaletteAPIClientTests`.
  This failure predates this change (verified against a clean tree) and
  should be fixed by dropping the stale exclude in the implementation phase.
- On the canonical macOS host, `bin/lint` runs plain `swift test`; the same
  223 tests plus any CoreGraphics-dependent suites apply.
