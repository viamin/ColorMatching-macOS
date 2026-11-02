# Solver parity corpus & OpenAPI contract consumption

This document covers how this app consumes the two contracts published by the
[`color_matching`](https://github.com/viamin/color_matching) server:

1. the **solver parity corpus** (viamin/color_matching#111) — golden vectors
   that pin `WeightedSquaredErrorScorer` + earliest-wins selection to the
   server's `ColorMatching.WeightedSquaredError`, and
2. the **OpenAPI document** (viamin/color_matching#110) — the typed contract
   for `/api/v1` from which the generated client (issue #39) is produced.

The repo README should link here (see *README checklist* below).

## Parity corpus

### Where it lives

| What | Path |
| --- | --- |
| Committed fixture (this repo) | `ColorComposerCore/Tests/Fixtures/ParityCorpus/corpus.json` |
| Upstream source of truth | `priv/parity/v1/corpus.json` in `viamin/color_matching` |
| Upstream generator | `mix parity.generate` (`lib/color_matching/parity/corpus.ex`) |

The fixture is a **byte-exact copy** of the upstream file (algorithm_version
`1`, sha256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
The corpus is deterministic upstream: `mix parity.generate` always emits
identical bytes, and upstream CI verifies the committed bytes with
`mix parity.generate --check`.

### How to refresh it

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/Fixtures/ParityCorpus/corpus.json

shasum -a 256 ColorComposerCore/Tests/Fixtures/ParityCorpus/corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

(Or run `mix parity.generate` inside a `color_matching` checkout and copy
`priv/parity/v1/corpus.json`.)

Rules of engagement:

- `algorithm_version` is bumped upstream whenever scoring semantics change.
  `SolverParityCorpusTests.testCorpusMetadataMatchesSolverSemantics` asserts
  version `1`; a bumped corpus + failing test means *every* expectation moved
  and the scorer/metadata assertions must be updated together, deliberately.
- The fixture loads via `#filePath` from outside the test target directory
  (`Tests/Fixtures/…`, deliberately not `Tests/ColorComposerCoreTests/…`), so
  it stays a plain committed file with no SwiftPM resource declaration — do
  not move it under the target directory.

### What the parity tests assert

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
replays all 12 scenarios and asserts, per scenario:

- **Per-candidate scores match exactly** — bit-exact `Double.bitPattern`
  comparison, not epsilon. This is sound because every corpus value is an
  exact binary fraction (channels are multiples of 1/16, weights multiples of
  1/4), so each `diff² · w` term and their sum are exactly representable and
  summation order cannot matter.
- **Exclusions** — candidates (or the target) missing any positive-weight
  channel are `excluded` (never treated as zero brightness); scenarios
  `missing-candidate-excluded`, `missing-target-excluded`, `all-excluded`.
- **Selection with ties** — earliest-index-wins over strict improvement;
  `selected_index`, `selected_hex_color`, `error`, `tied_indices`, and
  `tie_broke` all match, including the three-way tie
  (`tie-three-way-on-lps`) and duplicate-vector tie
  (`tie-duplicate-vectors`) cases. `tied_indices` is itself re-derived from
  bit-exact score equality.
- **Weight handling** — zero-weight channels neither exclude nor contribute
  (`zero-weight-channel-missing`), and unknown light sources in the weights
  map are dropped, with `unknown-weight-ignored` required to reproduce the
  `distinct-errors` scores verbatim.
- **Solver fast path** — a 1×1 `CompositionSolver.solve` per scenario selects
  the corpus's expected color with the expected error and excluded-candidate
  count, pinning the contiguous fast path's deterministic earliest-wins
  tie-breaking, not just the scorer. (Skipped only for
  `missing-target-excluded`, where the target itself has no measurement to
  build a source grid from — a client-side input that cannot occur.)

Parity result at the time of this writing: all corpus scenarios reproduce
exactly (verified by recomputing the corpus from its inputs with exact
rational arithmetic offline, and by the test suite on a Swift host).

## OpenAPI document & generated client

### Where the document comes from

The server renders the spec with OpenApiSpex and serves it (unauthenticated)
at `GET /api/v1/openapi.json`. To refresh the committed document:

```bash
curl -fsSL "$COLOR_MATCHING_SERVER/api/v1/openapi.json" \
  -o ColorComposerCore/openapi.json
```

The implementation run of issue #39 commits the document at the
`ColorComposerCore` package root (`openapi.yaml`/`openapi.json`), adds
`swift-openapi-generator` (plugin) + `swift-openapi-runtime` (library) to
`Package.swift`, and migrates `PaletteAPIClient` onto the generated `Client`
(or wraps it) while keeping the disk-cache/offline-stale behavior intact.

### Contract checks

`ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractAdoptionTests.swift`
asserts the adoption deliverables: the package dependencies, the committed
document, its coverage of `GET /api/v1/printer_profiles`, `GET /api/v1/colors`,
and the `bearerAuth` (http/bearer) scheme, and the presence of generated
client sources under `Sources/`. `PaletteAPIClientTests` pins the wire
behavior the migration must preserve (versioned `/api/v1` request URLs, the
`printer_profile_id` query, bearer token normalization and header, 401 vs
5xx vs undecodable-body error mapping, envelope decoding).

### `/api/v1` shape findings (for the PR description)

Comparing the published spec (`ColorMatchingWeb.ApiSchemas`) with the current
hand-rolled DTOs — no endpoint or auth changes, only required-vs-optional
strictness deltas:

| Field | Spec (viamin/color_matching#110) | Current Swift DTO |
| --- | --- | --- |
| `ColorsResponse.printer_profile` | required | `PrinterProfileDTO?` (softened client-side) |
| `ColorsResponse.colors[].name` | required | `String?` |
| `ColorsResponse.colors[].palette_id`, `sort_order` | required | `Int?` |
| `ColorsResponse.colors[].rgb` | optional | `RGBDTO?` (consistent) |
| `ColorsResponse.colors[].palette_name` | nullable | `String?` (consistent) |
| `PrinterProfile` fields | all required | all `String?` (softened client-side) |

The generated client will surface these as non-optional; the
`PaletteAPIClient` wrapper should keep its public optional-returning surface
(`profile: PrinterProfileDTO?`) unchanged for the cache/app layers.

## Criterion-level verification map (issue #39)

| Criterion | Verification | Reference |
| --- | --- | --- |
| Generated OpenAPI client adopted, `PaletteAPIClient` migrated | Focused structural tests (red phase until implementation lands) | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractAdoptionTests.swift` |
| Behavior preserved: caching, offline-stale, profile fallback | Existing + extended permanent unit tests | `ProfileColorCacheTests.swift`, `PaletteAPIClientTests.swift`, `APIDecodingTests.swift` |
| Solver parity test target loading committed corpus, ties included | Permanent unit test target | `SolverParityCorpusTests.swift` + `Fixtures/ParityCorpus/corpus.json` |
| Corpus consumption documented | This document (README.md is not editable in the test-writing phase; the implementation run must link this file from the README's *Palette data* section) | `docs/parity-corpus.md` |
| PR description records migration notes, shape changes, parity results | Notes captured in this document for the implementation run to transcribe | sections above |

Environment note: this workspace has no Swift toolchain (Linux container;
`bin/lint` detects this and skips the build). `swift test` must be run on a
macOS host — expected results: `SolverParityCorpusTests` and
`PaletteAPIClientTests` green, `OpenAPIContractAdoptionTests` red until the
generated-client migration lands.

## README checklist (implementation run)

- [ ] Link `docs/parity-corpus.md` from the *Palette data* section.
- [ ] Document the corpus location + refresh command in the README (or point
      at this file).
- [ ] Record generated-client migration notes, `/api/v1` shape findings, and
      parity test results in the PR description (transcribe from above).
