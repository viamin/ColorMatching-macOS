# Solver parity corpus

`ColorComposerCoreTests` consumes the versioned golden vectors published by
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
The committed copy lives at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json`.

The parity test replays every vector through `WeightedSquaredErrorScorer` and
`CompositionSolver` where a complete target is representable. It asserts
per-candidate scores, exclusion of missing positive-weight channels, selected
color/index/error, and earliest-index tie resolution exactly. A target missing
a required channel is asserted directly against the scorer because the solver
correctly rejects a missing source grid before it can build that target.

## Refreshing the fixture

1. Regenerate and commit the upstream corpus with `mix parity.generate` in
   `viamin/color_matching`.
2. Review its `algorithm_version`, scenarios, tie evidence, and missing-data
   policy. A semantic change requires an explicit app-side compatibility
   decision before updating this fixture.
3. Replace the committed fixture with the upstream file, then run
   `cd ColorComposerCore && swift test`.

For a byte-for-byte refresh after review:

```bash
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json
```

The fixture currently records `algorithm_version: 1` and the upstream policy
`excluded-when-any-positive-weight-channel-missing`.
