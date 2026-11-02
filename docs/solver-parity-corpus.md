# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json` is the
committed corpus that enforces parity between the Swift
`WeightedSquaredErrorScorer` and the Elixir `ColorMatching.WeightedSquaredError`
solver (issue #39).

> README note: the README section on corpus consumption belongs with the
> implementation change; this document is the canonical description.

## Where it lives

- **Corpus:** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
- **Consuming test:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
- Loaded relative to the test source via `#filePath` (no `Package.swift`
  resource declaration required); when `Fixtures` is instead declared as a
  copied resource, the loader can move to `Bundle(for:)` without touching the
  corpus format.

## What it asserts

Every case runs at two levels:

1. **Scorer level** — each candidate is scored by `WeightedSquaredErrorScorer`;
   excluded ids, the selected id/index, and the winning score must match the
   corpus exactly (`1e-12`). Tie cases additionally require the tied scores to
   be *exactly* equal and the earliest palette entry to win.
2. **Solver level** — for cases with a selection, a 1×1 composition through the
   production `CompositionSolver` fast path must pick the same color and error.

The corpus pins the semantics shared with the server:

- **Weighted sum** — `weight * (candidate − target)²` accumulated in canonical
  channel order (`white, red, green, blue, lps`).
- **Exclusions** — a candidate *or target* missing a measurement for any
  channel with weight `> 0` is excluded; a missing measurement is never
  treated as zero brightness (and a measured `0.0` is never treated as
  missing).
- **Zero-weight channels** — channels with weight `0` are not required and do
  not exclude candidates missing them.
- **Ties** — resolve to the earliest palette entry (`best_match/4` policy).

## Corpus format

```jsonc
{
  "version": 1,                       // loader asserts this
  "scorer": "weighted_squared_error", // loader asserts this
  "channel_order": ["white", "red", "green", "blue", "lps"],
  "tie_policy": "earliest_palette_entry_wins",
  "cases": [
    {
      "id": "case-id",
      "palette": [ { "id": 11, "responses": { "red": 0.3 } } ], // absent = unmeasured
      "target": { "red": 0.4 },                                  // absent = unmeasured
      "weights": { "white": 0, "red": 1, "green": 0, "blue": 0, "lps": 0 },
      "expected": {
        "selected_id": 11,      // null ⇒ every candidate excluded
        "selected_index": 0,    // palette position of the winner
        "excluded_ids": [],
        "score": 0.010000000000000002,  // winning score; null when unselected
        "tie_ids": [11, 12]      // optional: pair that must tie exactly
      }
    }
  ]
}
```

Scores are IEEE-754 doubles serialized at full precision; the test compares
with `1e-12` accuracy.

## Refreshing the corpus

The corpus is *generated server-side* by viamin/color_matching#111. Until that
corpus is published, this fixture is a **hand-authored placeholder** whose
expected values were computed with a reference implementation of the
documented semantics (canonical order, strict `<` tie-break, target-side
exclusion) and cross-checked against the Elixir `WeightedSquaredError` doctest
(winning score `0.205`).

To refresh once #111 lands:

1. Download the generated corpus JSON from the `color_matching` repository
   (its release artifact / priv dir per #111) and replace the fixture file.
2. If the generator bumps `version` or renames fields, extend
   `SolverParityCorpusTests.loadCorpus()` and the `ParityCorpus` DTOs to the
   new format — the loader fails loudly on unknown versions so a silent
   contract drift is impossible.
3. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.
   Any failure is a genuine client/server solver divergence: fix the scorer
   (client) or the corpus (server) before shipping — never loosen the test.
