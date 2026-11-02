# Generated OpenAPI client migration (issue #39)

`PaletteAPIClient` talks to `color_matching`'s versioned `/api/v1` API. The
server now publishes an OpenAPI 3 spec (viamin/color_matching#110), and this
package is migrating to a typed client generated from it with
`swift-openapi-generator` + `swift-openapi-runtime`.

## The contract the migration tests enforce

`ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientMigrationTests.swift`
gates the migration (red until it lands, green afterwards):

1. **Manifest wiring** — `ColorComposerCore/Package.swift` declares the
   `apple/swift-openapi-generator` package (and applies its `OpenAPIGenerator`
   plugin to the target) and the `apple/swift-openapi-runtime` package (with
   its `OpenAPIRuntime` product linked into the client target and visible to
   the test target). Sketch:

   ```swift
   .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
   .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
   // target: .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
   // target: .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
   ```

2. **Canonical document path** — the OpenAPI document is committed at
   `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`
   (`.yml`/`.json` accepted), which is where the generator plugin looks by
   default, and it describes `GET /api/v1/printer_profiles` and
   `GET /api/v1/colors` (the only surfaces `PaletteAPIClient` uses today —
   issue #39 non-goals forbid new API surfaces).

3. **Runtime linkage** — `OpenAPIRuntime` must be importable from the test
   target (`#if canImport(OpenAPIRuntime)`), proving the dependency is
   actually wired rather than declared.

Fetching the document from a running server:
`curl -fsSL "$SERVER/api/v1/openapi.json" -o .../OpenAPI/openapi.yaml` (or
render it via the server repo).

## The behavior the migration must preserve

`ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientWireContractTests.swift`
pins today's wire behavior (migrate `PaletteAPIClient` onto the generated
client, or wrap it — either way these stay green):

- `GET /api/v1/colors?printer_profile_id=N` and
  `GET /api/v1/printer_profiles`, `Accept: application/json`.
- Bearer token trimmed before use; absent/blank token ⇒ no `Authorization`
  header. HTTP 401 ⇒ `.unauthorized` (drives re-auth), other non-2xx ⇒
  `.badStatus(code)`, undecodable body ⇒ `.malformedResponse`.
- Snake_case envelopes: `{"printer_profiles": [...]}` and
  `{"colors": [...], "printer_profile": {...}}` decoding into
  `PrinterProfileDTO` / `PaletteColorDTO` (including `responses` keyed by
  light-source strings, where unknown keys drop and missing measurements are
  absent, not zero).

The disk cache and offline fallback must remain untouched:
`CachedProfileColors` / `PaletteColorDTO` keep decoding from the cached
snake_case JSON exactly as
`ProfileColorCacheTests` (per-server/profile namespacing, corrupt-file =
miss, offline-stale serving, `Clear Cache`) and `APIDecodingTests` pin. The
cache stores wire DTOs, so as long as the DTO types survive the migration
(wrap the generated client rather than replacing them), nothing else moves.

## Migration notes (fill in the PR description when implementing)

- [ ] Generated-client migration notes: generated module/target name, whether
      `PaletteAPIClient` wraps the generated `Client` or was replaced by it,
      transport used (`URLSessionTransport`), and how the offline-stale
      paths kept working.
- [ ] Any `/api/v1` shape changes found while generating (fields the spec
      types that the hand-written DTOs ignored, naming drift, new fields).
- [ ] Parity test results: `swift test` output including
      `SolverParityCorpusTests` (ties, exclusions, weight handling), plus the
      corpus fixture provenance from `docs/PARITY_CORPUS.md`.
