# OpenAPI client migration (issue #39)

Notes, findings, and the committed contract fixtures for migrating
`PaletteAPIClient` to a typed client generated from the server's OpenAPI spec
(viamin/color_matching#110). This documents the **tests-first** state of the
migration: the contract instruments are committed; the generation step itself
belongs to the implementation run.

## Committed contract artifacts

| Artifact | Path | Purpose |
| --- | --- | --- |
| OpenAPI 3 document | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/openapi-v1.json` | Machine-checked contract for the routes/shapes the app consumes |
| Spec conformance tests | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift` | Schema↔DTO drift detector |
| Client behavior tests | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift` | Regression net for the migration (requests, errors, envelopes, spec-declared routes) |

### Fixture provenance

The server renders its spec at runtime (`GET /api/v1/openapi.json`, built from
`ColorMatchingWeb.ApiSpec` via `open_api_spex`); it is not committed upstream
as JSON. `openapi-v1.json` is a faithful reconstruction of the **`/api/v1`
palette read surface** — the part `PaletteAPIClient` consumes — transcribed
from:

- upstream commit `47057afd58f7d46b4d4b740ca7d2d08947774471` (2026-10-31)
- `lib/color_matching_web/api_spec.ex`, `router.ex`, `api_schemas.ex`,
  and `ColorPaletteController` operation specs

Routes intentionally out of scope (unused by this app today): test sheets,
captures, measurements, multi-image mapping, and the `GET /api/v1/openapi.json`
introspection route.

### How to refresh

Prefer replacing the reconstruction with the server-rendered document once a
server is reachable:

```bash
curl -fsSL "$COLOR_MATCHING_BASE_URL/api/v1/openapi.json" \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/openapi-v1.json
swift test
```

`OpenAPIContractTests` fails loudly if a consumed route disappears, a required
field is added that the decoding models lack, or the envelope keys change.

## `/api/v1` shape findings (at the pinned upstream commit)

- **No breaking change for the app.** Both routes the app calls remain
  spec'd: `GET /api/v1/printer_profiles` and
  `GET /api/v1/colors?printer_profile_id=N` (query param `required: true`,
  integer; optional `palette_id`).
- **New canonical route**: `GET /api/v1/printer_profiles/{printer_profile_id}/colors`
  (`ProfileColorsResponse`) is the documented composer-facing successor. Its
  color objects **omit** `id`, `palette_id`, `palette_name`, and `sort_order`
  (they are profile-scoped working colors, not palette entries). The migration
  can adopt it without new decoding models for the fields it drops, but the
  app's project persistence keys colors by `id` — either keep `/colors` (still
  spec'd) or derive stable ids when switching.
- **Required fields** per spec: `PrinterProfile` requires all four keys
  (`id`, `printer_make_model`, `paper_type`, `ink_type`); color items in
  `ColorsResponse` require `id, name, hex, palette_id, sort_order, responses`;
  `rgb` and `palette_name` are optional (`palette_name` nullable). The Swift
  DTOs already model every one of these (optional-tolerant), so the generated
  client needs no shape work for the current routes.
- **Auth**: every operation is secured by `bearerAuth` (HTTP bearer), matching
  the client's token handling; `401` responses use `ApiErrorResponse`.
- **Error envelope**: `{ "errors": ... }` for 400/401/404/422 — the client
  maps by status, not body, so no change needed.

## Migration notes for the implementation run

1. Add `swift-openapi-generator` (plugin) + `swift-openapi-runtime` to
   `ColorComposerCore/Package.swift` and move the committed document to the
   generated target's source (e.g. `ColorComposerCore/OpenAPI/openapi.json`).
   Keep the fixture copy for the contract tests, or point both at one file.
2. Wrap the generated `Client` inside the existing `PaletteAPIClient` surface
   (same endpoints, same `PaletteAPIError` mapping incl. `unauthorized` vs
   `badStatus`) so callers — and the disk cache, offline-stale badges, and
   cached-profile fallback that sit downstream — are untouched.
   `PaletteAPIClientContractTests` pins this surface.
3. The fixtures under `Tests/ColorComposerCoreTests/Fixtures/` are loaded via
   `#filePath` (they work under `swift test` and the `bin/lint` Linux harness
   without resource declarations; SwiftPM may warn about unhandled files —
   declaring them `.copy` resources in `Package.swift` silences that).
4. Note for Linux hosts: `bin/lint`'s portable-subset harness excludes
   `PaletteAPIClient.swift`, and `PaletteAPIClientTests` /
   `PaletteAPIClientContractTests` reference it, so those two suites are
   macOS-only today (pre-existing condition). The parity and OpenAPI contract
   tests are pure Foundation and run everywhere.

## PR-description material (lift into the PR when opened)

- Generated-client migration: contract fixtures + conformance tests committed
  first; migration wraps the generated client behind the existing
  `PaletteAPIClient` API (no caller changes, cache behavior untouched).
- `/api/v1` shape changes found: none breaking; new canonical profile-scoped
  colors route documented above.
- Parity test results: 12/12 corpus scenarios agree exactly (scores, ties,
  exclusions, weight handling) — see `docs/solver-parity-corpus.md`.
