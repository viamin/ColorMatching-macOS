# Solver parity corpus & OpenAPI spec consumption

This app enforces two contracts with the `color_matching` server
(viamin/color_matching):

1. **Solver parity** — `WeightedSquaredErrorScorer` plus the solver's
   earliest-index-wins selection deliberately mirror the server's
   `ColorMatching.WeightedSquaredError` + `IlluminantMatching.best_match/4`.
2. **API shape** — `PaletteAPIClient` consumes `/api/v1`, now described by the
   server's published OpenAPI 3 document.

## Where the corpus lives

The golden-vector corpus is committed at:

```
ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json
```

It is a byte-for-byte copy of the server fixture
`priv/parity/v1/corpus.json`, produced by
[PR #112](https://github.com/viamin/color_matching/pull/112) (the parity
corpus tracked by issue #111). The fixture intentionally lives outside any
test-target directory so `swift test` reads it from disk without a
`Package.swift` resource declaration, and every test target under `Tests/`
can reach it via `../Fixtures/parity/v1/corpus.json`.

## What it pins

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
replays every scenario three ways:

- per-candidate scores (`score` vs `excluded`) must match exactly,
- earliest-index-wins selection, winning error, `tie_broke`, and
  `tied_indices` must match exactly (including exact ties), and
- a 1×1-grid `CompositionSolver` run must select the same palette index,
  exercising the app's real deterministic selection path.

Corpus semantics to preserve when touching the scorer or solver:

- Channels with weight `0` (or absent) are ignored — they neither contribute
  nor exclude, even when unmeasured.
- A candidate **or target** missing any positive-weight channel is
  `excluded`, never treated as zero brightness.
- Unknown weight keys (e.g. `ultraviolet`) are silently ignored — they cannot
  be represented in `ChannelWeights`, which is the desired behavior.
- `algorithm_version` (currently `1`) is bumped upstream whenever scoring
  semantics change; the corpus-contract test fails on a bump, and every
  expectation should be re-reviewed before refreshing the fixture.

## How to refresh the corpus

```bash
git clone https://github.com/viamin/color_matching
cd color_matching
mix deps.get
mix parity.generate          # regenerate priv/parity/v1/corpus.json
mix parity.generate --check  # CI upstream verifies the committed bytes
cp priv/parity/v1/corpus.json <this repo>/ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json
cd <this repo>/ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Upstream CI runs `mix parity.generate --check`, so the copied bytes are
reproducible; a diff after copying means real semantic drift, not noise.

## How to refresh the vendored OpenAPI document

The server publishes its OpenAPI 3 spec at `GET /api/v1/openapi.json`
([PR #113](https://github.com/viamin/color_matching/pull/113), tracked by
issue #110). The app vendors it at:

```
ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml
```

`swift-openapi-generator` (build plugin) + `swift-openapi-runtime`
(dependency) generate the typed client from this document;
`PaletteAPIClient` wraps the generated client. Refresh by fetching
`/api/v1/openapi.json` from a running server, saving it at the path above
(JSON or YAML), and rebuilding so the plugin regenerates the client.
`OpenAPIContractTests` guards that the vendored document exists and still
covers `/api/v1/printer_profiles`, `/api/v1/colors`, and `bearerAuth`.

> README note: fold this section into the repo README when the generated
> client migration lands (the README is out of scope for the tests-only
> change that introduced this document).
