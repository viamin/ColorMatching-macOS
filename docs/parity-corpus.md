# Solver parity corpus and the `/api/v1` OpenAPI contract

This app shares two unenforced contracts with the
[`color_matching`](https://github.com/viamin/color_matching) server. Both are
now pinned by committed test fixtures under
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/`:

| Contract | Fixture | Upstream source | Tests |
| --- | --- | --- | --- |
| Solver parity (golden vectors) | `Fixtures/parity/v1/corpus.json` | `priv/parity/v1/corpus.json` (viamin/color_matching#112) | `SolverParityCorpusTests` |
| `/api/v1` wire shapes | `Fixtures/openapi/v1/openapi.json` | `GET /api/v1/openapi.json` (viamin/color_matching#113) | `OpenAPIContractTests` |

## Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver plus the earliest-index-wins
selection of `ColorMatching.IlluminantMatching`. The corpus is the shared
source of truth both test suites replay so that silent divergence —
tie-breaking, missing-measurement exclusion, or channel weighting — is caught.

Each scenario records the palette response vectors, the target vector, the
channel weights (which may include unknown light sources like `ultraviolet`;
they are ignored), the per-candidate score table (`"excluded"` marks
missing-measurement exclusions), the expected selection and error, and
explicit tie evidence (`tie_broke`, `tied_indices`).

### Where it lives

- **This repo:** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
- **Upstream:** `priv/parity/v1/corpus.json` in `viamin/color_matching`

The fixture is loaded relative to the test source (`#filePath`), so it works
under both `swift test` and the generated Xcode project without bundle-resource
declaration.

### How the tests replay it

`SolverParityCorpusTests`:

1. **Score table** — every palette candidate is scored with
   `WeightedSquaredErrorScorer` using the scenario's weights; the result must
   equal the recorded score exactly (corpus values are exact dyadic rationals,
   so even a last-bit divergence fails).
2. **Selection** — the score table is replayed with the server's
   earliest-index-wins rule and must reproduce `selected_index`,
   `selected_hex_color`, `error`, `tie_broke`, and `tied_indices`.
3. **Solver fast path** — each replayable scenario is also solved as a 1×1
   composition through `CompositionSolver`, exercising the app's real
   per-cell selection (and its own earliest-wins tie-breaking).

Scenarios whose *target* is missing an active channel cannot be expressed as
source grids and are covered by the scorer-level replay only.

### Refreshing the corpus

The corpus is deterministic on the server (`mix parity.generate`; upstream CI
verifies committed bytes). After a server solver change lands upstream:

```bash
cd ColorComposerCore/Tests/ColorComposerCoreTests
curl -o Fixtures/parity/v1/corpus.json \
  https://raw.githubusercontent.com/viamin/color_matching/master/priv/parity/v1/corpus.json
cd ../../../.. && (cd ColorComposerCore && swift test --filter SolverParityCorpus)
```

The corpus is stamped with `algorithm_version`. When it changes, every
expectation has moved: update the fixture and
`SolverParityCorpusTests.supportedAlgorithmVersion` together, and expect
real semantic changes (re-run the full suite, not just the parity tests).

## `/api/v1` OpenAPI snapshot

The server publishes an OpenAPI 3 document at `GET /api/v1/openapi.json`
(served live by OpenApiSpex). The committed snapshot contains the two
operations `PaletteAPIClient` consumes — `GET /api/v1/printer_profiles` and
`GET /api/v1/colors?printer_profile_id=N` — with their bearer security
scheme, parameters, and response schemas.

`OpenAPIContractTests` pins:

- both paths, the required `printer_profile_id` query parameter, and bearer
  auth on each operation;
- the envelope required-keys (`printer_profiles`; `printer_profile` +
  `colors`) and the per-color required set
  (`id, name, hex, palette_id, sort_order, responses` — `rgb` and
  `palette_name` optional);
- that the client's DTO decoding accepts a spec-minimal payload (every
  required field present, every optional field absent) and still converts to
  the solver's domain model (hex fallback when `rgb` is omitted).

### Refreshing the snapshot

```bash
curl -o Fixtures/openapi/v1/openapi.json \
  http://localhost:4000/api/v1/openapi.json
```

(Trim to the consumed paths if the server document is large; keep the schema
components the two operations reference.)

### Migration note (issue #39)

When `PaletteAPIClient` migrates onto the `swift-openapi-generator` typed
client, `PaletteAPIClientTests` (wire behavior: paths, query, headers,
status-code → error mapping, tolerant decoding) and `OpenAPIContractTests`
must keep passing unchanged — the per-server/profile disk cache and
offline-stale fallback (`ProfileColorCache`, `CachedProfileColors`) sit
downstream of exactly these requests and decodes.

Known, deliberate looseness recorded by the tests: the spec marks
`printer_profile` as **required** inside `ColorsResponse` and `name` /
`palette_id` / `sort_order` as required per color, while the Swift DTOs model
them as optional so partial server responses still yield servable colors for
the offline cache.
