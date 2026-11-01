# Solver parity corpus

The Elixir service's `ColorMatching.WeightedSquaredError` solver is the
authority for palette-color selection; this app's
`WeightedSquaredErrorScorer` deliberately mirrors it so client and server
agree on every selection. The parity corpus makes that mirror a *tested*
contract instead of a comment.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json
```

Keeping the corpus inside the test target means `swift test` enforces parity
on every run with no extra setup.

## What it covers

Every case is a self-contained selection problem:

| Field | Meaning |
| --- | --- |
| `weights` | Per-channel weights; absent channels carry weight `0` (inactive → neither required nor summed) |
| `target` | Desired brightness per lighting condition |
| `palette` | Candidates as `id` + `responses` (a missing key = *unmeasured*, never brightness zero) |
| `expected.selected_color_id` | Winner under `IlluminantMatching.best_match/4` — lowest score wins, **earliest palette entry wins ties**, or `null` when every candidate is excluded |
| `expected.score` | The winner's weighted squared error (raw weighted sum — the Elixir scorer never normalizes by the weight sum) |
| `expected.excluded_color_ids` | Candidates that must be excluded for missing a measurement on a weight-`>0` channel |

The committed cases pin the parity findings that matter (see
`docs/openapi-client-adoption.md` for the current results):

- **Score value parity** — the Elixir module doctest pair scores exactly
  `0.205` (weights `white 0.5, red 1.0, green 1.0, lps 1.5`).
- **Ties** — symmetric candidates and duplicate candidates both resolve to
  the *earliest* palette entry; an extra measurement on a zero-weight channel
  never breaks a tie.
- **Exclusions** — a candidate missing any required channel is excluded even
  when it would win if "missing" were misread as brightness `0`; if *all*
  candidates are excluded, the expected selection is `null` (an unmatched
  cell).
- **Weight handling** — zero-weight channels are optional and never enter the
  sum; heavy weights dominate channel trade-offs; weights are not normalized.

## How it is consumed

`WeightedSquaredErrorParityTests` (same directory) loads the fixture and
asserts parity at two levels:

1. **Scorer level** — score values, exclusions, and the `best_match`
   selection policy against `WeightedSquaredErrorScorer` directly.
2. **Solver level** — the same cases through `CompositionSolver`'s optimized
   fast path (1×1 grids), i.e. the selection code the app actually ships.

Run it with the rest of the package:

```bash
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests
```

## Refreshing from upstream

The corpus originates from viamin/color_matching#111. When upstream publishes
or extends the corpus:

1. Download the corpus JSON from the `color_matching` repository.
2. Convert it (if needed) to the schema above — keys are the `light_source`
   strings (`white`, `red`, `green`, `blue`, `lps`), matching
   `LightingCondition` raw values.
3. Overwrite the fixture at the path above and add cases for any newly
   covered behavior (keep at least one `tie`, one `exclusion`, and one
   `weights` kind — `testCorpusLoadsAndCoversTiesExclusionsAndWeightHandling`
   enforces this).
4. Run `swift test`. A failure means genuine client/server solver divergence —
   fix the *client* to match the server (never edit expected outputs to make
   the test pass without an upstream cross-check).

Until #111 lands, the committed fixture is a seed corpus hand-derived from
the documented Elixir semantics (anchored on the module doctest); its
`source` field records that provenance.
