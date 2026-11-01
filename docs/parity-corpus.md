# Solver parity corpus

`ColorComposerCore` deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError`
solver so the macOS client and the `color_matching` server always agree on which palette
color represents a target. Issue #39 makes that mirror enforceable: the server publishes a
parity corpus (viamin/color_matching#111) and this repository consumes it in tests.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json
```

It is a **byte-identical copy** of the upstream artifact:

- Source: `priv/parity/v1/corpus.json` in `viamin/color_matching`
  (<https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json>)
- `algorithm_version`: 1
- SHA-256 at commit time: `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`

## How it is consumed

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` decodes the
fixture and asserts parity at two levels:

| Test | Proves |
| --- | --- |
| `testCorpusIsPresentAndWellFormed` | fixture decodes, `algorithm_version` is 1, scorer is `ColorMatching.WeightedSquaredError`, selection policy is `earliest-index-wins`, all 12 named scenarios are present, indices are dense |
| `testScorerScoresMatchCorpusPerCandidate` | every candidate's `WeightedSquaredErrorScorer` score (or exclusion) matches the server's recorded score table exactly |
| `testSolverFastPathSelectionMatchesCorpus` | `CompositionSolver`'s production fast path selects the same color (id + hex) with the same error for every scenario, including the no-selection scenarios where all candidates are excluded |
| `testTieBreakingMatchesEarliestIndexWinsPolicy` | tie groups match `tied_indices` bit-for-bit (2-way, 3-way, duplicate-vector, and zero-weight ties) and the earliest index wins, exactly like `IlluminantMatching.best_match/4` |
| `testMissingMeasurementsAreExcludedNeverTreatedAsZero` | missing measurements on positive-weight channels exclude a candidate (never scored as brightness 0); zero-weight channels neither exclude nor contribute; a target missing a positive-weight channel excludes everything |
| `testUnknownLightSourceWeightKeysAreIgnored` | unknown weight keys (`ultraviolet`) are dropped and cannot change scores or selection |

The fixture is loaded relative to the test source file (`#filePath`), not through bundle
resources, so it works under both `swift test` and the Xcode project without a
`Package.swift` resource declaration.

## Corpus format (v1)

```jsonc
{
  "algorithm_version": 1,
  "light_sources": ["white", "red", "green", "blue", "lps"],
  "missing_policy": "excluded-when-any-positive-weight-channel-missing",
  "scorer": "ColorMatching.WeightedSquaredError",
  "selection": "earliest-index-wins",
  "scenarios": [
    {
      "id": "distinct-errors",
      "description": "…",
      "palette": [
        { "index": 0, "hex_color": "#A0522D", "channels": { "red": 0.5, /* absent key = unmeasured */ } }
      ],
      "target": { "index": null, "hex_color": "#336699", "channels": { … } },
      "weights": { "white": 0.5, "red": 1.0, "lps": 1.5, "ultraviolet": 3.0 },  // unknown keys ignored
      "expected": {
        "selected_index": 2,          // null when every candidate is excluded
        "selected_hex_color": "#708090",
        "error": 0.0234375,           // null when nothing is selected
        "scores": [ { "index": 0, "score": 0.23046875 }, { "index": 1, "score": "excluded" } ],
        "tie_broke": false,           // null when nothing is selected
        "tied_indices": [2]           // all candidates at the minimum score
      }
    }
  ]
}
```

Notes:

- `channels` maps light-source names to normalized brightness; an **absent** key means
  *unmeasured*, which is never the same as a measured `0.0`.
- `scores[].score` is a JSON number, or the string `"excluded"`.
- All brightness/weight values in v1 are exact binary fractions, so ties are bit-exact in
  IEEE-754 doubles and the tests compare scores at `1e-12`.
- One semantic boundary: the corpus's `missing-target-excluded` scenario (target missing a
  positive-weight channel) is asserted at **scorer** level only — the composition solver
  always receives a concrete brightness grid per active condition, so an absent target
  channel is not representable at the app layer.

## Refreshing the corpus

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

- If upstream bumps `algorithm_version`, `testCorpusIsPresentAndWellFormed` fails on
  purpose: re-review the parity semantics (exclusions, ties, weight handling) before
  accepting the new corpus.
- If scenarios are renamed upstream, update `requiredScenarioIDs` in
  `SolverParityCorpusTests.swift` alongside the fixture.
- Record the new SHA-256 in this file so the copy is traceable to its upstream commit.
