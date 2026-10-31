# Solver parity corpus

`ColorComposerCore` must select the same palette color as the Elixir
`color_matching` service for identical inputs. The solver-parity corpus is the
executable proof: a JSON document of cases exported from the Elixir solver
(`WeightedSquaredError` scoring + `IlluminantMatching.best_match/4` selection,
viamin/color_matching#111) and committed in this repository, consumed by
`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

The test resolves the file relative to `#filePath`, so no SwiftPM resource
declaration is required. (The implementation run of #39 may additionally
declare it as a `.copy`/`.process` resource in `Package.swift`; the lookup
keeps working either way.)

## Format

```json
{
  "version": 1,
  "source": "viamin/color_matching@<rev> parity corpus export",
  "cases": [
    {
      "id": "doctest",
      "description": "optional human note",
      "palette": [
        {"id": 1, "hex": "#51140F", "responses": {"white": 0.5, "red": 0.1, "green": 0.4, "lps": 0.3}}
      ],
      "target":  {"white": 0.8, "red": 0.2, "green": 0.7, "lps": 0.5},
      "weights": {"white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5},
      "expected_selected_id": 1,
      "expected_score": 0.205,
      "tie_candidate_ids": [1, 4],
      "excluded_candidate_ids": [3]
    }
  ]
}
```

Rules:

- Light-source keys are the canonical API strings: `white`, `red`, `green`,
  `blue`, `lps`. Unknown keys fail the test (format drift is a bug).
- `palette[i].responses` holds the measured brightness (`0...1`) per
  condition; a missing key is an unmeasured condition, never zero.
- `weights` maps to the user channel weights; weight `0` makes the channel
  inert (not required).
- `target` must cover every condition with weight `> 0`.
- `expected_selected_id` is the Elixir `best_match` selection, or `null` when
  every candidate is excluded.
- `expected_score` (optional) is the Elixir `WeightedSquaredError` score of
  the winner.
- `tie_candidate_ids` (optional) lists every candidate achieving the minimum
  score. The client must resolve the tie to the **earliest candidate in
  palette order** — the `IlluminantMatching.best_match/4` policy.
- `excluded_candidate_ids` (optional) lists candidates excluded for missing a
  measurement on a weighted channel.

## What is asserted

Per case, at scorer level (`WeightedSquaredErrorScorer`) and solver level
(`CompositionSolver`, the default fast path):

1. the selected palette color id equals `expected_selected_id` exactly;
2. the winning score equals `expected_score` (tolerance `1e-9`);
3. tie cases select the earliest palette-order member of `tie_candidate_ids`;
4. exactly `excluded_candidate_ids` come back `.excluded`;
5. `null` selections leave the cell unmatched (no eligible candidate).

The harness itself is self-checked by
`testHarnessVerifiesTheDocumentedReferenceCase`, which runs a reference case
(the Elixir doctest vector, expected score `0.205`) through the identical
verification path.

## Refreshing the corpus

1. Export the corpus from `color_matching` once viamin/color_matching#111
   lands (upstream mix task / script; recorded here when it exists):
   ```bash
   ./priv/scripts/export_solver_parity_corpus > solver_parity_corpus.json  # upstream command TBD
   ```
2. Validate the export against the format above (`version`, canonical
   light-source keys, every active target condition present).
3. Copy it to
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
   and update the `source` field to the upstream commit it was exported from.
4. Run the parity suite:
   ```bash
   cd ColorComposerCore && swift test --filter SolverParityCorpus
   ```

A red `testCorpusIsCommittedAtTheCanonicalLocation` means the corpus file is
missing from the checkout; a red case assertion means the Swift and Elixir
solvers have diverged — fix before merging.

> README note: link this document from `README.md` ("Solver parity corpus")
> in the implementation run of #39; the tests-only phase cannot edit files
> outside test paths and the documentation allowlist.
