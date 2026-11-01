# Solver parity corpus

`WeightedSquaredErrorScorer` in `ColorComposerCore` deliberately mirrors the
Elixir `ColorMatching.WeightedSquaredError` solver plus the
earliest-index-wins selection of `ColorMatching.IlluminantMatching`, so the
macOS client and the `color_matching` server always pick the same palette
color. The **parity corpus** is the server-published golden-vector fixture
that makes that mirroring an enforced contract instead of a hope.

## Where the corpus lives

| What | Where |
| --- | --- |
| Committed fixture (this repo) | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json` |
| Source of truth (server) | [`viamin/color_matching`](https://github.com/viamin/color_matching) at `priv/parity/v1/corpus.json` (published via viamin/color_matching#111) |
| Generating side | `ColorMatching.Parity.Corpus` + `mix parity.generate` (deterministic; CI runs `mix parity.generate --check` to verify committed bytes) |
| Consuming side | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` (issue #39) |

The fixture is a **byte-for-byte copy** of the upstream file. Do not hand-edit
it; refresh it wholesale (below).

## What the parity suite asserts

For every scenario in the corpus, replayed against
`WeightedSquaredErrorScorer` with selection mirroring
`CompositionSolver.bestCandidate` (earliest index wins on strict `<`):

- **Per-candidate scores** match the corpus exactly — including the
  `excluded` marker for candidates missing a positive-weight channel.
  Corpus values are dyadic rationals (multiples of 1/2^k), so Swift `Double`
  and Elixir float arithmetic agree bit-for-bit and scores compare with exact
  equality; any difference is real drift, not rounding.
- **Selection** (`selected_index`, `selected_hex_color`, `error`) matches,
  including tie scenarios (`tie-symmetric-around-target`,
  `tie-three-way-on-lps`, `tie-duplicate-vectors`, `mixed-large-palette`).
- **Tie evidence** (`tie_broke`, `tied_indices`) matches exactly, with ties
  detected by exact equality as on the server.
- **Weight handling**: zero-weight channels neither exclude nor contribute
  (`zero-weight-channel-missing`); unknown light sources in the weights map
  are ignored (`unknown-weight-ignored`).
- **Corpus metadata guards**: `selection` is `earliest-index-wins`,
  `missing_policy` is `excluded-when-any-positive-weight-channel-missing`,
  `light_sources` equals `LightingCondition.allCases`, and
  `algorithm_version` equals `ParityCorpusFixture.supportedAlgorithmVersion`
  (currently `1`).

The suite covers all 12 corpus scenarios as of `algorithm_version: 1`
(distinct errors, three tie shapes, candidate/target exclusion,
all-excluded, zero-weight-missing, single-channel, exact-match-zero-error,
unknown-weight-ignored, mixed large palette).

## How to refresh

1. Fetch the new corpus from the server repo (replace `v1` with the current
   algorithm version directory if it moved):

   ```bash
   curl -fsSL \
     https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
     -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
   ```

   If upstream bumps `algorithm_version`, also move the fixture to the new
   versioned directory (`Fixtures/parity/v2/…`) and update
   `ParityCorpusFixture.relativePath`.

2. Bump `ParityCorpusFixture.supportedAlgorithmVersion` to the new
   `algorithm_version`. The metadata-guard test fails loudly until you do —
   that is intentional: a version bump means every expectation moved.

3. Run the suite:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityCorpusTests
   ```

   A failure after a same-version refresh means the Swift scorer genuinely
   diverged from the server — fix the scorer (or coordinate the upstream
   change), never the fixture.

## README linkage

The implementation PR for issue #39 should link this document from the
repo `README.md` (suggested spot: the *Development* section, next to
`swift test`). This test-writing phase can only commit under test paths and
`docs/`, so the README edit itself is deferred to the implementation run.
