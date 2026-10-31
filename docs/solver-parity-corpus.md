# Solver parity corpus

`WeightedSquaredErrorScorer` mirrors the Elixir `ColorMatching.WeightedSquaredError`
solver and `CompositionSolver` mirrors the earliest-wins selection of
`ColorMatching.IlluminantMatching.best_match/3`. The parity corpus is the shared
golden-vector contract that keeps the two implementations in lockstep; without it
they can silently diverge on tie-breaking, missing-measurement exclusion, or
channel weighting.

## Where the corpus lives

- **Upstream (source of truth):** [`viamin/color_matching`](https://github.com/viamin/color_matching)
  at `priv/parity/v1/corpus.json`, generated deterministically by
  `mix parity.generate` (landed in viamin/color_matching#112). It is stamped with
  `algorithm_version` (currently **1**); when that number changes, every
  expectation has moved and this repo must update in step.
- **This repo (committed copy):** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/corpus.json`
  — consumed by `WeightedSquaredErrorParityTests` in the `ColorComposerCoreTests`
  target so `swift test` replays it offline with no server or network.

The parity coverage lives as a dedicated suite inside the existing
`ColorComposerCoreTests` target; a separate SwiftPM test target would require
`Package.swift` changes that belong to the implementation phase.

## How to refresh

```bash
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/master/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/corpus.json

cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests
```

Before committing, check the top-level `algorithm_version`:

- **Unchanged** — expectations should still pass; the corpus only gained/adjusted
  scenarios upstream.
- **Bumped** — solver semantics changed upstream. Update the stamp assertion in
  `WeightedSquaredErrorParityTests.testCorpusMetadataMatchesCurrentContract`,
  review every scenario diff against `WeightedSquaredErrorScorer`, and record the
  findings in the refreshing PR.

## What the parity test asserts

Each corpus scenario carries palette colors with per-channel response vectors,
the target vector, the channel weights, and recorded solver output. The replay:

1. Builds `ChannelWeights` from the scenario weights — **unknown light-source
   keys (e.g. `ultraviolet`) are ignored**, matching the server.
2. Treats a channel **absent from a vector's `channels` map as missing**, and a
   present `0.0` as measured zero — missing is never zero.
3. Scores every palette color with `WeightedSquaredErrorScorer` and derives the
   selection with **earliest-index-wins** tie-breaking.
4. Asserts **exact** agreement with the recorded output: the full per-candidate
   score table (bit-for-bit; every corpus value is an exactly representable
   dyadic rational), `"excluded"` entries for candidates missing any
   positive-weight channel, `selected_index`, `selected_hex_color`, the winning
   `error`, `tie_broke`, and `tied_indices` — including scenarios where the
   target itself is missing a required channel (no selection exists).

The corpus deliberately contains ties (two-way, three-way, duplicate vectors,
symmetric-around-target) and all-excluded scenarios; a metadata test fails if a
refreshed corpus no longer exercises those paths.

## Parity status (corpus v1, 12 scenarios)

The replay logic was independently verified against the committed corpus during
issue #39's test phase: all 12 scenarios reproduce the recorded score tables,
selections, errors, and tie indices exactly — including the 5 tie scenarios and
the 2 no-selection scenarios. No divergence found in tie-breaking, exclusion
policy, or weight handling. Run `swift test --filter WeightedSquaredErrorParityTests`
on a Swift host to confirm.
