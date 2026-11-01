# Solver parity corpus

`WeightedSquaredErrorScorer` in `ColorComposerCore` deliberately mirrors the
Elixir `ColorMatching.WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching). The parity corpus
is the shared source of truth that keeps the two implementations from drifting
apart — silently diverging tie-breaking, missing-measurement exclusion, or
channel weighting is caught by replaying the corpus on both sides.

## Where the corpus lives

The corpus consumed by this repository is committed as test data:

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

It is a byte-for-byte copy of `priv/parity/v1/corpus.json` from the
`color_matching` server (see [viamin/color_matching#111]). The upstream file is
deterministic: `mix parity.generate` always produces identical bytes, and the
server's CI verifies the committed bytes with `mix parity.generate --check`.

`v1` tracks the corpus `algorithm_version` field. When the server bumps that
version, the expectations describe new scoring semantics and the fixture must
be refreshed (and the Swift scorer reviewed) together.

## How the tests consume it

`SolverParityCorpusTests` (in `ColorComposerCoreTests`) loads the fixture and,
for every scenario:

- asserts the corpus declares the mirrored semantics — scorer
  `ColorMatching.WeightedSquaredError`, selection `earliest-index-wins`,
  missing policy `excluded-when-any-positive-weight-channel-missing`,
  `algorithm_version` 1, and the same light-source list (and order) as
  `LightingCondition`;
- replays every candidate through `WeightedSquaredErrorScorer` and compares
  each per-candidate score with the corpus **exactly** — `excluded` results
  included (the corpus numbers are exact binary fractions, so exact `Double`
  equality is meaningful);
- recomputes the earliest-index-wins selection, best error, tie membership,
  and `tie_broke` flag, and compares them with the corpus expectations;
- runs the same scenario through `CompositionSolver` (single-cell source
  grids, default scorer fast path) so the shipped selection path — not just
  the score function — matches the corpus;
- guards corpus coverage: the fixture must keep at least one scenario per
  behavior class (ties, three-way ties, missing-candidate exclusion,
  missing-target exclusion, all-excluded, zero-weight channels, unknown weight
  keys, exact matches) so a refresh cannot silently narrow parity.

Scenarios whose target vector is itself missing a positive-weight channel
cannot be expressed as solver source grids (the solver rejects the grid set by
design); those scenarios are asserted at the scorer level only.

## Refreshing the corpus

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Verify `algorithm_version` did not change before committing the refresh; if it
did, treat it as a solver-semantics change, not a data refresh. The corpus
format is part of the contract and is decoded by the test target — after any
upstream format change, update the decoding structs in
`SolverParityCorpusTests.swift` in the same commit.

## OpenAPI document

The `/api/v1` OpenAPI document (see [viamin/color_matching#110]) is served by
the server at `GET /api/v1/openapi.json`. The generated-client adoption
expects it committed at the canonical `swift-openapi-generator` input location:

```
ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json
```

Refresh it from a running server with:

```bash
curl -fsSL http://localhost:4000/api/v1/openapi.json \
  -o ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json
```

`GeneratedClientAdoptionTests` pins the document's presence, its coverage of
`GET /api/v1/printer_profiles` and `GET /api/v1/colors`, and the `bearerAuth`
security scheme; `PaletteAPIClientBehaviorTests` pins the client behavior
(URLs, `printer_profile_id` query, trimmed bearer token, 401/5xx/error
mapping, snake_case decoding) that the generated-client migration must keep
identical.

[viamin/color_matching#110]: https://github.com/viamin/color_matching/pull/110
[viamin/color_matching#111]: https://github.com/viamin/color_matching/pull/111
