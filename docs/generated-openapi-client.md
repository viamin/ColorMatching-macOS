# Generated OpenAPI client (issue #39)

This note records the plan the tests enforce and the notes the migration PR
description should carry. The implementation belongs to the implementation
run; the tests committed alongside this note are the gates.

## What lands

- `swift-openapi-generator` (plugin) + `swift-openapi-runtime` (dependency)
  declared in `ColorComposerCore/Package.swift`.
- The OpenAPI document published by `viamin/color_matching#110`, committed
  where the plugin consumes it, generating a typed client for `/api/v1`.

## Migration approach: wrap, don't replace

`PaletteAPIClient` keeps its public surface (`fetchPrinterProfiles`,
`fetchColors(printerProfileID:)`, `testConnection`, `PaletteAPIError`) and
delegates transport to the generated client. Wrapping — rather than
replacing call sites — is what preserves:

- **Per-server/profile disk caching** (`ProfileColorCache`) and the
  offline-stale badges driven by `isServingFromCache` in `ColorCatalog`;
  all of that lives above the client and is untouched.
- **The error taxonomy**: `unauthorized` (HTTP 401 → re-auth flow),
  `badStatus`, `malformedResponse`. `ColorCatalog.allowsOfflineFallback`
  falls back to the disk cache **only** for transport errors, so the
  generated client's errors must keep mapping onto `PaletteAPIError`
  faithfully.

## Gates already in place (tests)

| Test file | Role |
| --- | --- |
| `OpenAPIClientIntegrationTests` | Red until the manifest declares the OpenAPI plugin + runtime and the committed document covers `printer_profiles` and `colors`; green forever after |
| `PaletteAPIContractTests` | Characterizes the current `/api/v1` request shapes (paths, `printer_profile_id` query, `Accept`, bearer-token handling incl. blank-token suppression) and envelope decoding; the generated client must reproduce all of it |
| `ProfileColorCacheTests` (pre-existing) | Per-server/profile cache namespacing, corrupt-file misses, clear-cache |
| `SolverParityCorpusTests` | Solver parity — see `solver-parity-corpus.md` |

## PR description checklist (for the implementation run)

- Generated-client migration notes (wrap decision, generated types adopted).
- Any `/api/v1` shape drift found between the spec and the current DTOs
  (`PaletteAPIContractTests` is the baseline; field-by-field diff against the
  spec belongs in the PR).
- Parity test results (`swift test --filter SolverParityCorpus`), including
  tie, exclusion, and weight-handling findings.
