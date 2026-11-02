# Solver parity corpus

`ColorComposerCore` deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError`
solver so the macOS client and the `color_matching` server agree on color selection.
The parity corpus is a committed set of scored selection cases that the Swift
`WeightedSquaredErrorScorer` must reproduce **exactly** — including tie cases and
exclusions.

## Where the corpus lives

- **Corpus (data):** `ColorComposerCore/Tests/Fixtures/solver_parity_corpus.json`
- **Harness (tests):** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`

The fixture sits outside the test *target* directory on purpose: SwiftPM treats
non-Swift files inside a target directory as an error unless the manifest declares
them as resources, and keeping the fixture target-free means no `Package.swift`
rule is needed to load it (the harness locates it relative to `#filePath`).

The current fixture is a **hand-authored stand-in** written directly against the
documented solver semantics (the Elixir doctest, the earliest-wins tie rule, and
the missing-channel exclusion rule). Upstream will publish the canonical corpus
via [viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111);
when it lands, replace the fixture with it (see *Refreshing* below).

## Corpus schema (version 1)

```jsonc
{
  "version": 1,
  "source": "provenance note",
  "cases": [
    {
      "id": "unique-case-id",              // used in failure messages
      "description": "what the case proves",
      "covers": ["tie", "exclusion", ...], // coverage tags (see below)
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "target": { "red": 0.2, "green": 0.7 },          // absent key = no measurement
      "candidates": [
        { "id": 101, "hex": "#C64A35", "responses": { "red": 0.1 } }
      ],
      "expected": { "selected_id": 101, "score": 0.205 }
    }
  ]
}
```

Rules the harness enforces:

- Absent keys mean *no measurement* — never zero. Candidate ids must be unique
  within a case so `selected_id` is unambiguous; `rgb` is omitted because
  scoring never reads it (the harness derives display RGB from `hex`).
- `expected.selected_id: null` means every candidate is excluded and nothing
  may be selected. `expected.score` may be omitted (e.g. for `null` selections).

### Semantics each case encodes

- **Scoring** — sum of `(candidate − target)² × weight` over channels with
  `weight > 0` (the Elixir `WeightedSquaredError` mirror; see the doctest case).
- **Exclusion** — a candidate missing a measurement for any active channel on
  either side (candidate *or* target) is excluded, never scored as zero.
- **Zero-weight channels** — channels with weight `0` neither require a
  measurement nor contribute to the score.
- **Ties** — equal-best scores resolve to the **earliest candidate in list
  order**, matching `CompositionSolver`'s deterministic earliest-wins rule.
- **Weights decide** — paired cases where flipping which channel is weighted
  10× flips the winner.

### Required coverage tags

The harness fails if the corpus loses any of these scenarios:
`tie`, `exclusion`, `all-excluded`, `zero-weight`, `weights`, `multi-channel`.
A refreshed corpus must keep carrying them (additional tags are fine).

## Refreshing from upstream

1. Take the parity corpus artifact published by
   [viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111).
2. Overwrite `ColorComposerCore/Tests/Fixtures/solver_parity_corpus.json`,
   preserving schema `version: 1` (or update the harness decoding structs
   together with the fixture — `testCorpusVersionIsSupported` guards this).
3. Verify every case still carries the required coverage tags.
4. Run the parity suite:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityCorpusTests
   ```

5. Record any mismatches (ties, exclusions, weight handling) in the PR — a
   mismatch means the Swift scorer and the Elixir solver have drifted; the fix
   belongs in the implementation, never in the corpus expectations.

The README should point here once the generated-client migration lands
(this document is the canonical description during the test-first phase).
