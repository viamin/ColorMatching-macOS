# Generated OpenAPI client adoption plan (issue #39)

This documents the plan for adopting `swift-openapi-generator` /
`swift-openapi-runtime` in `ColorComposerCore`, the behavior that must survive
the migration unchanged, and how each acceptance criterion of issue #39 is
verified. The tests committed alongside this document are the executable half
of the plan; the implementation changes listed here are the parts that touch
non-test files and therefore land in the implementation phase.

## Adoption guards (red until implemented)

`ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift`
pins the two structural deliverables:

1. **The OpenAPI document is committed at**
   `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json`.
   The location matches `swift-openapi-generator`'s default document
   discovery. The format is pinned to **JSON** (not YAML) deliberately: the
   contract tests parse the document with `JSONSerialization`, so the package
   needs no YAML dependency; the generator accepts JSON documents.
   `testOpenAPIDocumentIsCommittedAtPinnedLocation` is red until the document
   (from viamin/color_matching#110) is committed there.
2. **`Package.swift` wires up the toolchain** — declares the
   `swift-openapi-generator` package (provides the `OpenAPIGenerator` build
   plugin), the `swift-openapi-runtime` dependency, and attaches the plugin to
   the `ColorComposerCore` target. `testPackageManifestDeclaresOpenAPIToolchain`
   is red until then.

Once the document exists, the same file enforces the `/api/v1` surface the
app consumes: `GET /api/v1/printer_profiles` and `GET /api/v1/colors` (with a
required `printer_profile_id` query parameter), operationIds present, and an
`info.version` string. Any spec-driven shape change to the endpoints the app
uses must be a conscious change visible in that test.

## Migration notes (for the implementation phase)

- **Wrap, don't rewrite, `PaletteAPIClient`.** The public surface
  (`baseURL`, `token`, injectable `URLSession`, `PaletteAPIError` mapping,
  `fetchPrinterProfiles`, `fetchColors`, `testConnection`) is load-bearing
  for the app and for the tests below. Preferred shape: keep
  `PaletteAPIClient` as the app-facing type and back its endpoints with the
  generated `Client` (constructed from the injected session), mapping
  generated errors back onto `PaletteAPIError` (`unauthorized` for 401,
  `badStatus` for other non-2xx, `malformedResponse` for undecodable
  payloads).
- **Behavior that must not change** (executable pins):
  - `PaletteAPIWireBehaviorTests` — versioned paths, query parameter, bearer
    token trimming/forwarding/omission, 401 vs 500 vs malformed mapping,
    envelope decoding, and `toDomain()` conversion.
  - `ProfileColorCacheTests` (pre-existing) — per-server/per-profile disk
    cache, offline-stale timestamps, cached-profile fallback, clear-cache.
    These tests are unaffected by the migration because the cache stores wire
    DTOs; they stay green only if the client keeps feeding it the same DTOs.
- **`bin/lint` on Linux** builds a portable subset excluding
  `PaletteAPIClient.swift`; when the package gains OpenAPI targets/plugins,
  revisit that harness (and consider whether the excluded files still need
  excluding) so the portable subset keeps compiling.

## Acceptance-criterion → verification map

| Criterion (issue #39) | Verification | Kind |
| --- | --- | --- |
| Generated client adopted; `PaletteAPIClient` migrated or wrapped | `OpenAPIContractTests.testOpenAPIDocumentIsCommittedAtPinnedLocation` + `testPackageManifestDeclaresOpenAPIToolchain` (red markers), spec surface pins once present | unit test (structural guards) |
| Disk cache / offline-stale / cached-profile fallback preserved | `PaletteAPIWireBehaviorTests` (wire pins) + pre-existing `ProfileColorCacheTests` (cache semantics) | unit tests |
| Parity corpus test target loads committed corpus, selections match exactly incl. ties | `SolverParityCorpusTests` + committed fixture `Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/weighted_squared_error_v1.json` | unit test over committed artifact |
| Corpus consumption documented (where it lives, how to refresh) | `docs/solver-parity-corpus.md` (README section to be added in the implementation phase; this run is tests/docs-only) | documentation |
| PR description records migration notes, `/api/v1` shape findings, parity results | PR body at publication time; parity outcomes are reproducible via `SolverParityCorpusTests` | human/PR evidence |
| `swift test` green with corpus test + generated client | `cd ColorComposerCore && swift test` on a Swift host (no toolchain in the authoring container; see PR evidence) | test run |

## Parity findings to record in the PR

When the PR is opened, the description should capture (all reproducible via
`SolverParityCorpusTests`):

- **Ties**: exact-score ties resolve to the earliest palette index; the corpus
  pins this with a reversed-order twin case (selection flips with order).
- **Exclusions**: missing candidate measurements exclude; a target missing a
  required channel excludes every candidate; present-with-zero ≠ missing.
- **Weight handling**: weight 0 channels neither require nor contribute;
  weighting can flip a selection (0.16 vs 0.25 case at 1:1 vs 10:1 weights).
- **`/api/v1` shape changes found**: surfaced by `OpenAPIContractTests` and
  `PaletteAPIWireBehaviorTests` / `APIDecodingTests` (wire envelopes); none
  expected beyond the published spec's naming.
