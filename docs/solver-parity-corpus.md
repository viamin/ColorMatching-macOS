# Solver parity corpus

The macOS app's `WeightedSquaredErrorScorer` deliberately mirrors the
`color_matching` server's `ColorMatching.WeightedSquaredError` solver and the
earliest-index-wins selection of `IlluminantMatching.best_match/4`. The
**parity corpus** is the shared golden-vector fixture both test suites replay
so that silent divergence — in tie-breaking, missing-measurement exclusion,
or channel weighting — is caught on either side (issue #39; corpus from
viamin/color_matching#111).

## Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  [`viamin/color_matching`](https://github.com/viamin/color_matching), generated
  deterministically by `ColorMatching.Parity.Corpus` (`mix parity.generate`;
  CI verifies the committed bytes with `mix parity.generate --check`).
- **This repo (consumed copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json`
  — a **byte-identical** copy so a diff immediately shows drift.

## How the tests consume it

`SolverParityCorpusTests` (in `ColorComposerCore/Tests/ColorComposerCoreTests/`)
loads the fixture via `ParityCorpusFixture` and replays every scenario:

- **Scorer level** — each candidate's `WeightedSquaredErrorScorer.score` must
  equal the corpus score exactly (`Double` `==`; every corpus value is a dyadic
  rational, so the arithmetic is exact and any last-bit difference is a real
  semantic divergence), or be `.excluded` where the corpus says `"excluded"`.
  This includes scenarios where the *target* itself is missing a channel, which
  dense solver grids cannot express.
- **Solver level** — every scenario expressible as dense grids runs through
  `CompositionSolver` on a 1×1 composition (the production contiguous fast
  path) and must select `selected_index` with exactly `error`.
- **Tie evidence** — the recomputed tied-index set, `tie_broke` flag, selected
  index (earliest of the tied set), and selected hex must all match.
- **Stamp** — `algorithm_version` (currently `1`), `scorer`, `selection`, and
  `missing_policy` are asserted, so a corpus from different semantics is
  rejected rather than mis-replayed.

## Refreshing the corpus

The corpus changes only when solver semantics change upstream. When it does:

1. In a checkout of `viamin/color_matching`, run `mix parity.generate` —
   `ColorMatching.Parity.Corpus` bumps `algorithm_version` whenever scoring
   semantics change (never edit expectations by hand).
2. Copy the regenerated file **byte-for-byte** over
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json`
   (keep the trailing newline; `sha256` both sides to confirm).
3. Update the `algorithmVersion` expectation in
   `SolverParityCorpusTests.testCorpusStampMatchesCurrentSolverSemantics`.
4. Run `cd ColorComposerCore && swift test` — the parity suite must be green;
   if it is not, the *app's* scorer has drifted from the server's solver and
   the app must be fixed to match (issue #39 non-goal: changing scorer
   semantics).

To verify the copy is current without regenerating, compare against upstream:

```bash
curl -s https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  | diff - ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json
```

An empty diff means the fixture is current for `algorithm_version` 1.

## What the corpus pins (parity findings, v1)

- **Selection:** lowest weighted squared error; ties broken by earliest
  palette index (`selection: "earliest-index-wins"`).
- **Exclusions:** a candidate *or target* missing any positive-weight channel
  is excluded — never treated as zero brightness
  (`missing_policy: "excluded-when-any-positive-weight-channel-missing"`).
- **Weights:** zero/absent weight makes a channel neither required nor
  contributing; unknown light-source keys in the weights map (e.g.
  `ultraviolet`) are ignored.
- **Score arithmetic:** sum of `weight × (candidate − target)²` over
  positive-weight channels — no per-channel averaging.
