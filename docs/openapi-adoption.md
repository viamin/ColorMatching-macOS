# OpenAPI client adoption (issue #39)

`PaletteAPIClient` talks to the `color_matching` `/api/v1` endpoints. The
server is publishing an OpenAPI spec (viamin/color_matching#110); this package
must consume it via a generated typed client instead of hand-written decoding.
This document is the contract the test suite enforces and the checklist the
migration PR must record.

> Enforced by `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift`
> and `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientWireContractTests.swift`.

## Artifacts the tests require

1. **OpenAPI document committed in the package.** Canonical path (the
   `swift-openapi-generator` SwiftPM plugin default):

   ```
   ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml
   ```

   Accepted alternatives (no test change needed): `openapi.yml` or
   `color_matching.yaml` in the same directory, or
   `ColorComposerCore/OpenAPI/{openapi,color_matching}.yaml`.

   The document must describe both operations the app consumes:

   - `GET /api/v1/printer_profiles`
   - `GET /api/v1/colors` (query: `printer_profile_id`)

2. **Package manifest adoption.** `ColorComposerCore/Package.swift` must
   reference `swift-openapi-generator`, `swift-openapi-runtime`, and apply the
   `OpenAPIGenerator` plugin to the `ColorComposerCore` target.

## Behavior that must survive the migration

`PaletteAPIClient` may be migrated to the generated client directly or wrapped
by it — whichever keeps the following exactly as pinned by the wire-contract
tests:

- Endpoint URLs: `{baseURL}/api/v1/printer_profiles` and
  `{baseURL}/api/v1/colors?printer_profile_id=N` (base URL with or without a
  trailing slash produces the same request).
- Headers: `Accept: application/json`; `Authorization: Bearer <trimmed token>`
  only when a non-empty token is configured.
- Envelope shapes (snake_case): `printer_profiles: [...]` and
  `colors: [...], printer_profile: {...}|null|absent`; nullable profile
  metadata fields; per-response provenance (`source`, `raw_value`, `raw_unit`,
  `apparent_brightness`, `measured_at`, `test_run_id`).
- Error mapping: 401 → `PaletteAPIError.unauthorized`, other non-2xx →
  `.badStatus(status)`, undecodable body → `.malformedResponse`.
- The disk cache and offline fallback built on top of the client
  (`ProfileColorCache`: per-server/profile color caching, offline-stale
  badges with fetch date, cached profile fallback) is covered by
  `ProfileColorCacheTests` and must remain green, unchanged.

## PR description checklist (for the migration PR)

The pull request that lands the generated client must record:

- [ ] **Generated-client migration notes** — wrap vs. replace decision, where
      the OpenAPI document lives, how to regenerate after spec updates.
- [ ] **Any `/api/v1` shape changes found** while generating the client
      (fields the hand-written DTOs ignored, nullability differences, new
      endpoints) and whether they changed app behavior.
- [ ] **Solver parity test results** — `swift test --filter
      SolverParityCorpusTests` output, including tie-case findings (see
      `docs/solver-parity-corpus.md`).
