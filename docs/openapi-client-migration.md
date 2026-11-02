# OpenAPI generated-client migration notes (issue #39)

Working notes for migrating `PaletteAPIClient` onto the OpenAPI-generated
client once implementation files are unlocked. The tests committed alongside
this document are the acceptance gate: the migration is behavior-preserving
if and only if they stay green.

## Dependencies to add (ColorComposerCore/Package.swift)

- `apple/swift-openapi-generator` as a plugin dependency
  (`.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`)
- `apple/swift-openapi-runtime` as a target dependency
- A generated client target fed by the OpenAPI document, e.g.
  `ColorComposerCore/Sources/OpenAPIGeneratedClient` with
  `openapi-generator-config.yaml` (`security: ["bearerAuth"]`,
  `mode: typesafeClient`)

## Spec source

The server publishes its OpenAPI 3 contract at `GET /api/v1/openapi.json`
(unauthenticated; spec title "Color Matching API", version `v1`). Capture it
from a running server (or render it from `lib/color_matching_web/api_spec.ex`)
and commit the document next to the generated target; do not fetch it at
build time.

## Migration shape: wrap, don't replace

Keep `PaletteAPIClient`'s public surface (`baseURL`, `token`, `fetchPrinterProfiles`,
`fetchColors`, `testConnection`, `PaletteAPIError`) and re-implement its
internals on top of the generated `Client`. The disk cache
(`ProfileColorCache`), offline-stale badges, and cached-profile fallback all
sit above this surface — wrapping them keeps that behavior untouched.

The generated client must be constructed with the user's server URL and a
`URLSession`-backed transport, and must send the bearer token only when
non-empty (after trimming).

## `/api/v1` shape findings (from the published spec)

No breaking changes versus what `PaletteAPIClient` decodes today; the client
is a lenient subset consumer of the spec:

- `PrinterProfile`: `id`, `printer_make_model`, `paper_type`, `ink_type` are
  all *required* by the spec; the app's DTOs treat them as optional. Optional
  decoding stays valid (strictly more permissive), no change needed.
- `ColorsResponse` colors entries require `id`, `name`, `hex`, `palette_id`,
  `sort_order`, `responses`. `palette_name` is explicitly **nullable**;
  `rgb` is **optional** (the app already falls back to `hex` when `rgb` is
  absent); `responses` is a free-form object (`additionalProperties: true`),
  so unknown light-source keys can appear — the app already drops them in
  `PaletteColorDTO.toDomain()`.
- `ColorsResponse` embeds a required `printer_profile`; the app's optional
  handling remains compatible.
- Security: authenticated `/api/v1` endpoints use the `bearerAuth`
  (`http`/`bearer`) scheme — matching the app's `Authorization: Bearer`
  header — and HTTP 401 is the contract's auth-failure signal, which the app
  maps to `PaletteAPIError.unauthorized` for the re-auth flow.

## Behavior-preservation guard suite (must stay green through the migration)

- `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift`
  (new in this change): request construction (`/api/v1` paths, query
  parameter, `Accept` header, base-URL path prefixing), token handling
  (omitted / whitespace-only / trimmed bearer), spec-shaped envelope decoding
  end-to-end through `toDomain()`, and the error map (401 → `.unauthorized`,
  500 → `.badStatus`, malformed body → `.malformedResponse`, 2xx on
  `testConnection`).
- `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`
  (pre-existing): 401 mapping and trimmed-bearer behavior.
- `ColorComposerCore/Tests/ColorComposerCoreTests/APIDecodingTests.swift`
  (pre-existing): snake_case wire decoding and missing-vs-zero semantics.
- `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`
  (pre-existing): per-server/profile disk caching, offline-stale entries
  (including `fetchedAt`), clear-cache semantics, and on-disk format
  stability. These are unaffected by the migration as long as
  `PaletteColorDTO`/`PrinterProfileDTO` keep coding to the same snake_case
  wire keys — the cache stores DTOs verbatim.

If the generated types replace the hand-written DTOs, keep
`CachedProfileColors`'s on-disk JSON format unchanged (snake_case keys) or
ship a migration; `testDecodesHandWrittenSnakeCaseCacheFile` pins the
current format.
