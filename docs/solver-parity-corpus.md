# Solver parity corpus

`ColorComposerCore`'s `WeightedSquaredErrorScorer` deliberately mirrors the
Elixir `ColorMatching.WeightedSquaredError` solver in the
[`color_matching`](https://github.com/viamin/color_matching) backend. The
**parity corpus** is the committed set of golden cases that keeps the two
implementations provably in agreement: every case records a palette, channel
weights, target vectors, and the exact selection the server's solver makes.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

The corpus is committed with the tests and loaded from disk by
`SolverParityCorpusTests` (no bundle resources required). It is the seed copy
of the upstream corpus published by
[viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111);
`schema_version` guards the wire format.

## Schema (version 1)

```jsonc
{
  "schema_version": 1,
  "source": { /* upstream provenance: repo, corpus PR, solver names */ },
  "cases": [
    {
      "id": "tie-at-nonzero-score-earliest-wins",   // unique, descriptive
      "description": "...",
      "weights": { "white": 0, "red": 1, "green": 1, "blue": 0, "lps": 0 },
      "palette": [                                   // ORDERED: ties break to the earliest entry
        { "id": 501, "hex": "#1abc9c", "responses": { "red": 0.5, "green": 0.9 } }
      ],
      "targets": [ { "red": 0.7, "green": 0.7 } ],   // one per expected output cell
      "expected_selections": [501],                  // palette ids; null = unmatched cell
      "expected_scores": [0.08],                     // weighted squared error; null = infinite
      "expected_excluded_count": 0                   // candidates missing a required measurement
    }
  ]
}
```

Semantics the corpus encodes (and the tests enforce):

- **Weights** — keys are the `light_source` strings (`white`, `red`, `green`,
  `blue`, `lps`); absent or `0` means the channel is inactive and ignored.
  Fractional weights are valid.
- **Ties** — two candidates with equal minimum score: the *earliest* palette
  entry wins, matching the Elixir solver's enumeration order.
- **Exclusions** — a candidate missing a measurement for any weight > 0
  condition is excluded, never treated as zero brightness. A *measured zero*
  (`"green": 0.0`) is a real measurement and participates.
- **Unmatched cells** — when every candidate is excluded, the expected
  selection and score are `null` and the solver records infinite error.

## How the tests consume it

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
asserts, for every case and target:

1. scorer-level selection: the earliest-wins argmin of
   `WeightedSquaredErrorScorer.score` equals `expected_selections`, with the
   expected score;
2. solver-level selection: `CompositionSolver`'s production fast path picks
   the same palette color, records the same per-cell error, the same
   `excludedCandidateCount`, and the same unmatched-cell count; and
3. corpus hygiene: the corpus still covers ties, exclusions, all-excluded
   targets, zero-weight channels, and fractional weights, so a refresh that
   drops coverage fails loudly.

Run them with:

```bash
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

## Refreshing the corpus

When the upstream corpus from
[viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111)
changes (new cases, regenerated expectations after a server solver change):

```bash
# From a color_matching checkout at the ref that produced the artifact:
mix solver.parity_corpus > /tmp/solver_parity_corpus.json   # or the documented export task

# Review the diff, then update the committed copy:
cp /tmp/solver_parity_corpus.json \
   ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Record the upstream commit/tag in `source` when refreshing. **A refresh that
makes parity fail is a finding, not a reason to edit expectations by hand**:
either the client scorer has drifted (fix the client) or the server solver
changed semantics (escalate in the color_matching repo).

The exact upstream export command is defined by viamin/color_matching#111;
until that PR ships its artifact, the committed file is the seed corpus and
this section names the canonical refresh path.
