# Solver parity corpus

`ColorComposerCore`'s `WeightedSquaredErrorScorer` mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[`viamin/color_matching`](https://github.com/viamin/color_matching) so the app
and the server agree on which palette color is selected. Nothing in the code
enforced that agreement, so the two implementations could drift apart on
tie-breaking, missing-measurement exclusion or channel weighting without
anything noticing.

The server therefore publishes a **golden-vector corpus** (issue
[viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111),
landed in PR
[#112](https://github.com/viamin/color_matching/pull/112)) and this app
replays it in its test suite.

## Where the corpus lives

| Where | Path |
| --- | --- |
| Upstream (source of truth) | `priv/parity/v1/corpus.json` in `viamin/color_matching` |
| Committed copy in this repo | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json` |
| Replay test | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` |
| Decoder + fixture locator | `ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpus.swift`, `…/ParityCorpusFixture.swift` |

The committed copy is byte-identical to the upstream file. A checksum of the
upstream bytes is pinned in `ParityCorpusFixture.upstreamChecksum`, so an
accidental edit to the fixture fails the suite instead of quietly weakening
the parity check.

The fixture is read from the source tree (`#filePath`), so it needs no
resource declaration; declaring `Fixtures` as a test resource in the package
manifest is still worth doing so the fixture ships with the test bundle and
SwiftPM stops reporting it as an unhandled file.

## What the corpus contains

The corpus is stamped with an `algorithm_version` and carries, for every
scenario:

- `palette` — the candidates, each with a hex color and its measured
  brightness per light source (a light source absent from `channels` is
  **missing**, never zero),
- `target` — the target response vector,
- `weights` — the per-light-source weights (may include a source the app does
  not know, e.g. `ultraviolet`),
- `expected.scores` — the server's score per candidate, with the string
  `"excluded"` marking a candidate that is missing a weighted measurement,
- `expected.selected_index` / `expected.selected_hex_color` / `expected.error`
  — the server's selection,
- `expected.tie_broke` / `expected.tied_indices` — explicit tie-break evidence.

## How to refresh it

1. In a checkout of `viamin/color_matching`, make sure the committed corpus
   matches a fresh deterministic build:

   ```bash
   mix parity.generate --check
   ```

2. Copy the corpus over the committed copy:

   ```bash
   cp path/to/color_matching/priv/parity/v1/corpus.json \
      ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
   ```

3. Update the pinned checksum in `ParityCorpusFixture.upstreamChecksum` to the
   new file's FNV-1a (64-bit) hash.

4. If `algorithm_version` changed, the server's scoring or selection semantics
   changed: review the new expectations against this app's scorer **before**
   accepting them, and update the client if the semantics intentionally
   changed. The corpus is the record of what the server now does — it is not
   automatically right for the app.

## Parity findings the corpus pins down

Replaying the corpus keeps these behaviors locked to the server's:

- **Ties break by earliest index.** `tie-symmetric-around-target`,
  `tie-duplicate-vectors`, `tie-three-way-on-lps` and `mixed-large-palette`
  contain exact ties; the earliest tied candidate wins, matching the
  server's `earliest-index-wins` selection.
- **A missing measurement excludes, it is never zero.** Candidates missing a
  measurement for any positive-weight channel are excluded
  (`missing-candidate-excluded`, `all-excluded`), and so is every candidate
  when the *target* is missing such a measurement (`missing-target-excluded`).
- **Zero-weight channels neither exclude nor contribute.**
  `zero-weight-channel-missing` pins that a candidate missing an unweighted
  channel ties exactly with one whose unweighted value differs wildly.
- **Unknown light sources are ignored.** `unknown-weight-ignored` carries a
  weight for `ultraviolet`, which no vector can measure; the scenario scores
  exactly like `distinct-errors`.
- **Weights scale the squared error.** `distinct-errors` and
  `exact-match-zero-error` pin the per-channel weighting and the exact zero
  error of a channel-for-channel clone of the target.
