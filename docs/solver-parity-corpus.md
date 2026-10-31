# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir `WeightedSquaredError`
solver in [`color_matching`](https://github.com/viamin/color_matching) so the
macOS client and the server agree on palette-color selection. The **solver
parity corpus** is the executable proof: a committed JSON file of fixed inputs
(palette, target vector, channel weights) and expected outputs (selected
candidate, score, exclusions) that the Swift tests replay exactly.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

It is consumed by `SolverParityCorpusTests.swift` in the `ColorComposerCoreTests`
target. The loader reads the fixture from the source tree (via `#filePath`), so
no resource declarations are required.

Run the parity suite:

```bash
cd ColorComposerCore && swift test --filter SolverParityCorpus
```

## What the tests enforce

For every corpus case, both selection layers must match the expected output:

1. **Scorer level** — `WeightedSquaredErrorScorer` under lowest-score /
   earliest-wins selection.
2. **Production solver level** — `CompositionSolver` (the contiguous fast path
   used by the app) solving a 1×1 composition built from the case target:
   same selected palette index, same per-cell error, same excluded-candidate
   count.

The corpus semantics (mirroring `WeightedSquaredError` /
`IlluminantMatching.best_match/4`):

- Score = Σ over channels with weight > 0 of `weight × (candidate − target)²`,
  accumulated in canonical channel order: `white, red, green, blue, lps`.
- A candidate (or the target) **missing a measurement** for any channel with
  weight > 0 is **excluded** — missing is never treated as zero brightness.
- Channels with weight 0 are ignored entirely: they neither contribute to the
  score nor cause exclusion.
- **Ties select the earliest candidate** in palette order (deterministic).
- `expected_selection: null` means every candidate is excluded and the cell
  stays unmatched (infinite error).

## Corpus format

```json
{
  "meta": {
    "format": "color_matching.solver_parity_corpus/1",
    "upstream": "viamin/color_matching#111",
    "origin": "…",
    "notes": "…"
  },
  "cases": [
    {
      "id": "tie_identical_vectors_earliest_wins",
      "description": "…",
      "tie": true,
      "weights": { "white": 0, "red": 1, "green": 1, "blue": 0, "lps": 0 },
      "target": { "red": 0.5, "green": 0.5 },
      "candidates": [
        { "name": "Twin A", "hex": "#808080", "responses": { "red": 0.5, "green": 0.5 } }
      ],
      "expected_selection": 0,
      "expected_selected_name": "Twin A",
      "expected_score": 0.0,
      "expected_excluded": []
    }
  ]
}
```

Field notes:

- All five `weights` keys are required (they decode into `ChannelWeights`).
- `target` / `responses` keys must be canonical lighting conditions
  (`white`, `red`, `green`, `blue`, `lps`); any other key fails the test run —
  a typo'd condition must never silently drop a measurement.
- `tie` flags cases whose purpose is exact-tie coverage (the integrity test
  requires at least one tie case, one exclusion case, one all-excluded case,
  and one case that weights all five channels).
- `expected_score` is asserted with `1e-9` accuracy; `expected_selection` is
  asserted exactly.
- Candidate `hex` values must be parseable (`#rrggbb`).

## Refreshing the corpus

The committed file is currently a **seed corpus**: its expected values are
hand-derived from the Elixir `WeightedSquaredError` semantics documented in the
README (including the `0.205` doctest vector mirrored by `ScorerTests`). The
canonical corpus is exported by the `color_matching` server
(viamin/color_matching#111):

1. Export the parity corpus from a `color_matching` checkout at or beyond the
   corpus release (see that PR for the export task/endpoint).
2. Replace `Fixtures/solver_parity_corpus.json` with the exported file, keeping
   the `color_matching.solver_parity_corpus/1` format above (the server export
   is the source of truth for the format; extend the loader if the export adds
   fields).
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpus` — every
   case must pass. A failure means client/server solver drift: fix the Swift
   side (or, if the server changed semantics intentionally, update the corpus
   in the same server PR that changed the solver).

> Note for issue #39: this document is the source for the README
> "Solver parity corpus" section; fold it into the README when touching it
> alongside the generated-client migration.
