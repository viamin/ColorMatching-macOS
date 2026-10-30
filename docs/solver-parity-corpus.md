# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching) so the macOS
client and the server always agree on which palette color a target selects.
This document describes the committed parity corpus that enforces that mirror,
its schema, and how to refresh it.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/weighted_squared_error_v1.json
```

One JSON file, `corpus_version: 1`, generated from the reference solver. When
an updated corpus is published by `color_matching`
([viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111)),
replace this file wholesale; do not hand-edit expected values.

## What the tests enforce

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
loads the corpus and asserts, for every case:

- **Selection** — the lowest weighted squared error wins, computed over
  channels with weight `> 0` only.
- **Ties** — equal scores resolve to the *earliest palette index*
  (`min_score_earliest_index_wins`, matching the Elixir
  `IlluminantMatching.best_match/4` policy). Tie cases appear twice with the
  palette order reversed to pin the order-dependence.
- **Exclusions** — a candidate (or target) missing a measurement for any
  required channel is *excluded*, never treated as zero brightness. Cases
  cover candidate-side missing measurements, target-side missing channels,
  and all-candidates-excluded (no selection at all).
- **Weight handling** — weight `0` channels neither require a measurement nor
  contribute to the score; heavy weights can flip a selection.
- **Solver agreement** — `CompositionSolver` (the shipped solve path) produces
  the same selection, error, and exclusion count on a 1×1 composition.

A meta-test also verifies the corpus still covers the required scenario
categories (`tie`, `exclusion`, `no_selection`, `zero_weight`, …) so a refresh
cannot silently shrink parity coverage.

## Corpus schema (`corpus_version` 1)

```json
{
  "corpus_version": 1,
  "source": "…",
  "algorithm": "weighted_squared_error",
  "selection_policy": "min_score_earliest_index_wins",
  "cases": [
    {
      "id": "unique_case_id",
      "description": "what behavior this case pins",
      "tags": ["tie"],
      "weights": { "white": 0.5, "red": 1.0 },
      "target": { "red": 0.5, "green": 0.5 },
      "palette": [
        { "id": 501, "name": "Below Target", "hex": "#7A3B2E",
          "responses": { "red": 0.4 } }
      ],
      "expected": {
        "selected_index": 0,
        "selected_id": 501,
        "score": 0.01,
        "excluded_indices": [],
        "tied_indices": [0, 1]
      }
    }
  ]
}
```

Field rules:

| Field | Meaning |
| --- | --- |
| `weights` | Per-channel weights; omitted keys are `0`. Channels with weight `> 0` are *required*. |
| `target` | Target brightness vector; an omitted key means *no measurement* (never zero). |
| `palette[].responses` | Measured brightness per light source; an omitted key means *unmeasured*. |
| `expected.selected_index` / `selected_id` | `null` when every candidate is excluded (no selection). |
| `expected.score` | Winner's weighted squared error (`null`/omitted → score not asserted). |
| `expected.excluded_indices` | Candidate indices that must report `.excluded`. |
| `expected.tied_indices` | Indices scoring bit-equal to the minimum (tie cases). |

Channel keys are the canonical `LightingCondition` raw values: `white`, `red`,
`green`, `blue`, `lps`. Any other key fails the loader.

## Refreshing the corpus

1. Regenerate (or copy) the corpus from the `color_matching` parity corpus
   output ([#111](https://github.com/viamin/color_matching/pull/111)) into
   the fixture path above.
2. If the generator bumps `corpus_version`, update the Swift loader and this
   document in the same change; the version assertion in
   `testCorpusDeclaresExpectedAlgorithmAndPolicy` is the guard.
3. Run `cd ColorComposerCore && swift test` — the parity target must be green.
   A red parity test means client and server solvers disagree; investigate the
   semantic difference (ties, exclusions, weight handling) before touching any
   expected value.

### Note on the initial corpus

The upstream generator (#111) is not reachable from every development
environment. The corpus committed with this change was authored from the
documented Elixir semantics (the `WeightedSquaredError` doctest, exclusion and
zero-weight rules in the `color_matching` README and this package's
`CompositionScorer` documentation). Once #111 publishes generated corpora,
replace the fixture with the generated file — the loader, schema, and tests in
this package are already shaped for it.
