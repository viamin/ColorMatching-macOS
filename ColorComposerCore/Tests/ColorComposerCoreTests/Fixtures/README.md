# Solver parity corpus fixture

`solver_parity_corpus.json` belongs in this directory. It is **not vendored
yet** — it ships from `viamin/color_matching#111`, which issue #39
(ColorMatching-macOS) depends on and which had not merged as of this writing.

`SolverParityCorpusTests.swift` (the parent directory) loads this file and
asserts `WeightedSquaredErrorScorer` reproduces the Elixir
`ColorMatching.WeightedSquaredError` solver's recorded selections exactly,
including tie cases and exclusions. Until the file is added here, that test
fails with a message pointing back to this README.

## Expected schema

A JSON array of cases:

```json
[
  {
    "name": "elixir doctest example",
    "weights": {"white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5},
    "target": {"white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5},
    "candidates": [
      {"id": 1, "responses": {"white": 0.5, "red": 0.1, "green": 0.4, "blue": 0.0, "lps": 0.3}},
      {"id": 2, "responses": {"white": 0.1, "red": 0.9}}
    ],
    "expected_winner_id": 1,
    "expected_tied_ids": null,
    "expected_excluded_ids": null
  }
]
```

- `expected_winner_id` — the candidate id the scorer must select; `null` when
  every candidate is excluded.
- `expected_tied_ids` — every candidate id achieving the minimum score, for
  cases that specifically exercise tie-breaking.
- `expected_excluded_ids` — candidate ids expected to score `.excluded`
  (missing a measurement for a channel with weight `> 0`).

This schema is this app's best-effort anticipation of what `color_matching`
will publish, reverse-engineered from `WeightedSquaredErrorScorer`'s own
contract (see `CompositionScorer.swift`). When the real corpus lands, reconcile
field names against it — the decode step in `SolverParityCorpusTests.swift`
is the only place that should need to change.

## Refreshing

Once `color_matching#111` merges, pull the published corpus file from that
repository and commit it here as `solver_parity_corpus.json`. Re-run
`swift test --filter SolverParityCorpusTests` after any upstream solver
change and update the committed copy if the corpus is republished.
