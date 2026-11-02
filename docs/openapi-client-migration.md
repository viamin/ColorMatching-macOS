# OpenAPI client migration (issue #39)

Working notes and the enforced contract for migrating `PaletteAPIClient` to a
generated [swift-openapi-generator](https://github.com/apple/swift-openapi-generator)
client. The tests in
`ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientMigrationTests.swift`
encode this contract and are red until the migration lands.

## Pinned locations (test-enforced)

| Artifact | Location |
| --- | --- |
| OpenAPI document | `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml` (`.yml`/`.json` accepted) |
| Generator config (optional) | `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi-generator.yaml` |
| Package dependencies | `swift-openapi-generator` (plugin) + `swift-openapi-runtime`, declared in `ColorComposerCore/Package.swift` |

## Source of truth for the document

The server renders its spec live with OpenApiSpex at **`GET /openapi.json`**
(definition: `lib/color_matching_web/api_spec.ex` +
`lib/color_matching_web/api_schemas.ex` in viamin/color_matching, from
[issue #110](https://github.com/viamin/color_matching/issues/110)). Refresh the
vendored copy with:

```bash
curl -fsSL <server-base>/openapi.json \
  -o ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json
```

`OpenAPIClientMigrationTests.testVendoredOpenAPIDocumentDescribesConsumedEndpoints`
requires the vendored document to describe `GET /api/v1/printer_profiles`,
`GET /api/v1/colors`, and the `bearerAuth` security scheme.

## Migration strategy (wrap, do not rewrite callers)

Keep `PaletteAPIClient`'s public surface (`baseURL`, `token`, `init(session:)`,
`fetchPrinterProfiles`, `fetchColors`, `testConnection`) and re-implement its
body on top of the generated `Client`. That preserves:

- the disk cache and offline-stale behavior in `ProfileColorCache` /
  `ColorCatalog` (untouched — they only see DTOs and `PaletteAPIError`),
- the 401 → `.unauthorized` distinction the re-auth flow (issue #16) relies on,
- the session-injectable transport the tests use.

## `/api/v1` shape findings (upstream spec vs current DTOs)

From `ColorMatchingWeb.ApiSchemas` (upstream `main`, 2026-11-02):

1. **`PrinterProfile` fields are all required** (`id`, `printer_make_model`,
   `paper_type`, `ink_type` — non-nullable strings). The app's
   `PrinterProfileDTO` models the three descriptor fields as `String?`.
   No wire change is needed (the server always sends them), but the generated
   types will be non-optional; the wrapper must keep tolerating absence for
   cached/legacy payloads.
2. **`ColorsResponse.printer_profile` is required** in the spec envelope; the
   app types it as `PrinterProfileDTO?`. Again: keep the optional on the app
   side, feed it from the required generated field.
3. **`colors[]` required keys** are `id, name, hex, palette_id, sort_order,
   responses`; `rgb` is optional; `palette_name` is nullable — matches the app
   DTO except `name`, which the app treats as optional. No action.
4. **`responses` is free-form** (`type: object, additionalProperties: true`) —
   the structured `ColorResponseDTO` members (`brightness`, `source`,
   `raw_value`, `raw_unit`, `apparent_brightness`, `measured_at`,
   `test_run_id`) are **not** in the published spec. The generated client will
   surface an untyped map; the wrapper must keep decoding
   `ColorResponseDTO` from those values (or upstream should enrich the schema —
   worth requesting; unknown keys are already ignored per
   `APIDecodingTests.testDomainConversionDropsUnknownLightSources`).
5. **Security**: `/api/v1` requires `bearerAuth` (HTTP bearer) — matches the
   current `Authorization: Bearer <token>` header behavior, including
   whitespace-trimmed tokens and omitting the header when the token is empty
   (pinned by `PaletteAPIClientWireContractTests`).

## Behavior preserved (test-enforced)

| Behavior | Pinned by |
| --- | --- |
| `/api/v1/colors?printer_profile_id=N`, `Accept: application/json`, envelope decode | `PaletteAPIClientWireContractTests.testFetchColorsRequestsAPIV1PathWithProfileQueryAndAcceptHeader` |
| 401 → `.unauthorized` on both endpoints + `testConnection` | `PaletteAPIClientWireContractTests` (`.testFetchColorsMaps401ToUnauthorized`, `.testTestConnectionMaps401ToUnauthorized`), `PaletteAPIClientTests` |
| Non-2xx → `.badStatus(code)`; undecodable 2xx body → `.malformedResponse` | `PaletteAPIClientWireContractTests` |
| Bearer token trimming; no `Authorization` header for empty tokens | `PaletteAPIClientTests.testFetchPrinterProfilesUsesTrimmedBearerToken`, `PaletteAPIClientWireContractTests.testFetchPrinterProfilesSendsNoAuthorizationWhenTokenEmpty` |
| Per-server/per-profile disk cache, entry validation, offline `allEntries` fallback | `ProfileColorCacheTests` (unchanged by the migration; run the full suite to verify) |

## PR description checklist (implementation run)

- Generated-client migration notes (wrap vs replace, transport session
  injection, error mapping).
- Any `/api/v1` shape changes found — seed with the findings above.
- Parity test results (`SolverParityCorpusTests` — see
  `docs/parity-corpus.md` findings).
