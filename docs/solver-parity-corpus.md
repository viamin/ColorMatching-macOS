# Solver parity corpus

`WeightedSquaredErrorScorer` (`ColorComposerCore/Sources/ColorComposerCore/CompositionScorer.swift`)
deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError` solver in
the [`color_matching`](https://github.com/viamin/color_matching) backend, so
the client and server agree on which palette color wins for a given target
and weights. That agreement is unenforced today beyond one doctest example
copied into `ScorerTests.swift`.

`color_matching` publishes a committed corpus of solver inputs and expected
selections, including tie cases, for clients to replay
([viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111)).
`SolverParityCorpusTests.swift`
(`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`)
loads that corpus and asserts `WeightedSquaredErrorScorer`'s selections match
it exactly, including which candidate wins a tie (earliest-wins, matching
`CompositionSolver.bestCandidate`).

## Where the corpus lives

Vendor the corpus as a single JSON file at:

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

Until that file is vendored, `SolverParityCorpusTests` fails with a message
naming the missing path and this document, rather than silently skipping.

## Schema

```json
{
  "version": 1,
  "cases": [
    {
      "name": "doctest_example",
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "target": { "white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5 },
      "candidates": [
        { "id": 1, "hex": "#808080", "responses": { "white": 0.5, "red": 0.1, "green": 0.4, "lps": 0.3 } }
      ],
      "expected_selected_id": 1,
      "tied_candidate_ids": []
    }
  ]
}
```

- `weights` / `target` / a candidate's `responses` are sparse maps keyed by
  the raw `LightingCondition` strings (`white`, `red`, `green`, `blue`,
  `lps`); an absent key means "no measurement for that condition", matching
  `PaletteColorDTO.toDomain()`'s decoding of the live API.
- `expected_selected_id` is the winning candidate's `id`, or `null` when
  every candidate is expected to be excluded (missing a required
  measurement for the target or for the candidate itself).
- `tied_candidate_ids` lists every candidate id that scores identically to
  the selection. Leave it empty for cases with no tie. When present, the
  test asserts those ids all score identically to the selection *and* that
  the lowest id among them is the one selected (earliest-wins).

## Refreshing the corpus

1. Pull the latest corpus artifact from
   [viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111).
2. Replace `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
   with the refreshed file (convert to the schema above if the upstream
   format differs).
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`
   and resolve any mismatches — a mismatch means the scorer has drifted from
   the server's `WeightedSquaredError`, which is a correctness bug, not a
   test to relax.
