# Solver parity corpus

`ColorComposerCore` deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError`
solver in [`color_matching`](https://github.com/viamin/color_matching) so this app and the
server always agree on palette-color selection. The parity corpus makes that mirror
**enforced by tests** instead of asserted by comment.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

The corpus is committed data, not generated at test time. `SolverParityCorpusTests`
loads it (relative to the test file, so it works under `swift test` on macOS and Linux
without a bundle-resource declaration) and asserts for **every case**:

- the selection made through `CompositionSolver` on a 1×1 grid — the app's real
  selection path, including tie-breaking — matches `expected.selected_id` exactly;
- the winning error matches `expected.score` (tolerance 1e-9), both via the solver's
  recorded cell error and via `WeightedSquaredErrorScorer.score` directly;
- the exclusion set matches `expected.excluded_ids` exactly;
- a `selected_id` of `null` (every candidate excluded) leaves the cell unmatched with
  infinite error.

Additional suite invariants (`testCorpusIntegrity`, `testTieCases…`,
`testWeightEmphasisPairFlipsSelection`) keep the corpus itself a meaningful parity net:
schema version 1, unique case ids, ≥10 cases, coverage of ties / exclusions /
all-excluded, targets covering every weight > 0 channel, and a weight-flip case pair
that proves weights flow through scoring.

## Parity semantics pinned by the corpus

| Semantics | Case |
| --- | --- |
| Elixir doctest anchor (score 0.205) | `elixir_doctest_weights` |
| Ties resolve to the **earliest palette candidate** | `tie_symmetric_distance_earliest_wins`, `tie_identical_vectors_earliest_wins`, `tie_all_perfect_matches_earliest_wins` |
| Missing a weight > 0 channel **excludes** a candidate (never scored as zero) | `missing_required_measurement_excludes_candidate`, `five_channel_full_vector`, `elixir_doctest_weights` |
| Weight 0 channels are not required | `zero_weight_channel_is_not_required` |
| Weights scale channel error and can flip the winner | `weight_emphasis_white` / `weight_emphasis_red` |
| Measured `0.0` brightness is a real measurement, not missing | `measured_zero_brightness_is_not_missing` |
| All candidates excluded → no selection, infinite error | `all_candidates_excluded_no_selection` |

Channel summation order is the canonical `LightingCondition.all` order
(`white, red, green, blue, lps`), matching the Elixir scorer's channel fold.

## Schema

```jsonc
{
  "version": 1,                       // bump on breaking schema changes
  "scorer": "weighted_squared_error", // which solver the corpus targets
  "tie_break": "earliest_palette_candidate",
  "cases": [
    {
      "id": "unique_case_id",
      "description": "…",
      "tie": true,                     // optional: marks a deliberate tie case
      "weights":  { "white": 0.5, "red": 1.0 },   // absent keys = 0
      "target":   { "red": 0.2, "lps": 0.5 },     // per-channel brightness
      "palette": [
        { "id": 101, "hex": "#5A3C2E", "responses": { "red": 0.1 } }  // absent = unmeasured
      ],
      "expected": {
        "selected_id": 101,            // null when every candidate is excluded
        "score": 0.205,                // optional; winning weighted squared error
        "excluded_ids": [103]          // candidates excluded for missing required channels
      }
    }
  ]
}
```

Light-source keys are the `color_matching` wire strings (`white`, `red`, `green`,
`blue`, `lps`). Unknown keys fail the suite rather than being silently dropped.

## Refreshing the corpus

The committed file is a hand-seeded anchor corpus (case `elixir_doctest_weights`
reproduces the Elixir module doctest). Once the generated corpus from
[viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111) lands:

1. Download the generated `solver_parity_corpus.json` from that PR (or regenerate it
   upstream with the corpus export task).
2. Replace the fixture at
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
   in place — same schema (`version: 1`), same filename.
3. Run `cd ColorComposerCore && swift test`. Every case must pass unchanged:
   selection parity, tie resolution, exclusion sets, and scores.

If the upstream schema evolves, bump `version`, update the Codable models in
`SolverParityCorpusTests.swift` to match, and record any deltas (ties, exclusions,
weight handling) in the PR description.
