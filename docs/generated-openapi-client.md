# Generated OpenAPI client (issue #39)

`PaletteAPIClient` talks to the `color_matching` server's versioned API. The
server publishes an OpenAPI 3 contract (viamin/color_matching#110, served at
`GET /api/v1/openapi.json`); the macOS app consumes it through
[apple/swift-openapi-generator](https://github.com/apple/swift-openapi-generator)
instead of hand-written decoding.

## Conventions enforced by the tests

`ColorComposerCore/Tests/ColorComposerCoreTests/GeneratedOpenAPIClientAdoptionTests.swift`
(red until the migration lands) pins the standard swift-openapi-generator
layout:

1. `ColorComposerCore/Package.swift` depends on
   `apple/swift-openapi-generator` and `apple/swift-openapi-runtime`, applies
   the `OpenAPIGenerator` build plugin to the `ColorComposerCore` target, and
   links the `OpenAPIRuntime` product.
2. The OpenAPI document is committed at
   `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`
   (the generator's default lookup path) and describes
   `GET /api/v1/printer_profiles`, `GET /api/v1/colors`, and the
   `bearerAuth` security scheme.
3. At least one source file in `Sources/ColorComposerCore` is wired to the
   generated client (`OpenAPIRuntime`), i.e. `PaletteAPIClient` is migrated
   to — or wraps — the generated `Client`.

## Behavior that must not change

- `PaletteAPIClientContractTests` pins the request shapes
  (`/api/v1/colors?printer_profile_id=N`, `Accept: application/json`,
  optional trimmed `Authorization: Bearer …`), envelope decoding with
  missing measurements **absent, never zero**, and the error taxonomy
  (`unauthorized` on 401, `badStatus` on other non-2xx,
  `malformedResponse` on undecodable bodies).
- `ProfileColorCacheTests` (69 tests) pins the per-server/per-profile disk
  cache, offline-stale badges, and cached-profile fallback that sit on top of
  the client.

## `/api/v1` shape findings (recorded for the PR description)

Diffing the upstream OpenAPI schemas (`ColorMatchingWeb.ApiSchemas`) against
the hand-written DTOs in `APIModels.swift` found **required-ness drift** —
the spec is stricter than what the Swift DTOs assume:

| Field | OpenAPI spec | Current Swift DTO |
| --- | --- | --- |
| `PrinterProfile.printer_make_model` / `paper_type` / `ink_type` | required (string) | optional (`String?`) |
| `ColorsResponse.printer_profile` | required | optional (`PrinterProfileDTO?`) |
| `ColorsResponse.colors[].name` | required (string) | optional (`String?`) |
| `ColorsResponse.colors[].palette_id` / `sort_order` | required (integer) | optional (`Int?`) |
| `ColorsResponse.colors[].rgb` | optional `{r,g,b}` (integers) | optional (`RGBDTO?`) — matches |
| `ColorsResponse.colors[].palette_name` | nullable string | optional — matches |
| `colors[].responses` | free-form object (`additionalProperties: true`) | `[String: ColorResponseDTO]` — client-side enforces `brightness` |

Migration notes:

- The generated types will surface the required fields as non-optional. The
  wrapper around the generated client should keep the lenient, optional
  decoding (or tolerate decode failures per-field) so behavior against
  older servers is unchanged — preserving the existing DTOs as the wrapper's
  output is the lowest-risk route.
- `responses` being free-form in the spec means the real
  `ColorResponseDTO` shape (`brightness` + provenance fields) is a client
  convention; a schema-tightening PR upstream would make this explicit.
- The spec also covers endpoints the app does not use (palettes, metamer
  pairs, captures, multi-image mapping). Per the issue non-goals, only
  `printer_profiles` and `colors` are consumed; no new API surfaces.

## Regenerating the client

The generated sources are produced at build time by the `OpenAPIGenerator`
plugin — nothing generated is committed. After changing the committed
`openapi.yaml`, `swift build` regenerates automatically.

## README linkage

As with the parity corpus doc, linking this document from `README.md`
belongs to the implementation run for issue #39.
