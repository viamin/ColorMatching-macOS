# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver, and `CompositionSolver` mirrors
the earliest-index-wins selection of `ColorMatching.IlluminantMatching`. The
**parity corpus** is the shared source of truth that keeps the two
implementations from silently diverging (tie-breaking, missing-measurement
exclusion, channel weighting).

## Where the corpus lives

- **Upstream (source of truth):** [`viamin/color_matching`](https://github.com/viamin/color_matching)
  at `priv/parity/v1/corpus.json`, generated deterministically by
  `ColorMatching.Parity.Corpus` (landed as viamin/color_matching#112 — the
  parity-corpus dependency of issue #39). Regenerate upstream with
  `mix parity.generate`; upstream CI verifies the committed bytes with
  `mix parity.generate --check`.
- **This repo (consumed copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
  — a **byte-identical** copy (sha256
  `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604` at the
  time of committing).

## How the tests consume it

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
loads the fixture (via a `#filePath`-relative lookup, so no resource bundling
is required) and asserts, for every scenario:

- **Exact score parity** — every candidate's score reproduces the corpus's
  expected float *bit-for-bit* (both sides compute IEEE 754 doubles over the
  same dyadic values), and `"excluded"` maps to `ScorerResult.excluded`
  (missing is never treated as zero brightness).
- **Selection parity** — solving a 1×1 grid per active channel through
  `CompositionSolver` selects `expected.selected_index` (or leaves the cell
  unmatched with an infinite error when every candidate is excluded).
- **Tie parity** — `tied_indices` lists every candidate at the minimum score,
  the selection is the earliest of them, and `tie_broke` is true exactly when
  more than one candidate is tied.
- **Weight parity** — weights arrive as a light-source map that may carry
  unknown sources (e.g. `ultraviolet`); only the five canonical conditions
  (`white`, `red`, `green`, `blue`, `lps`) influence scoring and unknown keys
  never exclude a candidate.
- **Metadata guards** — `algorithm_version` (currently `1`), `scorer`
  (`ColorMatching.WeightedSquaredError`), `selection`
  (`earliest-index-wins`), and `missing_policy`
  (`excluded-when-any-positive-weight-channel-missing`) must match the
  semantics this app implements; a change upstream means every expectation
  may have moved and the mirror must be re-audited.

One scenario shape cannot be built through `CompositionSolver`: a *target*
missing a positively-weighted channel (`BrightnessGrid` always yields a
value, so the app can never construct such a target). The corpus's
`missing-target-excluded` scenario is therefore asserted at scorer level
(`testScorerScoresMatchCorpusExactly`), which is where the app would ever
evaluate such a vector.

## How to refresh the fixture

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Rules:

1. Copy **byte-for-byte** — never hand-edit; the corpus is deterministic
   upstream (`mix parity.generate` always emits identical bytes).
2. If `algorithm_version` changed, the scorer/selection semantics moved:
   update `WeightedSquaredErrorScorer`/`CompositionSolver` (or consciously
   fork), then update the metadata guard in the test. The failing metadata
   test is the prompt.
3. `swift test` must stay green after the refresh; if it is not, the client
   and server have genuinely diverged — fix the divergence, do not adjust
   the fixture.
