# Generated OpenAPI client

`PaletteAPIClient` talks to the `color_matching` backend's versioned JSON API
(`/api/v1/*`). The server now publishes an **OpenAPI 3 contract** for those
endpoints, and this app generates its typed client from that contract instead
of hand-writing the wire shapes.

## The upstream contract

| | |
| --- | --- |
| Upstream repository | [`viamin/color_matching`](https://github.com/viamin/color_matching) |
| Upstream dependency | [`viamin/color_matching` #110](https://github.com/viamin/color_matching/issues/110) |
| Served at | `GET /api/v1/openapi.json` (unauthenticated) |
| Source of truth | The OpenAPI document published by the server change in #110 |

The committed copy is the source used to generate the Swift client. Refresh it
only from the OpenAPI document delivered by the server change in #110.

## What this app does with it

- The contract is **committed** to this repository (a copy of the document the
  server serves) so the typed client can be regenerated deterministically and
  reviewed in a diff. `OpenAPIClientContractTests` fails when the committed
  document stops describing the endpoints the client uses.
- The client is generated with [`swift-openapi-generator`](https://github.com/swift-server/swift-openapi-generator)
  and runs on [`swift-openapi-runtime`](https://github.com/swift-server/swift-openapi-runtime).
  Both are dependencies of `ColorComposerCore` (see `Package.swift`).
- The generated types stay an implementation detail: `PaletteAPIClient` keeps
  its public surface (`fetchPrinterProfiles()`, `fetchColors(printerProfileID:)`,
  `testConnection()`, `PaletteAPIError`), so the app's cache, badge and
  fallback logic is unaffected by the migration.

## Endpoints this app uses

| Request | Response |
| --- | --- |
| `GET /api/v1/printer_profiles` | `PrinterProfilesResponse` — `{ "printer_profiles": [PrinterProfile] }` |
| `GET /api/v1/colors?printer_profile_id=N` | `ColorsResponse` — `{ "printer_profile": PrinterProfile, "colors": [Color] }` |

`printer_profile_id` is a **required** integer query parameter (minimum 1);
the contract documents a `422` for a missing or invalid value.

## `/api/v1` shape notes

Found while reading the published contract — the places where the generated
types and this app's hand-written DTOs do not line up exactly:

- **`PrinterProfile` strings are non-nullable in the contract.**
  `printer_make_model`, `paper_type` and `ink_type` are declared as required
  strings, so the generated type has non-optional fields. The app's
  `PrinterProfileDTO` keeps them optional: an older server (or a profile row
  without paper metadata) must still decode, and the app renders missing
  metadata as `Profile #<id>`. The mapping from the generated type to the DTO
  is where that difference is absorbed.
- **`palette_name` is nullable, `rgb` is optional.** A color entry therefore
  carries `palette_name: String?` and `rgb: RGBDTO?`; the app falls back to
  parsing `hex` when `rgb` is absent (`PaletteColorDTO.toDomain()`).
- **A color requires `id`, `name`, `hex`, `palette_id`, `sort_order` and
  `responses`.** The app's DTO keeps `name`, `paletteId` and `sortOrder`
  optional because the app also reads colors from saved project snapshots,
  which were written by older versions.
- **The `responses` map is untyped in the contract** (`additionalProperties:
  true`), so the generated client hands back an opaque JSON value. The app
  keeps its own `ColorResponseDTO` shape (`brightness` required; `source`,
  `raw_value`, `raw_unit`, `apparent_brightness`, `measured_at` and
  `test_run_id` optional) and decodes the map itself — unknown light-source
  keys are dropped, and a channel without a measurement stays *absent* rather
  than becoming zero brightness.
- **The contract documents `GET /api/v1/openapi.json` itself** and returns
  `405` for unsupported methods on the read-only endpoints. The app does not
  call either, but the generated client covers them.

## Refreshing the contract and the client

1. Fetch the contract from a running server (or generate it from the server
   checkout with the command above) and commit the copy in this repository.

2. Regenerate the client:

   ```bash
   cd ColorComposerCore
   swift run --package-path . openapi-generator generate \
     <path-to-openapi-document> \
     --module-name ColorMatchingAPI \
     --output-directory Sources/ColorMatchingAPI
   ```

3. Run the contract tests and the parity tests:

   ```bash
   cd ColorComposerCore && swift test
   ```

`PaletteAPIClientContractTests` pins the wire behavior the migration must not
change: the requested paths and query parameter, the bearer token, the error
mapping (`401` → `.unauthorized`, other non-2xx → `.badStatus`, an unreadable
body → `.malformedResponse`) and the hand-off of fetched colors into the
per-server/per-profile disk cache with their original fetch date.
