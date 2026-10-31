# Generated OpenAPI client migration — verification plan and findings

Working notes for issue #39 (adopt the generated OpenAPI client for
`/api/v1` and enforce solver parity). This document is the source for the
PR description's migration notes; the tests referenced here are the
criterion-level evidence.

## Deliverable → verification map

| Issue deliverable | Permanent verification |
| --- | --- |
| Generated client keeps `PaletteAPIClient`'s observable wire behavior | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` — canonical endpoints (`GET /api/v1/printer_profiles`, `GET /api/v1/colors?printer_profile_id=N`), `Accept: application/json`, trimmed bearer token (absent when blank), 401 → `.unauthorized`, other non-2xx → `.badStatus`, undecodable body → `.malformedResponse` |
| Per-server/profile color caching unchanged | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` (existing suite: server scoping/normalization, corrupt-file misses, `removeAll` semantics, snake_case on-disk format) |
| Offline-stale badges / cached profile fallback | Cache contract covered by `ProfileColorCacheTests` (`allEntries(serverBaseUrl:)` is the profile-picker fallback; `entry(for:serverBaseUrl:)` feeds the stale badge). The UI badge itself (`ColorCatalog.isServingFromCache`) is not unit-testable without injecting a transport into `ColorCatalog` — verify by inspection in review when the client is swapped |
| Solver parity corpus test | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` + `Fixtures/parity/v1/corpus.json` (see docs/parity-corpus.md) |
| Corpus provenance (one-off) | `.ephemeral-tests/verify_parity_corpus_fixture.sh` — byte-identical to upstream `priv/parity/v1/corpus.json`; remove before merge |

Migration rule for the implementation run: whether the generated client
*replaces* or is *wrapped by* `PaletteAPIClient`, the tests above must pass
without modification. Any intentional behavior change (e.g. surface the
required `printer_profile` as non-optional) updates the pinned test **in the
same PR**, with the delta called out in the PR description.

## `/api/v1` shape findings (from the published OpenAPI spec)

The server publishes an OpenAPI 3 contract
(`ColorMatchingWeb.ApiSpec`, viamin/color_matching#113) enforced upstream in
CI. Compared with the hand-rolled DTOs in `APIModels.swift`:

1. `ColorsResponse.printer_profile` is **required** by the spec; the current
   `ColorsResponse` DTO decodes it as optional. `testFetchColorsTolerates…`
   pins the tolerant behavior so the migration makes a deliberate choice.
2. `PrinterProfile` string fields (`printer_make_model`, `paper_type`,
   `ink_type`) are required by the spec; the DTO keeps them optional (the
   disk cache stores entries with a `nil` profile, so tolerant decoding must
   survive the migration).
3. `ColorsResponse.colors[].rgb` is optional and `palette_name` is nullable
   — matches the DTO's optionals; no delta.
4. Envelope keys are snake_case (`printer_profiles`, `printer_profile_id`
   query parameter) — pinned by the canonical-endpoint tests.

## Parity findings (pre-implementation baseline)

Validated against the committed corpus (12 scenarios):

- Scores reproduce **exactly** (bit-for-bit IEEE 754 doubles): weights are
  applied per active channel as `(candidate − target)² × w`, summed in
  canonical channel order (white, red, green, blue, lps).
- Ties: selection is earliest-index-wins in both implementations
  (`Enum.min_by` upstream keeps the first minimum; the solver's strict
  `sum < bestError` keeps the first winner). Covered scenarios include a
  two-way symmetric tie, a duplicate-vector tie, and a three-way tie.
- Exclusions: a candidate missing any positively-weighted channel is
  excluded, never treated as zero brightness; a target missing such a
  channel excludes every candidate. Zero-weight channels neither exclude
  nor contribute. Unknown weight keys (e.g. `ultraviolet`) are ignored.
- `algorithm_version` is `1`; no semantic drift between the Elixir scorer
  and `WeightedSquaredErrorScorer` at the time of writing.

## Notes for generating the client

- The upstream spec is served by the app (`ColorMatchingWeb.ApiSpec`), not
  committed as a static file; fetch the document from a running server (the
  upstream OpenAPI controller) or generate it upstream, then commit it under
  `ColorComposerCore/openapi/` for the `swift-openapi-generator` plugin.
- `swift-openapi-runtime`'s `URLSessionTransport` must be configured with
  the bearer-token header injection the current client performs (trimmed
  token; no header when absent/blank) — the contract tests assert this.
- Keep `ProfileColorCache` fed with the same DTO values it stores today
  (snake_case on-disk format is pinned by its tests).
