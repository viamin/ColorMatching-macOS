# Solver parity corpus

`WeightedSquaredErrorScorer` (and `CompositionSolver`'s earliest-index-wins
selection) deliberately mirrors the Elixir `ColorMatching.WeightedSquaredError`
solver + `ColorMatching.IlluminantMatching.best_match/4` in
[viamin/color_matching](https://github.com/viamin/color_matching). The parity
corpus is the shared golden-vector fixture that both test suites replay so
silent divergence — tie-breaking, missing-measurement exclusion, or channel
weighting — is caught on either side.

## Where the corpus lives

| Copy | Path |
| --- | --- |
| Source of truth (generated, committed upstream) | `priv/parity/v1/corpus.json` in viamin/color_matching (PR #111; regenerate there with `mix parity.generate`, verified in their CI with `mix parity.generate --check`) |
| This repo's committed mirror | `ColorComposerCore/Tests/Fixtures/parity-corpus-v1.json` (byte-identical) |

The mirror is consumed by `SolverParityCorpusTests`
(`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`),
which locates it relative to the source file (`Tests/Fixtures/…`) — no bundle
resource or `Package.swift` resource declaration is involved, so the fixture
stays byte-identical to upstream.

## What the corpus pins

Corpus metadata declares the semantics contract, asserted by the test:

- `algorithm_version: 1` — bump when scoring semantics change; every
  expectation in the corpus moves with it.
- `scorer: ColorMatching.WeightedSquaredError`
- `selection: earliest-index-wins`
- `missing_policy: excluded-when-any-positive-weight-channel-missing`

Each scenario carries a target vector, a palette (channels absent = *missing*,
never "measured as zero"), per-channel weights, and expected results:

- per-candidate scores — exact finite numbers, or the literal string
  `"excluded"` — asserted **exactly** (corpus values are binary fractions, so
  IEEE-754 double comparison has no rounding slack);
- `selected_index` / `selected_hex_color` / `error`, `tie_broke`, and
  `tied_indices` — including exact ties (symmetric offsets, duplicate vectors,
  three-way ties) where the earliest index must win;
- weight handling: zero-weight channels neither exclude nor contribute, and
  unknown light sources in the weights map (e.g. `ultraviolet`) are ignored.

The test additionally replays every scenario that has a complete target
through the real `CompositionSolver` on 1×1 grids, pinning the solver's own
tie-breaking, unmatched-cell (`nil` index, infinite error), and
excluded-candidate diagnostics.

The set of scenario IDs is pinned as a required minimum (upstream may append
scenarios; removing any of the twelve coverage scenarios — ties, exclusions,
zero-weight, unknown-weight, exact-match, mixed — fails the metadata test).

## Refreshing the corpus

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/Fixtures/parity-corpus-v1.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If upstream bumps `algorithm_version`, scoring semantics changed: do not
blindly refresh — reconcile the Swift scorer with the new semantics first,
update the mirror **and** the `algorithmVersion` pin in the test together, and
note the change in the PR description.

## Verification (as of the corpus-v1 mirror)

An independent reference computation (Python, IEEE-754 doubles) of all twelve
scenarios reproduced every expected score, selection, tie set, and exclusion
in the upstream corpus byte-for-byte before the Swift harness was written —
i.e. the corpus and the Swift scorer semantics agree exactly, including all
four tie scenarios and both no-selection scenarios.
