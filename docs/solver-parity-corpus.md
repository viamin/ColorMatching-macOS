# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver, and selection mirrors
`ColorMatching.IlluminantMatching.best_match/4` (lowest score wins, ties go
to the earliest index). The parity corpus is the shared golden-vector source
of truth that keeps the two implementations from silently diverging.

## Where the corpus lives

- **Source of truth (server):** [`viamin/color_matching`][server-repo]
  `priv/parity/v1/corpus.json` — generated deterministically by the server's
  `mix parity.generate` task (upstream CI verifies the committed bytes with
  `mix parity.generate --check`). See
  `lib/color_matching/parity/corpus.ex` there for the format.
- **Committed copy (this repo):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
  — a byte-for-byte copy of the server fixture.
- **Replay test:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
  runs on `swift test` (see `bin/lint`).

## How to refresh the fixture

The corpus is deterministic for a given `algorithm_version`, so refreshing is
a byte-identical copy unless semantics changed upstream:

```bash
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

Pin to a tag or commit SHA instead of `main` when you want a reproducible
snapshot. Alternatively, in a local checkout of the server repo:

```bash
mix parity.generate   # rewrites priv/parity/v1/corpus.json
```

Then copy the file to the fixture path above and run `swift test`.

**If `algorithm_version` changed** (the top-level JSON field), the server's
scoring/selection semantics changed; do not refresh blindly. Diff the corpus,
re-validate the parity replay, and only then update the fixture and the
pinned version in `SolverParityCorpusTests.testCorpusMetadataMatchesSupportedContract`.
The current corpus version is `1`, selection is `earliest-index-wins`, and the
missing-measurement policy is
`excluded-when-any-positive-weight-channel-missing`.

## What the replay asserts

For all 12 corpus scenarios:

- every candidate's score matches **exactly** (`"excluded"` or the identical
  `Double`, compared with zero tolerance — corpus values are exact dyadic
  fractions),
- missing measurements on a positive-weight channel exclude (candidate *or*
  target), while missing/unknown channels on zero-or-absent weights neither
  exclude nor contribute,
- the selected index, hex color, winning error, `tie_broke` flag, and
  `tied_indices` all match, and
- the production `CompositionSolver` fast path picks the same winner for a
  single-cell composition with the same error and excluded-candidate count
  (skipped only for the `missing-target-excluded` scenario, whose
  missing-target vector cannot be expressed as solver source grids — grids
  always exist for active conditions).

## Related: OpenAPI document for the generated client

The server publishes its OpenAPI 3 spec at `GET /api/v1/openapi.json`
(viamin/color_matching#110, merged as PR #113 there). Issue #39 adopts
`swift-openapi-generator` + `swift-openapi-runtime` in `ColorComposerCore`
with a committed snapshot of that document;
`GeneratedClientAdoptionTests` guards those structural requirements, while
`PaletteAPIClientTests` pins the observable wire behavior (URLs, headers,
envelope decoding, error mapping) that the migration must preserve.

[server-repo]: https://github.com/viamin/color_matching
