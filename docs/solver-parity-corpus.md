# Solver parity corpus

This app mirrors the Elixir solver of the `color_matching` backend
(`ColorMatching.WeightedSquaredError` plus the earliest-wins selection of
`ColorMatching.IlluminantMatching`). The two implementations agree only if
they agree on three things at once:

1. **the score** — `Σ weight × (candidate − target)²` over the weighted
   channels,
2. **the exclusion policy** — a candidate (or the target) missing a
   measurement for any channel with weight `> 0` is *excluded*, never read as
   zero brightness,
3. **the tie policy** — the lowest score wins and ties go to the **earliest**
   candidate in the palette order.

Nothing in this repository enforced those three rules until now: the app's own
unit tests could only prove that the app is self-consistent, not that it agrees
with the server that owns the palette data. The **parity corpus** closes that
gap.

## Where the corpus lives

| | |
| --- | --- |
| Upstream repository | [`viamin/color_matching`](https://github.com/viamin/color_matching) |
| Upstream path | `priv/parity/v1/corpus.json` |
| Upstream dependency | [`viamin/color_matching` #111](https://github.com/viamin/color_matching/issues/111) |
| Upstream generator | `mix parity.generate` |
| Upstream CI guard | `mix parity.generate --check` (fails when the committed bytes drift) |
| **This repository** | `ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json` (byte-identical copy) |
| Provenance notes | `ColorComposerCore/Tests/Fixtures/parity/README.md` |
| Replayed by | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityTests.swift` |

The corpus is committed (not fetched at test time) because the Swift package
is built by the Xcode app target, which has no Elixir toolchain and no running
server. The committed bytes are never edited by hand.

## What the corpus asserts

The corpus header records the coupled semantics it was produced with:

```json
{
  "algorithm_version": 1,
  "scorer": "ColorMatching.WeightedSquaredError",
  "selection": "earliest-index-wins",
  "missing_policy": "excluded-when-any-positive-weight-channel-missing",
  "light_sources": ["white", "red", "green", "blue", "lps"]
}
```

`SolverParityTests` replays all twelve scenarios and asserts, for each of
them:

- every candidate's score matches the server's **exactly** (the corpus values
  are exact binary fractions, so the comparison is bit-for-bit, not a
  tolerance);
- candidates the server excludes are excluded here too, for the same reason;
- the selected color, its error, and the tied-index list match;
- `tie_broke` is true exactly when more than one candidate shares the best
  score, and the winner is the **earliest** of them;
- the solver the app ships (`CompositionSolver`, including its optimized
  nearest-neighbor fast path) selects the same color as the server.

## The twelve scenarios

| Scenario | What it pins |
| --- | --- |
| `distinct-errors` | The clear best candidate wins outright. |
| `tie-symmetric-around-target` | Two candidates sit exactly ±0.125 from the target on white and match elsewhere — an exact tie; the earlier index wins. |
| `tie-duplicate-vectors` | Two candidates carry identical channel values under different hex colors — an exact tie; the earlier index wins. |
| `tie-three-way-on-lps` | Three candidates tie exactly on the only weighted channel (lps); the earliest index wins even though a later candidate matches bit-for-bit. |
| `missing-candidate-excluded` | The best-matching candidate is missing lps (a weighted channel) and is therefore excluded rather than scored as zero brightness; the runner-up wins. |
| `missing-target-excluded` | The target itself is missing a weighted channel, so *every* candidate is excluded and no selection exists. |
| `zero-weight-channel-missing` | blue has weight 0: a candidate missing blue is not excluded, and a wildly different blue value ties exactly — missing data on unweighted channels neither excludes nor contributes. |
| `all-excluded` | Every candidate misses at least one weighted channel; nothing is selected. |
| `single-channel-lps` | Only lps is weighted: the exact match scores 0.0 even though every other channel is unmeasured. |
| `exact-match-zero-error` | A channel-for-channel clone of the target scores exactly 0.0. |
| `unknown-weight-ignored` | The weight map carries an unknown light source (`ultraviolet`); it is ignored and the result matches `distinct-errors` verbatim. |
| `mixed-large-palette` | Eight candidates mixing exact ties, exclusions and unmeasured zero-weight channels; the earliest member of the tied best trio wins. |

### Parity findings

- **Ties are common, not exotic.** Three of the twelve scenarios end in a tie.
  A client that broke ties differently — or that used `<=` instead of `<` while
  scanning the palette — would print a different color than the server for the
  same data while every score-based test still passed.
- **Exclusions are asymmetric in practice.** A candidate missing a *weighted*
  channel is excluded; the same candidate missing an *unweighted* channel is
  scored normally. `zero-weight-channel-missing` shows that a missing
  measurement on an unweighted channel can even tie exactly with a measured
  one, so the exclusion check must look at the weights and not at the data.
- **A missing target excludes everything.** `missing-target-excluded` and
  `all-excluded` produce *no* selection: the solver leaves the cell unmatched
  (`Double.infinity`) instead of falling back to an arbitrary color.
- **Weight handling has two halves.** Weights decide which channels are
  *required* (exclusion) and how much each channel *contributes* (the score).
  Unknown light sources in the weight map are ignored entirely — they are
  neither required nor scored.
- **The score is exactly reproducible.** Every corpus value is a dyadic
  rational and every weight is one too, so the summation order (canonical
  `white, red, green, blue, lps` here, alphabetical on the server) cannot
  change the result: the sums are exactly representable and the parity test
  compares them for equality.

## Refreshing the corpus

1. Regenerate the corpus in a checkout of `viamin/color_matching`:

   ```bash
   mix parity.generate          # writes priv/parity/v1/corpus.json
   mix parity.generate --check  # CI guard: fails when the committed bytes drift
   ```

2. Copy the file over the committed copy, keeping the layout:

   ```bash
   cp /path/to/color_matching/priv/parity/v1/corpus.json \
      ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json
   ```

3. Update the provenance table in
   `ColorComposerCore/Tests/Fixtures/parity/README.md` (copied-on date,
   SHA-256, size) and the `expectedSHA256` constant plus the expected
   metadata and scenario ids in `SolverParityTests.swift`.

4. Run the parity tests:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityTests
   ```

If the upstream `algorithm_version` changed, the server's scoring semantics
changed: every expectation in the corpus moved with it, and the parity test
fails loudly instead of silently accepting a different algorithm.
