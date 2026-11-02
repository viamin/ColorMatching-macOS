# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError` solver in [`color_matching`](https://github.com/viamin/color_matching). The parity corpus is the executable proof: every case pins the exact palette-color selection (and score) the Swift solver must produce, so the two implementations cannot drift apart silently.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

It is consumed by `SolverParityCorpusTests` (same directory), which runs each case through `CompositionSolver` with the default `WeightedSquaredErrorScorer` and asserts:

- **Selections match exactly** — the selected palette color id per cell, `null` when every candidate is excluded.
- **Tie cases** — equal scores resolve to the earliest candidate in palette order (the Elixir `IlluminantMatching.best_match/4` policy). Strict `<` comparison, so a strictly better candidate always displaces an earlier one.
- **Exclusions** — a candidate missing a measurement for any *active* channel (weight > 0) is excluded, never treated as zero brightness; `expected_excluded_count` pins how many.
- **Measured zero ≠ missing** — a recorded `0.0` brightness is a real value and stays eligible.
- **Zero-weight channels** — inactive channels neither exclude nor contribute to the score.
- **Weight handling** — per-channel weights scale each squared difference; cases where weighting flips the selection pin this.
- **Scores** — when `expected_scores` is present, the winning candidate's weighted squared error must match within `1e-9`.

## Corpus schema (version 1)

```json
{
  "schema": 1,
  "algorithm": "ColorMatching.WeightedSquaredError",
  "source": { "repo": "viamin/color_matching", "pull": 111, "note": "..." },
  "cases": [
    {
      "id": "unique-case-id",
      "description": "...",
      "tags": ["tie", "exclusion", "zero-weight", "measured-zero", "weights"],
      "weights": { "white": 0.5, "red": 1.0 },
      "palette": [
        { "id": 101, "name": "…", "hex": "#C64A35", "rgb": { "r": 198, "g": 74, "b": 53 },
          "responses": { "red": { "brightness": 0.87 } } }
      ],
      "width": 2,
      "targets": [ { "red": 0.5, "green": 0.5, "lps": 0.3 } ],
      "expected_selections": [101, null],
      "expected_scores": [0.205, null],
      "expected_excluded_count": 1
    }
  ]
}
```

- `weights` keys must be canonical condition names (`white`, `red`, `green`, `blue`, `lps`); absent keys mean weight 0.
- `targets` is a flat row-major list of one target vector per cell; `width` defaults to the target count (a single row).
- `rgb` is optional; when absent the loader falls back to `hex`.
- `expected_scores` and `expected_excluded_count` are optional.

## Provenance and refreshing

The committed file is a **seed corpus** derived from the published Elixir `WeightedSquaredError` semantics (including the module doctest, whose canonical case expects score `0.205` with weights `white 0.5, red 1.0, green 1.0, blue 0.0, lps 1.5`). The upstream corpus from [viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111) was not reachable when this seed was created.

To refresh once #111 merges:

```bash
cp <path-to-upstream-corpus>/weighted_squared_error_corpus.json \
   ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If the upstream file's field names differ from schema version 1, extend the loader's `CodingKeys` in `SolverParityCorpusTests.swift` — do not hand-edit expected selections.

## Parity findings (current corpus)

- Ties: earliest candidate wins on both platforms (Swift strict `<`, Elixir `best_match` order scan).
- Exclusions: any active-channel missing measurement excludes a candidate on both platforms; unmatched cells record infinite error.
- Measured `0.0` is a legitimate brightness, distinct from an absent measurement.
- Zero-weight channels are ignored entirely — neither exclusion nor contribution.
- Weights multiply per-channel squared differences (not absolutes, not max), and can flip selections versus unweighted matching.
