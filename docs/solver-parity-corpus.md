# Solver parity corpus

The Swift `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver so the macOS client and the
`color_matching` server pick identical inks for identical inputs. That parity
is enforced by replaying a committed golden-vector corpus through the Swift
scorer and comparing **exactly** against the outputs the Elixir solver
produced.

## Where the corpus lives

- **Upstream (source of truth):** [`viamin/color_matching`](https://github.com/viamin/color_matching)
  at `priv/parity/v1/corpus.json` (parity corpus PR #111). It is generated
  deterministically by `mix parity.generate` (`lib/color_matching/parity/corpus.ex`)
  and consumed upstream by `test/color_matching/parity/corpus_test.exs`.
- **This repo (committed copy):** `ColorComposerCore/Tests/ParityCorpus/corpus.json` —
  a verbatim copy of the upstream file for algorithm version 1
  (SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
- **Consuming test:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
  (`swift test` inside `ColorComposerCore/`). The loader looks for a bundle
  resource named `corpus.json` first (if the fixture is later declared in
  `Package.swift`), then falls back to the source-tree path above.

## Corpus contract

```json
{
  "algorithm_version": 1,
  "scorer": "ColorMatching.WeightedSquaredError",
  "selection": "earliest-index-wins",
  "missing_policy": "excluded-when-any-positive-weight-channel-missing",
  "light_sources": ["white", "red", "green", "blue", "lps"],
  "scenarios": [
    {
      "id": "tie-symmetric-around-target",
      "palette":   [{ "index": 0, "hex_color": "#111111", "channels": { "white": 0.875, ... } }],
      "target":    { "index": null, "hex_color": "#336699", "channels": { ... } },
      "weights":   { "white": 0.5, "red": 1.0, "blue": 0.25, "lps": 1.5 },
      "expected":  {
        "scores": [{ "index": 0, "score": 0.0703125 }, { "index": 3, "score": "excluded" }],
        "selected_index": 1, "selected_hex_color": "#222222", "error": 0.0078125,
        "tie_broke": true, "tied_indices": [1, 2]
      }
    }
  ]
}
```

Semantics the replay relies on (all verified against the current corpus):

- **Channels:** a light-source key **absent** from `channels` is a *missing
  measurement* — never zero brightness. Unknown light-source keys are dropped.
- **Weights:** a light source with weight `0` or absent is ignored entirely,
  including for exclusion. Weight keys that are not known light sources (e.g.
  `ultraviolet`) are silently ignored, mirroring the Elixir `filter_weights/1`.
- **Exclusion:** a candidate or target missing a measurement for any channel
  with weight `> 0` is `excluded` (score is the string `"excluded"`).
- **Selection:** lowest score wins; ties break to the **earliest palette
  index** (`tie_broke` records whether the winner came from a tie,
  `tied_indices` lists every index sharing the winning score).
- **Exactness:** every number in the corpus is a dyadic rational, so IEEE 754
  arithmetic is exact and order-independent. The Swift test therefore asserts
  exact `Double` equality (no tolerance), matching the upstream Elixir corpus
  test's `==`.

Scenario taxonomy in corpus v1 (12 scenarios): `distinct-errors`,
`tie-symmetric-around-target`, `tie-duplicate-vectors`, `tie-three-way-on-lps`,
`missing-candidate-excluded`, `missing-target-excluded`,
`zero-weight-channel-missing`, `all-excluded`, `single-channel-lps`,
`exact-match-zero-error`, `unknown-weight-ignored`, `mixed-large-palette`.

## How to refresh

1. Fetch the upstream corpus for the current algorithm version:

   ```bash
   curl -fsSL \
     https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
     -o ColorComposerCore/Tests/ParityCorpus/corpus.json
   ```

2. Re-run the parity suite:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityCorpusTests
   ```

3. If upstream bumps `algorithm_version` (solver semantics changed), the
   metadata test fails by design: port the corresponding semantic change to
   `WeightedSquaredErrorScorer` **before** refreshing the corpus. Do not adjust
   the scorer to make a mismatching corpus pass without understanding the
   upstream change.

The README ("Palette data" / development sections) should link to this file;
see also `docs/openapi-client-migration.md` for the companion OpenAPI-client
work.
