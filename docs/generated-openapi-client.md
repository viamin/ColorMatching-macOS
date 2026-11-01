# Generated OpenAPI client — migration test plan (issue #39)

This document maps each acceptance criterion of issue #39 to its verification, and records
what the test-writing phase committed. It is also the source for the PR description's
"generated-client migration notes" and "parity findings" sections.

## Acceptance criteria → verification

| # | Criterion | Verification | Where |
| --- | --- | --- | --- |
| AC-1 | `swift-openapi-generator` + `swift-openapi-runtime` in `ColorComposerCore`; typed client generated from the OpenAPI document; `PaletteAPIClient` migrated (or wraps it) with disk-cache/offline behavior intact | `OpenAPIContractTests.testOpenAPIDocumentIsCommittedAndDocumentsConsumedOperations` — permanent unit test, **red until the spec from viamin/color_matching#110 is committed** at `ColorComposerCore/OpenAPI/openapi.json`, then guards that both consumed operations stay documented. The wire-contract tests below must stay green across the migration. | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift` |
| AC-2 | Existing behavior preserved: per-server/profile color caching, offline-stale badges, cached profile fallback | Existing permanent unit tests for the disk cache (`ProfileColorCacheTests`, 69 tests: per-server namespacing, corrupt/symlink misses, overwrite semantics). API error taxonomy (`unauthorized` on 401 → re-auth flow, `badStatus`, `malformedResponse`) pinned by `PaletteAPIClientTests` so the migration cannot silently change failure modes. Offline-stale *badges* are UI; verified by human review in the implementation PR. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`, `PaletteAPIClientTests.swift` |
| AC-3 | Solver parity test target loading the committed corpus, asserting `WeightedSquaredErrorScorer` selections match exactly, including ties | Permanent unit tests driving every corpus scenario through both the scorer and `CompositionSolver`'s fast path: scores, exclusions, selections, tie groups, earliest-index-wins. | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` + `Fixtures/parity_corpus.json` (see `docs/parity-corpus.md`) |
| AC-4 | Corpus consumption documented (where it lives, how to refresh) | `docs/parity-corpus.md` (location, format, refresh commands, SHA-256 provenance). A README pointer is added in the implementation run — `README.md` is outside the test-phase allowlist. | `docs/parity-corpus.md` |
| AC-5 | PR description records migration notes, `/api/v1` shape findings, parity results | Populated from this document when the implementation PR opens. | this file |

## Wire-contract tests that must survive the migration

`PaletteAPIClientTests` (extended in this phase) pins the externally observable contract of
`PaletteAPIClient`; whatever transport ends up underneath (raw `URLSession` today,
generated client tomorrow) must keep these true:

- `GET {base}/api/v1/printer_profiles` and `GET {base}/api/v1/colors?printer_profile_id=N`
  with `Accept: application/json` and a trimmed `Authorization: Bearer <token>` header.
- HTTP 401 → `PaletteAPIError.unauthorized`; other non-2xx → `.badStatus(code)`;
  undecodable 2xx body → `.malformedResponse`.
- Envelope shapes: `{"printer_profiles": […]}` and
  `{"colors": […], "printer_profile": {…}?}` with snake_case keys; `printer_make_model` /
  `paper_type` / `ink_type` nullable; `responses` is a map keyed by light source where
  unknown keys (e.g. `ultraviolet`) survive on the DTO but are dropped by `toDomain()`.

## OpenAPI document: where it comes from and where it goes

- The server builds its spec with OpenApiSpex and serves it at **`GET /api/v1/openapi.json`**
  (no auth pipeline on that route). Export:

  ```bash
  curl -fsSL "$COLOR_MATCHING_URL/api/v1/openapi.json" \
    -o ColorComposerCore/OpenAPI/openapi.json
  ```

- Commit the export at `ColorComposerCore/OpenAPI/` (the conventional
  `swift-openapi-generator` layout) with an `openapi-generator.yaml` config in
  `ColorComposerCore/`; add `swift-openapi-generator` (plugin) and
  `swift-openapi-runtime` (dependency) to `Package.swift`, plus
  `swift-http-types` transitively.
- `OpenAPIContractTests` searches `ColorComposerCore/OpenAPI/{openapi,color_matching,api}.{json,yaml,yml}`
  and the repository root; JSON documents are structurally validated (both paths expose
  `get`), YAML documents get a path-presence check.

## `/api/v1` shape findings (researched from viamin/color_matching `main`)

- Both endpoints this app consumes are unchanged on `main`:
  `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=…`
  (`ColorPaletteController.printer_profiles` / `.colors`).
- New endpoints the app does **not** use (non-goal to adopt): printer-profile-scoped
  colors `GET /printer_profiles/:id/colors`, `GET /printer_profiles/:id/metamer_pairs`,
  `GET /palettes`, test-sheet capture endpoints, `POST /api/illuminant_measurements(…/bulk)`,
  `POST /api/multi_image_mapping`, `GET /brightness_reference_scales/:illuminant`.
- Auth: `:api_auth` plug (bearer token) protects both consumed endpoints; the spec declares
  an `http`/`bearer` security scheme (`bearerAuth`) — matches the app's token handling.
- Unknown methods on API routes return 405 via `MethodNotAllowedController` (worth noting
  when mapping `badStatus` in the generated client).
- The spec is generated from Phoenix routes at runtime (`ColorMatchingWeb.ApiSpec`), so the
  committed export must be refreshed deliberately after server releases; there is no
  committed spec file upstream to vendor.

## Parity findings (from the corpus, v1 / `algorithm_version` 1)

- 12 scenarios; the Swift scorer and solver reproduce **all** recorded score tables,
  selections, and errors exactly (differences 0 within `1e-12`; values are exact binary
  fractions).
- Ties: 2-way symmetric (`tie-symmetric-around-target`), duplicate-vector
  (`tie-duplicate-vectors`), 3-way (`tie-three-way-on-lps`), zero-weight-induced
  (`zero-weight-channel-missing`), and mixed 8-color palette (`mixed-large-palette`) — all
  resolve to the earliest palette index, matching `IlluminantMatching.best_match/4` and the
  solver's strict `<` comparison.
- Exclusions: missing candidate channel (would otherwise win on measured channels) and
  missing target channel exclude candidates entirely; exclusion is per-scenario recorded as
  the string `"excluded"` in score tables. `all-excluded` selects nothing and the solver
  records an unmatched cell with infinite error.
- Weight handling: zero-weight channels are optional for candidates and contribute nothing;
  unknown light-source weight keys (`ultraviolet`) are ignored without affecting scores.
- Verified in this environment by a binary64 simulation of the Swift semantics (Python
  floats are IEEE-754 doubles) against every scenario; `swift test` execution happens on a
  macOS/Swift host in CI — no Swift toolchain exists in the authoring container.
