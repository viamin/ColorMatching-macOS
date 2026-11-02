# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver so the macOS client and the
`color_matching` server agree on color selection. The parity corpus makes that
mirror **enforced by tests** instead of assumed.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift   # consumer
```

The committed fixture currently encodes the `WeightedSquaredError` semantics by
hand (including the Elixir doctest example). Once the generated corpus from
viamin/color_matching#111 is published, the fixture is **replaced wholesale**
with that machine-generated file — same path, same format — so the test target
always consumes the upstream corpus.

## What the corpus pins

Each case declares a palette (colors with per-illuminant brightness), channel
weights, a row of target vectors, and the expected outcome per target:

- **Exact selections** — the selected color id must match `expected_selections[].color_id` exactly, with the expected weighted squared error (tolerance 1e-9).
- **Tie cases** — equal scores resolve to the **earliest palette index** (the Elixir `IlluminantMatching.best_match/4` policy). The corpus carries dedicated tie cases (`tie_break: "earliest_palette_index"`).
- **Exclusions** — a candidate missing a measurement for any *active* channel (weight > 0) is excluded, never treated as zero brightness; `expected_excluded_count` pins how many candidates drop out, and a `color_id: null` selection pins cells no candidate can serve.
- **Weight handling** — weight-symmetric cases show heavier channels flipping the winner; zero-weight channels neither require measurements nor contribute to the score.

The tests run every case through **both** solver paths — the optimized fast
path (`CompositionSolver()`) and the general per-candidate path (via a
forwarding scorer) — so the two paths cannot diverge either.

## Format

```json
{
  "version": 1,
  "scorer": "weighted_squared_error",
  "tie_break": "earliest_palette_index",
  "cases": [
    {
      "name": "equidistant tie resolves to the earliest palette entry",
      "weights": { "white": 0, "red": 1, "green": 1, "blue": 0, "lps": 0 },
      "palette": [
        { "id": 201, "hex": "#000000", "responses": { "red": 0.0, "green": 0.0 } },
        { "id": 202, "hex": "#FFFFFF", "responses": { "red": 1.0, "green": 1.0 } }
      ],
      "targets": [ { "red": 0.5, "green": 0.5 } ],
      "expected_selections": [ { "color_id": 201, "error": 0.5 } ],
      "expected_excluded_count": 0
    }
  ]
}
```

- Keys are snake_case; the loader uses `JSONDecoder` with
  `.convertFromSnakeCase`.
- `weights` carries all five channels (`white`, `red`, `green`, `blue`, `lps`); weight `0` deactivates the channel.
- `responses` maps light-source strings (the server's `light_source` keys) to brightness in `0.0...1.0`; absent = unmeasured.
- `expected_selections` has one entry per target, in row-major grid order; `color_id`/`error` are `null` when no candidate is eligible.
- The loader rejects an unknown `version`, `scorer`, or `tie_break` so a
  format change upstream fails loudly instead of testing the wrong contract.

## Refreshing the corpus

1. Export the corpus from an up-to-date `color_matching` server checkout
   (parity corpus export from viamin/color_matching#111).
2. Replace `Fixtures/solver_parity_corpus.json` with the exported file
   (bump `version` only if the format changed, and update the loader's
   decoding to match).
3. Run the tests:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

A mismatch means client and server solvers have drifted: fix the client (or
flag the server change) — never edit expected values to make the test pass.
