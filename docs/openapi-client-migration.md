# Generated OpenAPI client migration (issue #39)

`PaletteAPIClient` talks to `color_matching`'s versioned `/api/v1` API. The
server now publishes an OpenAPI 3 contract for that API (viamin/color_matching#110,
merged as viamin/color_matching#113, served at `GET /api/v1/openapi.json`),
and this package is expected to consume it through
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator) +
[swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime)
instead of hand-written requests and `JSONDecoder` envelopes.

This note records the **prescribed layout** the tests enforce, the **export
procedure** for the document, and the **`/api/v1` shape findings** observed
while comparing the server spec against the hand-written client. The
implementation PR must keep `docs/` and this file in sync with reality when it
lands.

## Prescribed package layout (enforced by `OpenAPIClientMigrationTests`)

```
ColorComposerCore/
├── Package.swift                     # declares swift-openapi-generator (plugin)
│                                     #          + swift-openapi-runtime (library)
└── Sources/
    ├── PaletteOpenAPI/               # generated-client target
    │   ├── openapi.yaml              # the committed OpenAPI document
    │   └── openapi-generator-config.yaml
    └── ColorComposerCore/            # existing sources
```

- The generated module is named **`PaletteOpenAPI`** so it can be imported
  (`import PaletteOpenAPI`) by `ColorComposerCore` and the test target.
  `OpenAPIClientMigrationTests` asserts the module is importable and exposes
  the runtime `Client` type.
- The OpenAPI document must describe both endpoints the app consumes:
  `GET /api/v1/printer_profiles` and `GET /api/v1/colors`.
- Generated code itself is **not committed** — the plugin regenerates it into
  the build directory on every build.

## Exporting / refreshing the OpenAPI document

The server renders the spec from code (OpenApiSpex); there is no committed
static file upstream. To (re)export:

```bash
# against a running server (no auth required for the spec endpoint):
curl -fsSL "$SERVER_BASE/api/v1/openapi.json" \
  | python3 -m json.tool --sort-keys \
  > ColorComposerCore/Sources/PaletteOpenAPI/openapi.yaml
```

(Any JSON→YAML conversion is fine; the generator accepts JSON or YAML. Keep
the export deterministic — sorted keys — so refresh diffs are meaningful.)

## Migration requirement: behavior preservation

The issue allows either migrating `PaletteAPIClient` onto the generated client
or wrapping the generated client inside `PaletteAPIClient` — whichever keeps
the existing behavior intact. That behavior is contract-tested and must not
change:

- **Wire contract** — `OpenAPIClientMigrationTests` (wire-contract section)
  pins the request shapes (`/api/v1/colors?printer_profile_id=N`,
  `/api/v1/printer_profiles`, trimmed bearer token, `Accept: application/json`)
  and the snake_case envelope decodes (`PaletteAPIClientTests`,
  `APIDecodingTests`).
- **Disk cache / offline behavior** — per-server/profile color caching,
  offline-stale badges with fetch dates, cached-profile fallback, and Clear
  Cache are covered by `ProfileColorCacheTests` and sit entirely above
  `PaletteAPIClient`; the migration must not touch them.

## `/api/v1` shape findings (spec vs. hand-written client)

Observed 2026-11 against `viamin/color_matching@main`
(`lib/color_matching_web/api_schemas.ex`); to be re-verified and updated in
the implementation PR:

1. **`PrinterProfile` fields are required in the spec, optional in the
   client.** The spec marks `printer_make_model`, `paper_type`, and `ink_type`
   as required (only `id`, too, of course). The hand-written
   `PrinterProfileDTO` types all three as optional and the UI tolerates their
   absence. The generated client will emit non-optional `String`s — a real
   shape difference to record in the migration notes; either the server spec
   should relax requiredness or the wrapper must keep tolerating misses.
2. **`ColorsResponse.colors[].name` is required in the spec** but optional in
   `PaletteColorDTO` (same class of mismatch as above). `id`, `hex`,
   `palette_id`, `sort_order`, `responses` are required on both sides.
3. **`palette_name` is explicitly `nullable: true`** — the only field where
   the spec acknowledges null (the client models it as `String?`; fine).
4. **`responses` is an opaque object** (`type: :object,
   additionalProperties: true`) — the spec does not describe the per-light
   -source response shape (`brightness`, `source`, `apparent_brightness`,
   `raw_value`, `raw_unit`, `measured_at`, `test_run_id`). The generated
   client will therefore produce untyped payload dictionaries there, and the
   existing `ColorResponseDTO` decoding must stay hand-written in the wrapper.
   A worthwhile follow-up server-side: describe the response schema.
5. **The spec documents more endpoints than the app uses** (palettes,
   metamer pairs, sheets, mapping). Non-goal per issue #39: this app consumes
   only the two endpoints above; trim nothing, generate everything, use two.

## Test enforcement summary

| Test | Phase | Meaning |
| --- | --- | --- |
| `OpenAPIClientMigrationTests/testPackageDeclaresOpenAPIGeneratorAndRuntime` | red until implemented | manifest declares toolchain pieces |
| `OpenAPIClientMigrationTests/testOpenAPIDocumentCoversConsumedAPIv1Endpoints` | red until implemented | committed spec covers both consumed paths |
| `OpenAPIClientMigrationTests/testGeneratedClientTargetCarriesOpenAPIGeneratorConfig` | red until implemented | `PaletteOpenAPI` target wired to the plugin |
| `OpenAPIClientMigrationTests/testGeneratedClientModuleIsAdopted` | red until implemented | module importable (canImport guard) |
| `OpenAPIClientMigrationTests` wire-contract tests | green before & after | request/decode behavior unchanged |
| `PaletteAPIClientTests`, `APIDecodingTests`, `ProfileColorCacheTests` | green before & after | existing behavior net |

> README note: when the migration lands, fold a short "Generated API client"
> section into the root `README.md` pointing here.
