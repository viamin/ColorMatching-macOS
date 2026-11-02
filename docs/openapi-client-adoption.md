# Generated OpenAPI client adoption (issue #39)

Notes for migrating `PaletteAPIClient` to a typed client generated from the
`color_matching` OpenAPI spec (viamin/color_matching#110), plus the `/api/v1`
shape deltas found while comparing the published spec against the current
hand-rolled DTOs. The behavioral tests that the migration must keep green are
`PaletteAPIClientTests` (wire contract) and `ProfileColorCacheTests`
(disk cache / offline fallback).

## Target layout (asserted by `OpenAPIAdoptionTests`)

- `Package.swift` declares the `swift-openapi-generator` plugin and the
  `swift-openapi-runtime` dependency.
- The OpenAPI document is committed at `ColorComposerCore/OpenAPI/openapi.json`.
  Export it from a running server: `GET /api/v1/openapi.json` (served by
  `ColorMatchingWeb.OpenApiController`), i.e.
  `curl -fsSL http://localhost:4000/api/v1/openapi.json -o ColorComposerCore/OpenAPI/openapi.json`.
- `PaletteAPIClient` either migrates onto the generated `Client` or wraps it.
  Its public surface must not change: `baseURL`, `token`,
  `fetchPrinterProfiles()`, `fetchColors(printerProfileID:)`, `testConnection()`,
  and the `PaletteAPIError` mapping (401 → `.unauthorized`, other non-2xx →
  `.badStatus`, undecodable body → `.malformedResponse`). The `ProfileColorCache`
  disk cache and offline-stale flow sit behind that surface and must stay
  untouched.

## `/api/v1` shape changes found (spec vs current DTOs)

From `ColorMatchingWeb.ApiSchemas` (served at `/api/v1/openapi.json`):

1. **`ColorsResponse` envelope** — the spec *requires* `printer_profile`
   (`required: [:printer_profile, :colors]`), while the current Swift
   `ColorsResponse` decodes it as optional `PrinterProfileDTO?`.
2. **Color items** — the spec requires `id`, `name`, `hex`, `palette_id`,
   `sort_order`, `responses` per color. The current `PaletteColorDTO` treats
   `name`, `paletteId`, `sortOrder` as optional. With the generated client
   these become non-optional; decode failures become server-contract bugs
   rather than silent `nil`s.
3. **`rgb`** — optional in the spec but each `Rgb` requires `r`, `g`, `b`
   integers; matches the current `RGBDTO?` handling.
4. **`palette_name`** — nullable string in the spec; matches
   `paletteName: String?`.
5. **`responses` is free-form** — `additionalProperties: true`, i.e. the
   generated client yields an `[[String: AnyJSON]]` shape rather than the
   current typed `ColorResponseDTO` (which requires `brightness` per entry).
   The migration must keep enforcing a numeric `brightness` per known light
   source before the values reach the solver (a response entry without
   `brightness` is a missing measurement, not zero).
6. **`PrinterProfile`** — spec requires all of `id`, `printer_make_model`,
   `paper_type`, `ink_type`; current `PrinterProfileDTO` keeps the three label
   strings optional (used by `displayName` / `softProofProfile`). Decide
   deliberately whether the generated types feed those optionals.
7. **Auth** — the spec declares a global `bearerAuth` HTTP scheme. The client
   sends `Authorization: Bearer <token>` only when a token is configured
   (server-side `LPSM_API_TOKEN` is optional); preserve that behavior.
8. **Endpoints used** — only `GET /api/v1/printer_profiles` and
   `GET /api/v1/colors?printer_profile_id=N` are in scope (non-goal: new API
   surfaces).

## Verification during migration

- `swift test` must stay green, including:
  - `PaletteAPIClientTests` — endpoint paths, query, headers, payload decoding,
    and error mapping pinned against a mock `URLProtocol`;
  - `ProfileColorCacheTests` — per-server/profile disk caching, ownership
    markers, corruption misses, and `allEntries(serverBaseUrl:)` fallback;
  - `SolverParityCorpusTests` — solver parity (unaffected by the migration);
  - `OpenAPIAdoptionTests` — green once the generator/runtime and the committed
    OpenAPI document are in place (red until then by design).
- Offline behavior (`offline-stale` badge, cached-profile fallback) is app-shell
  wiring (`ColorMatching/Networking/ColorCatalog.swift`) driven by
  `ProfileColorCache`; it has no network dependency and is preserved as long as
  `PaletteAPIClient`'s surface and error mapping are unchanged.
