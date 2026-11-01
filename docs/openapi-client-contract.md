# OpenAPI client contract (issue #39)

The `color_matching` server is publishing an OpenAPI spec for `/api/v1`
(viamin/color_matching#110). This app adopts a generated client
(`swift-openapi-generator` + `swift-openapi-runtime`) in `ColorComposerCore`,
keeping today's observable behavior intact. Two test files encode that
contract:

- `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientMigrationTests.swift`
  — **red until the migration lands.** Requires:
  - `ColorComposerCore/Package.swift` declares both `swift-openapi-generator`
    (the codegen plugin) and `swift-openapi-runtime` (the generated client's
    runtime).
  - The OpenAPI document is committed under `ColorComposerCore` at one of:
    `openapi.{yaml,yml,json}`, `OpenAPI/openapi.{yaml,yml,json}`, or
    `Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}`.
  - The document describes `GET /api/v1/printer_profiles` and
    `GET /api/v1/colors` with the `printer_profile_id` query parameter.
- `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift`
  — **green today; the migration safety net.** Whatever transport
  `PaletteAPIClient` ends up using (generated client, or a wrapper around it),
  these must keep passing:
  - `GET /api/v1/colors?printer_profile_id=N` and
    `GET /api/v1/printer_profiles`, `Accept: application/json`.
  - Bearer token trimmed and sent only when non-empty; HTTP 401 maps to
    `PaletteAPIError.unauthorized`, other non-2xx to `badStatus`, undecodable
    bodies to `malformedResponse`.
  - Snake_case wire shapes decode exactly as today (`printer_profiles` /
    `colors` + `printer_profile` envelopes; per-color `responses` keyed by
    light source; nullable profile fields).

## Migration notes for the implementer

- `PaletteAPIClient`'s public surface (`baseURL`, `token`,
  `fetchPrinterProfiles`, `fetchColors`, `testConnection`,
  `PaletteAPIError`) is consumed by `ColorMatching/Networking/ColorCatalog.swift`
  and by the disk cache; keep the surface stable so
  `ProfileColorCache`/offline-stale behavior (covered by
  `ProfileColorCacheTests`) is untouched.
- `/api/v1` shape findings to record in the PR description should be
  cross-checked against the fixtures in `PaletteAPIClientContractTests` —
  they are the pinned truth for the current wire format.
