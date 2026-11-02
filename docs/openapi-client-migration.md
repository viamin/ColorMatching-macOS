# Generated OpenAPI client migration notes (issue #39)

Material for the implementation PR description. Tracks the migration of `PaletteAPIClient` onto the typed client generated from the OpenAPI spec published by [viamin/color_matching#110](https://github.com/viamin/color_matching/pull/110).

## Test-side contracts in this repository

| Suite | State before implementation | Role |
| --- | --- | --- |
| `OpenAPIClientAdoptionTests` | **red** (by design) | Turns green when `Package.swift` declares `swift-openapi-generator` + `swift-openapi-runtime`, the OpenAPI document is committed, and package sources actually use the generated client (`OpenAPIRuntime`). |
| `PaletteAPIClientWireContractTests` | green | Pins the `/api/v1` wire behavior (endpoints, query, headers, error mapping, envelope decoding, `baseURL`/`token` exposure for re-auth). Must stay green through the migration. |
| `SolverParityCorpusTests` | green | Solver parity via the committed corpus (see `solver-parity-corpus.md`). |
| `ProfileColorCacheTests` | green | Disk-cache / offline fallback primitives the migration must not disturb. |

## `/api/v1` shape as consumed today

- `GET /api/v1/printer_profiles` → `{"printer_profiles": [ {id, printer_make_model, paper_type, ink_type} ]}` (snake_case envelope).
- `GET /api/v1/colors?printer_profile_id=N` → `{"colors": [ {id, name, hex, rgb?, palette_id, palette_name, sort_order, responses: {red|green|blue|white|lps: {brightness, source, raw_value, raw_unit, apparent_brightness, measured_at, test_run_id}} } ], "printer_profile": {...}?}`.
- Auth: optional `Authorization: Bearer <token>`; HTTP 401 must remain a *distinct* error (`PaletteAPIError.unauthorized`) because `ColorCatalog.withReauth` drives the re-authentication flow off it (issue #16).
- Optional fields (`rgb`, `printer_profile`) decode as `nil`; missing measurements are *absent* response keys, never zero.

No shape changes were found relative to this contract while writing these tests; the corpus seed needed nothing beyond canonical condition keys. When the #110 spec lands, diff it against the shapes above — any drift should surface as a `PaletteAPIClientWireContractTests` failure first.

## Migration guidance (implementation phase)

- **Wrap, don't rewrite**: keep `PaletteAPIClient`'s public surface (`baseURL`, `token`, `init(baseURL:token:session:)`, `fetchPrinterProfiles`, `fetchColors(printerProfileID:)`, `testConnection`) and `PaletteAPIError` cases intact — `ColorCatalog` and the re-auth flow depend on them; the wire-contract suite enforces this.
- Keep the disk cache (`ProfileColorCache`) downstream of the DTOs; offline-stale badges and cached-profile fallback read from it, not from the network stack, so they are preserved by leaving the cache contract untouched.
- Linux `bin/lint` harness: the stub `Package.swift` it generates excludes `PaletteAPIClient.swift`; after adding OpenAPI dependencies, that stub must gain them (or exclude the generated sources) or non-Apple lint runs will fail to compile.
- README: the issue asks for corpus-consumption docs in the README. The allowed file set for the test-writing run did not include `README.md`; `docs/solver-parity-corpus.md` carries the content — link it from the README's *Palette data* section during implementation.
