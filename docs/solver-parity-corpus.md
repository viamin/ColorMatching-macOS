# Solver parity corpus

The `ColorComposerCore` solver deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver so the macOS client and the
`color_matching` server always agree on which palette color represents a target
response vector. The parity corpus is committed test data that enforces this:
every case is a palette, a target, per-channel weights, and the expected
selection, and the test suite fails if the Swift scorer disagrees with the
corpus by even one selection.

## Where the corpus lives

```
ColorComposerCore/Tests/Fixtures/solver_parity_corpus.json
```

It is loaded at test time by
`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
via a `#filePath`-relative lookup, so no `Package.swift` resource declaration
is needed and `swift test` picks it up both locally and in CI.

The upstream source of truth is the parity corpus published by the Elixir
service (viamin/color_matching#111). Until that canonical corpus lands, this
repository carries a v1 corpus derived from the documented Elixir
`WeightedSquaredError` semantics and anchored on its doctest case (weights
white 0.5 / red 1.0 / green 1.0 / blue 0.0 / lps 1.5 → expected error
`0.205`).

## What each case pins

- **Selection** — the exact palette color id that must win.
- **Winning error** — the weighted squared error, asserted to 1e-12.
- **Exclusions** — candidates missing a measurement for any weight > 0
  condition are excluded, never treated as zero brightness.
- **Ties** — cases tagged `"tie"` require at least two candidates to hold the
  winning score; the *earliest* palette candidate must win, matching the
  Elixir `IlluminantMatching.best_match/4` policy.
- **Weights** — zero-weight conditions are neither required nor scored;
  flipping weights flips winners (cases `weights_change_winner_*`).
- **No selection** — cases tagged `"no_selection"` expect every candidate to
  be excluded (all candidates missing the required channel, or the target
  itself missing a required channel — the latter is scorer-level only, since
  the solver always derives targets from source grids).

Cases whose target defines every active condition are additionally
cross-checked through `CompositionSolver` on a 1×1 grid, so the optimized fast
path obeys the same contract as the scorer.

## Schema (v1)

```json
{
  "version": 1,
  "solver": "WeightedSquaredError",
  "tie_break": "earliest_candidate",
  "cases": [
    {
      "name": "unique_case_name",
      "description": "why this case exists",
      "tags": ["tie", "exclusion", "weights", "zero_weight", "no_selection", "anchor", "multi_channel"],
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "target": { "white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5 },
      "palette": [
        { "id": 101, "hex": "#63504A", "responses": { "white": 0.5, "red": 0.1 } }
      ],
      "expected": { "selected_id": 101, "error": 0.205, "excluded_ids": [103] }
    }
  ]
}
```

- `weights` and `target`/`responses` keys use the canonical light sources
  (`white`, `red`, `green`, `blue`, `lps`); omitted weights are `0`.
- `expected.selected_id` and `expected.error` are `null` for no-selection
  cases; `excluded_ids` lists excluded candidate ids in palette order.
- `tags` are advisory for humans but `"tie"` is verified by the test (a
  tagged case must genuinely tie).

## Refreshing the corpus

1. Fetch the canonical corpus from the `color_matching` repository once
   viamin/color_matching#111 lands (it is generated from the Elixir solver and
   covers the same `WeightedSquaredError` surface).
2. Replace `ColorComposerCore/Tests/Fixtures/solver_parity_corpus.json` with
   it, keeping schema v1. The corpus is a drop-in replacement: the loader
   does not depend on case counts, ids, or names (beyond the
   `elixir_doctest_anchor` anchor test, which may be renamed if the canonical
   corpus uses a different anchor case name).
3. If the upstream schema differs, extend the loader in
   `SolverParityCorpusTests.swift` and bump `version`; schema changes must
   keep the corpus readable without changing scorer semantics.
4. Run the parity suite:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityCorpus
   ```

A failure means the Swift `WeightedSquaredErrorScorer` and the corpus disagree
— fix the divergence (or refresh a stale corpus) before merging; do not weaken
the assertions.

## Related: `/api/v1` wire contract

The generated OpenAPI client migration (issue #39, consuming the spec from
viamin/color_matching#110) is guarded by
`ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift`,
which pins the endpoints (`/api/v1/printer_profiles`,
`/api/v1/colors?printer_profile_id=N`), `Accept`/`Authorization` headers,
status-code error mapping, snake_case decoding, absent-not-zero responses,
and the hex fallback. The disk cache, per-server/profile namespacing,
offline-stale entries, and cached-profile fallback are guarded by
`ProfileColorCacheTests.swift` and must stay green across the migration.
