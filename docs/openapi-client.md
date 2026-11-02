# Generated OpenAPI client (issue #39)

`PaletteAPIClient` talks to `color_matching`'s versioned HTTP API. The server
publishes an OpenAPI description of `/api/v1` (viamin/color_matching#110);
this app consumes it so the client's types are generated from the server's own
contract instead of hand-maintained DTOs.

## Target state

- `ColorComposerCore/Package.swift` gains
  [`swift-openapi-runtime`](https://github.com/apple/swift-openapi-runtime)
  as a target dependency and the
  [`swift-openapi-generator`](https://github.com/apple/swift-openapi-generator)
  build plugin; the generated sources live in a generated target (e.g.
  `ColorComposerCore/Generated/OpenAPI`).
- The OpenAPI document is vendored (primary documented location:
  `color_matching/openapi.json`; the spec test also accepts `openapi.yaml` /
  `openapi.yml`, and `ColorComposerCore/openapi.*`). Resolution order mirrors
  the corpus loader, with a `$COLOR_MATCHING_OPENAPI_DOCUMENT` override.
- `PaletteAPIClient` keeps its public surface (`fetchPrinterProfiles`,
  `fetchColors(printerProfileID:)`, `testConnection`, `PaletteAPIError`) and
  wraps the generated `Client`, so the app, the disk cache, and offline
  fallback continue to work unchanged. Migration may alternatively swap the
  internals entirely — the tests below are the contract either way.

## Refreshing the document and regenerating

```bash
curl -fsSL \
  "https://raw.githubusercontent.com/viamin/color_matching/<commit>/openapi.json" \
  -o color_matching/openapi.json

cd ColorComposerCore && swift build   # the plugin regenerates the client
swift test --filter PaletteAPI
```

## Behavior the migration must preserve (pinned by tests)

`PaletteAPIClientTests` and `PaletteAPIContractTests`
(`ColorComposerCore/Tests/ColorComposerCoreTests/`) pin the observable contract:

- Endpoints stay versioned: `GET /api/v1/printer_profiles` and
  `GET /api/v1/colors?printer_profile_id=N`, with `Accept: application/json`.
- Bearer-token handling: trimmed token sent as `Authorization: Bearer …`; no
  header when the token is nil/blank; HTTP 401 surfaces as
  `PaletteAPIError.unauthorized` (re-auth flow), other non-2xx as
  `.badStatus(code)`, unparseable bodies as `.malformedResponse`.
- `fetchColors` returns the colors **and** the envelope's printer profile —
  the profile is what the disk cache stores for the offline picker.

Disk-cache and offline behavior (unchanged by this issue) remain guarded by
`ProfileColorCacheTests`: per-(server, profile) namespacing, corrupt-file
misses, `allEntries` fallback for the profile picker, and `fetchedAt` round-trips
that drive the offline-stale badges.

Until the OpenAPI document is vendored,
`PaletteAPIContractTests.testVendoredOpenAPIDocumentIsPresentAndCoversUsedPaths`
is the red flag tracking that gap; once present, the same test verifies the
document actually describes both `/api/v1` routes this app uses (JSON
documents; YAML presence is checked but not parsed).

## `/api/v1` shape notes

Current wire shapes the tests pin (snake_case envelopes):

- `{"printer_profiles": [PrinterProfile]}`
- `{"colors": [PaletteColor], "printer_profile": PrinterProfile?}`
- `PaletteColor.responses` is keyed by `light_source` string
  (`white|red|green|blue|lps`); unknown keys are ignored on decode.

Any differences the published spec reveals (e.g. optional/required fields,
unknown light sources, error response bodies) are recorded in the migration PR
description and reflected here.

## Acceptance criteria mapping (issue #39)

| Criterion | Verification |
| --- | --- |
| Generated client from the OpenAPI document; `PaletteAPIClient` migrated or wrapping it | `PaletteAPIContractTests.testVendoredOpenAPIDocumentIsPresentAndCoversUsedPaths` (unit test; red until the document is vendored) + the pinned contract tests above staying green after migration |
| Per-server/profile color caching, offline-stale badges, cached profile fallback preserved | existing `ProfileColorCacheTests` suite (69 tests) + `PaletteAPIClientTests` staying green |
| `swift test` green with generated client in place | full `ColorComposerCore` suite in the implementation PR (cannot run in this container — no Swift toolchain; see run notes) |
