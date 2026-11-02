# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching) so the client and
the server agree on color selection. The **parity corpus** published by
viamin/color_matching#111 pins that mirror with expected selections, including
tie and exclusion cases. This app consumes the corpus as a committed test
fixture (issue #39).

## Where the corpus lives

The corpus is committed at:

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json
```

A second file, `parity_corpus.seed.json`, is **not** a parity source. It is a
hand-derived seed (it includes the Elixir `WeightedSquaredError` doctest case)
that validates the test harness itself — loader, selection-policy replication,
tie and exclusion handling — before the upstream corpus lands.

## How it is consumed

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
loads the committed corpus and, for every case:

1. Rebuilds `ChannelWeights`, the `TargetResponseVector`, and each candidate
   `PaletteColor` from the case JSON.
2. Scores every candidate with `WeightedSquaredErrorScorer`.
3. Applies the solver's selection policy — lowest score wins, **earliest
   candidate wins ties**, excluded candidates are skipped — exactly as
   `CompositionSolver.bestCandidate` does.
4. Asserts the selected candidate id, the excluded id set, and (when present)
   the winning score match the corpus expectations.

The test additionally enforces corpus coverage: at least one tie case and at
least one exclusion case must be present, so tie-breaking and the
missing-measurement policy are always exercised.

Run it with:

```bash
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

## Schema

JSON with snake_case keys (`version` must be `1`):

```json
{
  "version": 1,
  "source": "viamin/color_matching#111",
  "cases": [
    {
      "name": "tie resolves to earliest candidate",
      "weights": {"green": 1.0},
      "target": {"green": 0.5},
      "candidates": [
        {"id": 11, "hex": "#99f299", "responses": {"green": 0.6}},
        {"id": 12, "hex": "#669966", "responses": {"green": 0.4}}
      ],
      "expected_selection": 11,
      "expected_score": 0.01,
      "expected_excluded_ids": []
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `weights` | Per-light-source weights keyed by `white`/`red`/`green`/`blue`/`lps`. Weight `0` (or absent) channels are ignored; weight `> 0` channels are **required**. |
| `target` | Target brightness per light source. A required channel missing here excludes *every* candidate. |
| `candidates` | Ordered candidate colors; order defines tie-breaking (earliest wins). `hex` is optional (defaults to `#000000`). `responses` maps light sources to brightness; unknown light sources are a corpus error. |
| `expected_selection` | Candidate id the solver must select, or `null` when every candidate is excluded. |
| `expected_score` | Optional winning score, compared at tolerance `1e-9`. |
| `expected_excluded_ids` | Optional ids that must score `.excluded` (candidate or target missing a required-channel measurement). |

## Refreshing the corpus

The corpus originates in the `color_matching` repository (parity corpus from
viamin/color_matching#111). This repo pins that repository as the
`color_matching` gitlink at the repo root. To refresh the fixture:

```bash
# From an up-to-date color_matching checkout (the pinned gitlink, or a clone
# of https://github.com/viamin/color_matching after #111 merges):
cp <path-to-corpus-artifact-in-color_matching> \
   ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If a refreshed corpus changes selection outcomes, that is a parity break
between `WeightedSquaredErrorScorer` and the Elixir solver — investigate before
adapting either side. If the upstream artifact format differs from the schema
above, adapt the fixture (or the loader in `SolverParityCorpusTests`) so the
committed file stays self-describing, and record the conversion in the PR.
