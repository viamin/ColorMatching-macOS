# OpenAPI generated client — migration plan and verification map

`PaletteAPIClient` talks to `color_matching`'s `/api/v1` endpoints with a
hand-written `URLSession` + `Codable` client. The server is publishing an
OpenAPI spec (viamin/color_matching#110); this app will generate a typed
client from it (issue #39). This document records the migration plan, the
behavior invariants that tests pin, and the acceptance-criterion →
verification mapping required in the PR/run evidence.

## Canonical document location

The committed OpenAPI document lives at **`ColorComposerCore/openapi.yaml`**
(`.yml`/`.json` accepted). `OpenAPIContractTests.testOpenAPIDocumentIsCommittedAtTheCanonicalPath`
fails until it is committed — that is the red-phase guard for this
deliverable. Regenerate the typed client after every refresh of the document.

## Planned package changes (implementation phase)

- Add dependencies: `swift-openapi-runtime`, plus `swift-openapi-generator`
  (as a package plugin) and a URLSession transport (`swift-openapi-urlsession`)
  for `ColorComposerCore`.
- Generate sources into `Sources/ColorComposerCore/OpenAPI/` from the
  canonical document, and wrap the generated `Client` **inside**
  `PaletteAPIClient` rather than replacing it — the public surface stays
  `init(baseURL:token:session:)`, `fetchPrinterProfiles()`,
  `fetchColors(printerProfileID:)`, `testConnection()`.
- The disk-cache/offline-stale layers (`ProfileColorCache`, `ColorCatalog`)
  sit above `PaletteAPIClient` and must remain untouched by the migration.

## Behavior invariants (each pinned by a test)

| Invariant | Pinned by |
| --- | --- |
| `GET /api/v1/printer_profiles`, `GET /api/v1/colors?printer_profile_id=N` | `PaletteAPIClientTests.testFetchColorsRequestsProfileScopedColorsEndpoint` |
| `Accept: application/json`; trimmed `Authorization: Bearer …`; header omitted when token empty/nil | `PaletteAPIClientTests.testFetchPrinterProfilesUsesTrimmedBearerToken`, `testOmitsAuthorizationHeaderWithoutToken`, `testFetchColorsRequestsProfileScopedColorsEndpoint` |
| 401 ⇒ `PaletteAPIError.unauthorized` (re-auth flow) | `PaletteAPIClientTests.testFetchPrinterProfilesThrowsUnauthorizedWithoutRetryHandler` |
| Non-2xx ⇒ `.badStatus(code)` | `PaletteAPIClientTests.testFetchColorsThrowsBadStatusForServerError` |
| Undecodable body ⇒ `.malformedResponse` | `PaletteAPIClientTests.testFetchColorsThrowsMalformedResponseForUndecodableBody` |
| Snake_case envelope/DTO decoding (`printer_profiles`, `colors`, `printer_profile`, response map) | `APIDecodingTests`, `PaletteAPIClientTests.testFetchColorsRequestsProfileScopedColorsEndpoint` |
| Reachability probe succeeds on any 2xx | `PaletteAPIClientTests.testTestConnectionSucceedsOn2xx` |
| Per-server/profile disk cache, offline-stale entries, cached-profile fallback unchanged | `ProfileColorCacheTests` (67 tests; unchanged by this migration) |
| Committed spec keeps covering every field the client decodes | `OpenAPIContractTests.testCommittedDocumentCoversTheClientAPIContract` |
| Snapshot of today's wire contract (`Fixtures/OpenAPI/api-v1-expected-contract.json`) matches DTO `CodingKeys` exactly | `OpenAPIContractTests.testSnapshotPinsSchemaPropertySetsExactly`, `testSnapshotCoversTheClientAPIContract` |

## Detecting `/api/v1` shape changes

`Fixtures/OpenAPI/api-v1-expected-contract.json` snapshots the wire contract
implied by `APIModels.swift`. When the published spec (#110) is committed:

- fields the client decodes that the spec no longer describes ⇒ coverage test
  fails (shape change found — record it in the PR description);
- snapshot schema property sets drifting from the DTOs ⇒ snapshot test fails
  (update snapshot **and** DTO mapping together, noting the server-side PR).

## PR description checklist (implementation phase)

1. Generated-client migration notes (dependencies added, wrap-vs-replace
   choice, generated paths, regeneration command).
2. Any `/api/v1` shape changes found while adopting the spec (each mapped to
   the server PR that introduced it).
3. Parity corpus results: case count, tie cases verified, exclusion cases,
   weight handling, score tolerance.
4. Confirmation that disk cache + offline fallback behavior is unchanged
   (cite `ProfileColorCacheTests` run).

## Acceptance-criterion → verification map

| Criterion (issue #39) | Verification |
| --- | --- |
| Generated OpenAPI client adopted; `PaletteAPIClient` migrated (or wraps it) | Red guard: `OpenAPIContractTests.testOpenAPIDocumentIsCommittedAtTheCanonicalPath` (fails until the spec from viamin/color_matching#110 is committed at the canonical path). Behavior parity: the `PaletteAPIClientTests` pins listed above. |
| Existing behavior preserved (per-server/profile color caching, offline-stale badges, cached profile fallback) | Existing permanent suite `ProfileColorCacheTests` (cache layer) + `PaletteAPIClientTests`/`APIDecodingTests` (fetch layer); app-level offline-stale badges remain covered by the app test target. |
| Solver parity test target loading the committed corpus, exact selections incl. ties | Permanent unit tests: `SolverParityCorpusTests.testCommittedCorpusFilesReplayWithExactParity` + seed fixture; red guard `testCanonicalUpstreamCorpusIsCommitted` until the corpus from viamin/color_matching#111 lands. |
| Corpus consumption documented (README) | `docs/solver-parity-corpus.md` now; fold into README when the corpus lands (test-writing phase cannot edit `README.md`). |
| PR description records migration notes, shape changes, parity results | `docs/openapi-generated-client.md` checklist above; final prose belongs to the implementation PR. |
