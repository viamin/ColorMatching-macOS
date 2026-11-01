# OpenAPI client migration notes (issue #39)

Working notes for migrating `PaletteAPIClient` onto a typed client generated
from the server's OpenAPI document (`swift-openapi-generator` +
`swift-openapi-runtime`). Recorded so the PR description and the migration
itself start from verified facts about the contract.

## Where the contract lives

- Server (viamin/color_matching, PR #110 work): the OpenAPI 3 document is
  served at `GET /api/v1/openapi.json`, assembled by `ColorMatchingWeb.ApiSpec`
  from `ApiSchemas` + controller operation specs
  (`lib/color_matching_web/api_spec.ex`, `api_schemas.ex`,
  `color_palette_controller.ex`).
- This repo's pinned mirror: `ColorComposerCore/Tests/Fixtures/openapi-v1.json`
  — the subset the app consumes (`GET /api/v1/printer_profiles`,
  `GET /api/v1/colors`). `OpenAPIWireContractTests` pins this document and
  verifies spec-conforming payloads decode with the current DTOs.

## `/api/v1` shape findings (from the served spec)

1. `GET /api/v1/colors` documents `printer_profile_id` as a **required**
   integer query parameter (minimum 1), plus an optional `palette_id` —
   matching what `PaletteAPIClient` already sends. Documented error responses:
   400/401/404/422 with an `ApiErrorResponse` (`{"errors": …}`) body.
2. `ColorsResponse` requires top-level `printer_profile` **and** `colors`;
   each color item requires `id`, `name`, `hex`, `palette_id`, `sort_order`,
   `responses`. `rgb` is optional. `palette_name` is the one documented
   nullable field. The Swift DTOs are a tolerant superset (optionals where
   the spec requires values) — no shape change needed for the app.
3. `PrinterProfile` requires all four fields (`id`, `printer_make_model`,
   `paper_type`, `ink_type`), non-nullable; the app's optional decoding is
   strictly more tolerant.
4. New sibling route **`GET /api/v1/printer_profiles/:id/colors`**
   (`ProfileColorsResponse`) is the server's recommended composer-facing
   retrieval. Its color items carry only `name`, `hex`, `rgb`, `responses` —
   no `id`/`palette_id`/`sort_order` — so adopting it would change DTOs.
   **Non-goal for issue #39** (no new API surfaces): the migration keeps
   `GET /api/v1/colors?printer_profile_id=N`.
5. Both consumed operations declare the `bearerAuth` HTTP security scheme —
   consistent with the client's `Authorization: Bearer …` header and the 401 →
   `PaletteAPIError.unauthorized` mapping.

## Migration safety net (already committed)

Behavior that must survive the migration unchanged is pinned by:

- `PaletteAPIClientMigrationContractTests` — endpoint paths, required query
  parameter, `Accept` header, bearer-token presence/absence (trimmed and
  whitespace-only tokens), error mapping (401 → `.unauthorized`,
  other non-2xx → `.badStatus`, undecodable 2xx body → `.malformedResponse`),
  `testConnection` on 204/401.
- `OpenAPIWireContractTests` + `APIDecodingTests` — envelope/DTO wire shapes,
  including unknown-light-source tolerance and missing-vs-zero responses.
- `ProfileColorCacheTests` — per-server/profile disk caching, corrupt-file
  misses, namespace rules; unchanged by the migration (cache sits above the
  client).

## Migration checklist (implementation run)

1. Add `swift-openapi-generator` (plugin) + `swift-openapi-runtime` to
   `ColorComposerCore/Package.swift`; commit the full OpenAPI document (from
   the server) as the generator input.
2. Generate the typed client; wrap or migrate `PaletteAPIClient` so its public
   surface (used by `ColorCatalog`) is unchanged.
3. Keep the disk-cache/offline-stale/cached-profile-fallback paths above the
   client untouched; all suites above must stay green.
4. Record in the PR description: generated-client migration notes, shape
   findings above, and parity test results.
