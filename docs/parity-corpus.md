# Solver parity corpus

`ColorComposerCore`'s default scorer, `WeightedSquaredErrorScorer`, deliberately
mirrors the Elixir `WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching) so the macOS client
and the server always agree on which palette color best matches a target
response vector. The server publishes a **parity corpus** — a versioned set of
selection cases with expected outcomes — and this repository enforces parity by
replaying every case through the Swift scorer and solver.

## Where the corpus lives

The corpus is vendored into this repository (a snapshot copy of the upstream
artifact, so parity tests run offline and are pinned to a reviewed upstream
revision). Resolution order used by the test loader
(`ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpus.swift`):

1. `$COLOR_MATCHING_PARITY_CORPUS` — explicit override (local experiments)
2. `color_matching/parity_corpus.json` — **primary documented location**
3. `color_matching/test/solver_parity_corpus.json`
4. `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json`
5. `parity_corpus.json` (repository root)

When no file is found, the parity test **fails** (it never silently passes).

Until the upstream corpus lands (viamin/color_matching#111) and is vendored,
`testVendoredCorpusSelectionParity` is the red flag tracking that gap. The
committed fixture snapshot (`ParityCorpusFixture.swift`, embedded in the test
target) already pins the corpus format and the tie/exclusion/weight semantics
independently of upstream.

## Corpus format (schema version 1)

```json
{
  "version": 1,
  "source": "viamin/color_matching@<commit> (#111)",
  "cases": [
    {
      "name": "exact_tie_breaks_to_earliest_candidate",
      "description": "optional human context",
      "weights": { "red": 1.0, "green": 1.0 },
      "palette": [
        { "id": 1, "name": "shadow", "hex": "#404040",
          "responses": { "red": 0.25 } }
      ],
      "target": { "red": 0.5, "green": 0.5 },
      "expected": {
        "selected_id": 1,
        "score": 0.0625,
        "tie_ids": [1, 2],
        "excluded_ids": [3]
      }
    }
  ]
}
```

- Light-source keys are the API's `light_source` strings: `white`, `red`,
  `green`, `blue`, `lps`. Unknown keys fail the loader (deliberately — an
  upstream vocabulary change must be reviewed, not ignored).
- A missing `responses` key means *unmeasured*, which is never the same as a
  measured `0.0`.
- `weights` entries `<= 0` are inactive: they do not require measurements and
  do not contribute to the score.
- `expected.selected_id` — the palette id that must be selected; `null` when
  every candidate is excluded (the cell stays unmatched).
- `expected.score` — the winner's `WeightedSquaredError` value (compared within
  `1e-9`).
- `expected.tie_ids` — **every** id achieving the minimum score; the selection
  must be the earliest of them in palette order (the shared
  `IlluminantMatching.best_match/4` earliest-wins policy).
- `expected.excluded_ids` — exactly the ids excluded for missing a measurement
  on a condition with weight `> 0`.

Tie cases should use exact binary fractions (`0.25`, `0.5`, `0.75`, …) so ties
are bit-exact in IEEE 754 doubles rather than accidental.

## How the tests consume it

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
runs every case two ways and requires both to agree with the corpus:

1. **Scorer level** — each candidate is scored by `WeightedSquaredErrorScorer`;
   the excluded set and the minimum-score tie set must match `expected` exactly.
2. **Solver level** — the case runs through the full `CompositionSolver` as a
   1×1 composition; the selected id, cell error, `excludedCandidateCount`, and
   unmatched-cell behavior must match.

## Refreshing the corpus

The corpus is a generated artifact from the upstream repo. To refresh:

```bash
# From the repository root — pin to the exact upstream revision you reviewed.
curl -fsSL \
  "https://raw.githubusercontent.com/viamin/color_matching/<commit>/test/solver_parity_corpus.json" \
  -o color_matching/parity_corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If the upstream schema differs from version 1 documented here, the loader fails
loudly with the offending case name — extend `ParityCorpus.swift` /
`PreparedParityCase.swift` in the same change and record the schema delta in
this document.

## Acceptance criteria mapping (issue #39)

| Criterion | Verification |
| --- | --- |
| Parity test target loads the committed corpus | `SolverParityCorpusTests.testVendoredCorpusSelectionParity` (unit test; red until the corpus is vendored) |
| Selections match expected outputs exactly, including ties | same test + `testFixtureCorpusSelectionParity` (tie sets, earliest-wins, scores, exclusions) |
| Corpus consumption documented | this document |
