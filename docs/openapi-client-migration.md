# OpenAPI client migration (issue #39)

The `color_matching` server is publishing an OpenAPI spec
(viamin/color_matching#110). This app adopts it: `swift-openapi-generator` +
`swift-openapi-runtime` generate a typed client from the committed document,
and `PaletteAPIClient` either migrates onto that transport or wraps it —
whichever keeps the disk-cache / offline-stale behavior intact.

This note records the contract the tests enforce and the migration notes the
PR description should carry. It is the in-repo reference while the README is
updated as part of the implementation change.

## The committed document

The OpenAPI document is committed at:

```
ColorComposerCore/OpenAPI/openapi.json
```

`OpenAPIDocumentContractTests` enforces, on every `swift test` run:

- the document exists and is OpenAPI v3;
- it describes `GET /api/v1/printer_profiles` (behind
  `fetchPrinterProfiles()`) and `GET /api/v1/colors` (behind
  `fetchColors(printerProfileID:)`) with the `printer_profile_id` **query**
  parameter;
- its component schemas declare the snake_case wire keys the client actually
  decodes: the `printer_profiles` array envelope, the
  `colors`/`printer_profile` envelope, `printer_make_model`/`paper_type`/
  `ink_type`, `hex`/`responses`, and `brightness`.

If the published spec's shapes drift from what this app decodes, that test
fails — the PR should then record the `/api/v1` shape changes found.

## Behavior that must survive the migration

Enforced by `PaletteAPIClientContractTests`, `PaletteFetchCacheRoundTripTests`,
and the existing `PaletteAPIClientTests` / `ProfileColorCacheTests` /
`APIDecodingTests`:

- endpoint URLs: `<base>/api/v1/printer_profiles` and
  `<base>/api/v1/colors?printer_profile_id=N`, `Accept: application/json`;
- bearer-token handling: trimmed tokens are sent, blank/nil tokens send no
  `Authorization` header, and HTTP 401 maps to `PaletteAPIError.unauthorized`
  (distinct from other non-2xx statuses, which map to `.badStatus`);
  undecodable 2xx bodies map to `.malformedResponse`;
- per-server/profile disk caching: fetched wire DTOs are stored verbatim in
  `CachedProfileColors`, round-trip on read, and keep `fetchedAt` — the
  staleness marker behind the offline-stale badge and the cached-profile
  picker fallback;
- solver domain conversion: missing measurements stay absent (never zero),
  unknown light-source keys are dropped.

## Migration notes for the PR description

Record in the PR body when the implementation lands:

1. **Generated-client approach** — migrated `PaletteAPIClient` onto the
   generated client, or wrapped it; where the generated types map onto
   `PrinterProfileDTO` / `PaletteColorDTO` (the disk-cache wire format must
   not change — `PaletteFetchCacheRoundTripTests` pins it).
2. **`/api/v1` shape changes found** — any differences between the committed
   OpenAPI document and the shapes the hand-written client assumed.
3. **Parity test results** — full `swift test --filter SolverParityCorpus`
   output (ties, exclusions, weight handling), per
   docs/solver-parity-corpus.md.

## Status at the time of this writing

The upstream artifacts (viamin/color_matching#110 spec, #111 corpus) are not
published yet — fetching them returns 404. The contract tests are committed
red on purpose: they name exactly what must land (`OpenAPI/openapi.json`,
`ParityCorpus/solver_parity_corpus.json`) and turn green when the
implementation change commits those artifacts and migrates the client.
