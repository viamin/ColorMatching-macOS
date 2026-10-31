# Solver parity corpus

`WeightedSquaredErrorScorer` in `ColorComposerCore` deliberately mirrors the
Elixir `WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching): given the same
palette, channel weights, and target vector, both must pick the same color.
The parity corpus (published by
[viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111))
is the executable proof. It is consumed by
`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`,
which loads the corpus and asserts — for every case, ties included — that:

- the **selected palette entry** (lowest weighted squared error) matches
  `expected.selection_index` exactly, with earliest-entry-wins tie-breaking,
- the **score** matches `expected.score` within `1e-9`,
- the **tie flag** matches (more than one candidate achieves the best score),
- the **excluded-candidate count** matches (a candidate missing a measurement
  for any channel with weight `> 0` is excluded — missing is never zero
  brightness), and
- replaying the case through `CompositionSolver` on a 1×1 grid selects the
  same entry (the full pipeline, not just the scorer, stays in parity).

## Where the corpus lives

The test looks for the corpus in this order, loading the first that exists:

1. `$PARITY_CORPUS_PATH` — explicit override, e.g. a freshly exported corpus
   under review.
2. `color_matching/priv/solver_parity_corpus.json` — the canonical copy when
   the server repository is checked out next to this repo (the upstream
   location from viamin/color_matching#111).
3. `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`
   — the corpus vendored into this repository so `swift test` enforces parity
   without the server checkout.

## Refreshing the corpus

When upstream publishes a new corpus (new cases, new measurements):

```bash
# from a checkout of viamin/color_matching containing #111
cp color_matching/priv/solver_parity_corpus.json \
   ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json

cd ColorComposerCore && swift test
```

The corpus tests double as coverage guards: they fail if the refreshed file
loses its tie cases, exclusion cases, all-excluded case, zero-weight-channel
case, or the same-palette/same-target pair whose weights flip the selection.

## Corpus format

JSON, snake_case, schema version 1:

```json
{
  "version": 1,
  "source": "…",
  "cases": [
    {
      "id": "tie-identical-responses-earliest-wins",
      "description": "…",
      "palette": [
        { "id": 41, "name": "Ink A", "hex": "#0a0a0a",
          "responses": { "red": 0.5 } }
      ],
      "weights": { "red": 1.0 },
      "target": { "red": 0.5 },
      "expected": {
        "selection_index": 0,
        "score": 0.0,
        "tie": true,
        "excluded_candidates": 0
      }
    }
  ]
}
```

- Channel keys are the canonical `light_source` strings: `white`, `red`,
  `green`, `blue`, `lps`. Unknown keys fail the test rather than being ignored.
- `palette` order is significant: `selection_index` refers to it, and ties
  resolve to the earliest entry.
- `weights` keys with value `0` (or absent channels) are neither required nor
  scored.
- `selection_index` is `null` when every candidate is excluded; the cell then
  stays unmatched. `score` is `null` in that case too.

## See also

- `CompositionScorer.swift` — the scorer under test and its exclusion policy.
- `CompositionSolver.swift` — earliest-wins tie-breaking (`best_match/4`
  parity).
- `PaletteAPIClientContractTests.swift` — the `/api/v1` wire contract the
  generated OpenAPI client migration (viamin/color_matching#110) must keep.
