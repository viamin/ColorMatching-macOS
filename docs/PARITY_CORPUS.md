# Solver parity corpus

`WeightedSquaredErrorScorer` (and `CompositionSolver`'s selection) deliberately
mirrors the Elixir `ColorMatching.WeightedSquaredError` /
`IlluminantMatching.best_match/4` in [`color_matching`](https://github.com/viamin/color_matching).
The parity corpus is the machine-checked form of that promise: a set of
golden-vector scenarios — palette response vectors, targets, weights, and the
Elixir solver's expected scores, selections, and tie evidence — that the Swift
tests replay and must agree with exactly.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

It is a byte-verbatim copy of
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json)
from `color_matching` @ commit `a82aec5441d2a7b0100e8c8ab81d573e11ace9b0`
("feat(parity): add solver golden-vector corpus for client/server parity
(#112)", closing viamin/color_matching#111). `v1` mirrors the upstream corpus
version directory and the file's `algorithm_version` stamp (currently `1`).

## How the tests consume it

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`:

- **Fixture invariants** — the file is committed, stamped
  `algorithm_version == 1`, `scorer == "ColorMatching.WeightedSquaredError"`,
  `selection == "earliest-index-wins"`, and the canonical light-source set
  (`white red green blue lps`). If upstream bumps the algorithm version, this
  test fails loudly until the fixture is refreshed and the stamp updated.
- **Coverage guard** — the corpus keeps at least one intentionally tied
  scenario and at least one with no selection at all (mirrors the upstream
  ExUnit guard).
- **Scorer parity** — for every scenario, every candidate's score matches the
  corpus exactly (exact `Double` equality, matching the upstream ExUnit
  replay's exact float equality); the selection is the earliest index among
  minimum scores; the winning error, selected hex color, `tied_indices`, and
  `tie_broke` all match.
- **Solver parity** — every solver-representable scenario is replayed through
  `CompositionSolver` on a 1×1 grid (the production fast path): the selected
  palette index, per-cell error, and `excludedCandidateCount` must match.
  Scenarios whose *target* is missing a positively-weighted channel cannot be
  expressed as source grids (a target missing a channel is unrepresentable in
  the app, where targets come from fully-materialized images) and are covered
  by the scorer test instead.

### Corpus semantics (what parity means here)

| Concern | Semantics |
| --- | --- |
| Missing measurements | A candidate (or target) missing **any positive-weight channel** is excluded — never treated as zero brightness (`missing_policy: excluded-when-any-positive-weight-channel-missing`). |
| Zero-weight channels | Neither exclude nor contribute; missing data on an unweighted channel is invisible. |
| Ties | Earliest index wins; `tied_indices` lists every candidate at the winning score, `tie_broke` is `tied_indices.count > 1`. |
| Unknown light sources | Weight keys outside `white/red/green/blue/lps` (e.g. `ultraviolet`) are ignored. |
| Weight handling | Error is `Σ (candidate − target)² × weight` over active channels only. |

Before the Swift harness was committed, its mapping was validated offline by
replaying all 12 scenarios in an independent Python implementation of the
semantics above: 12/12 scenarios agreed with the corpus, including exact float
equality on every score and error.

## Refreshing the corpus

The corpus is generated upstream, never hand-edited here:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

- Upstream regeneration (deterministic, byte-stable) is
  `mix parity.generate` in the `color_matching` repo; its CI proves
  regeneration is byte-identical.
- If upstream bumps `algorithm_version` (solver semantics changed on
  purpose), pull the new corpus **and** update the stamp assertion in
  `SolverParityCorpusTests` in the same commit — a version bump with a stale
  fixture (or vice versa) is exactly what the test is there to catch.
- `algorithm_version` bumps are expected to change solver selections; that is
  a deliberate behavior change for this app too, not a test bug.

> README note: the repository README should link here for corpus consumption
> (issue #39 deliverable). The README itself is out of scope for the
> tests-only change that introduced this document; the link lands with the
> implementation change.
