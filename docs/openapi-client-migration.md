# OpenAPI generated-client migration notes (#39)

Working notes for migrating `PaletteAPIClient` to a client generated from the
server's OpenAPI spec (viamin/color_matching#110). These are the contract
points the migration must satisfy; the tests cited below are the enforcement.

## Wiring

- Commit the spec at `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`
  (or `.json`) — `swift-openapi-generator`'s conventional search path.
- `Package.swift` declares `swift-openapi-generator` (with the
  `OpenAPIGenerator` build plugin on the `ColorComposerCore` target) and links
  `swift-openapi-runtime`.
- Enforced red-until-migrated by `OpenAPISpecContractTests`:
  document present at the conventional path, describing `GET
  /api/v1/printer_profiles` and `GET /api/v1/colors` with the
  `printer_profile_id` query parameter, OpenAPI 3.x.

## `/api/v1` shapes as consumed today (migration must not change them)

- `GET /api/v1/printer_profiles` → `{"printer_profiles": [{"id", "printer_make_model", "paper_type", "ink_type", ...}]}`
- `GET /api/v1/colors?printer_profile_id=N` → `{"printer_profile": {...} | null, "colors": [{"id", "name", "hex", "rgb": {"r","g","b"}, "palette_id", "palette_name", "sort_order", "responses": {"<light_source>": {"brightness", "source", "raw_value", "raw_unit", "apparent_brightness", "measured_at", "test_run_id"}}}]}`
- All keys snake_case; unknown `light_source` keys in `responses` are ignored
  (only the five canonical conditions map).
- Optional bearer token: `Authorization: Bearer <trimmed token>` when a
  non-empty token is set; no header otherwise.

Whether `PaletteAPIClient` migrates onto the generated client directly or wraps
it, its observable behavior is pinned by `PaletteAPIClientTests` and
`PaletteAPIClientContractTests`:

- Endpoint URLs and the `Accept: application/json` header.
- HTTP 401 → `PaletteAPIError.unauthorized`; other non-2xx → `.badStatus(code)`;
  undecodable body → `.malformedResponse`.
- Disk-cache integration: a fetch's `(colors, profile)` must remain storeable
  via `ProfileColorCache` so the offline-stale badge (`fetchedAt`) and the
  cached-profile picker fallback (`allEntries`) keep working. The full cache
  contract (per-server/profile scoping, corrupt-file handling, clear) is
  pinned in `ProfileColorCacheTests` — no changes expected there.

## PR description checklist (for the implementation PR)

- Note whether the wire shapes above matched the published spec or required
  mapping, and any `/api/v1` shape changes found.
- Solver parity findings: ties (earliest-index), exclusions (missing active
  channel ≠ zero), weight handling (zero-weight channels inactive) — see
  `docs/solver-parity-corpus.md` and the parity test results.
- Confirm `swift test` green in `ColorComposerCore` with the parity corpus
  test and the generated client in place, and that
  `PaletteAPIClientContractTests`/`ProfileColorCacheTests` pass unchanged.
