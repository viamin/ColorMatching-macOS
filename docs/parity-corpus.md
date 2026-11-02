# Solver parity corpus

`ColorComposerCore` enforces parity between the macOS app's
`WeightedSquaredErrorScorer` and the Elixir `ColorMatching.WeightedSquaredError`
solver by replaying a committed corpus of expected selections (issue #39,
upstream viamin/color_matching#111).

## Where the corpus lives

- **Fixture (committed, consumed by tests):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_corpus.json`
- **Test suite:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
- **Upstream publisher:** the `color_matching` service (viamin/color_matching#111)
  generates the corpus from its own solver so both implementations are checked
  against the same expected outputs.

The fixture is located relative to the test source file (`#filePath`), so no
SwiftPM resource bundle is required and the suite runs identically under
`swift test`, Xcode, and the `bin/lint` portable harness.

## What the tests assert

Every corpus case is replayed through `WeightedSquaredErrorScorer` with the
`color_matching` selection policy (lowest score wins; **earliest candidate wins
a tie**, mirroring `IlluminantMatching.best_match/4`), and through the full
`CompositionSolver` fast path on a 1×1 grid. For each case the suite asserts:

- the selected color id matches `expected.selected_color_id` exactly
  (`null` when every candidate must be excluded);
- the winning score matches `expected.score` (when present) to 1e-9;
- the excluded candidate set matches `expected.excluded_color_ids` (when present);
- tie cases are genuine bitwise ties and select the earliest tied candidate;
- zero-weight channels neither require a measurement nor contribute to the score.

An integrity test guards the corpus itself: ≥10 cases, unique ids, ≥2 tie
cases, ≥2 exclusion cases, only canonical light-source keys (`white`, `red`,
`green`, `blue`, `lps`), and parseable `#RRGGBB` hexes.

## Corpus schema (v1, snake_case)

```json
{
  "version": 1,
  "source": {"repository": "viamin/color_matching", "pull_request": 111, "generator": "..."},
  "cases": [
    {
      "id": "case-id",
      "kind": "selection | tie | exclusion | weighting",
      "description": "what the case pins",
      "weights": {"red": 1.0, "lps": 1.5},
      "target": {"red": 0.2, "lps": 0.5},
      "palette": [
        {"id": 1, "hex": "#5A294D", "responses": {"red": {"brightness": 0.1}}}
      ],
      "expected": {
        "selected_color_id": 2,
        "score": 0.205,
        "excluded_color_ids": [1]
      }
    }
  ]
}
```

Semantics, matching the Elixir solver:

- `weights` — omitted conditions count as weight `0`: not required, not scored.
- `target` / `responses` — omitted conditions are *missing measurements*, never
  zero brightness. A candidate (or target) missing any weight-positive
  condition is **excluded**.
- `expected.selected_color_id: null` — every candidate excluded, no selection.
- Ties must be bitwise-equal scores; the corpus deliberately includes
  IEEE-symmetric pairs (e.g. candidates at `0.4` and `0.6` around a `0.5`
  target, whose errors are equal in IEEE-754) so the earliest-wins policy is
  exercised rather than floating-point luck.

## How to refresh

When `color_matching` publishes or updates the corpus (viamin/color_matching#111),
refresh the committed mirror while keeping the v1 schema:

```bash
curl -fsSL <corpus URL from color_matching#111> \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Until the upstream corpus lands, the committed fixture encodes the semantics
documented by `ColorMatching.WeightedSquaredError` (including its published
doctest example, expected score `0.205`) so parity is enforced offline. A
refresh that drops tie or exclusion cases fails the integrity test rather than
silently weakening the suite.

The implementation of #39 must surface this consumption path in the top-level
`README.md` (see the *Palette data* section); this document is the source of
truth for the procedure.

## Related contract

The `/api/v1` wire behavior the parity data arrives over is pinned by
`ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift`,
which the generated OpenAPI client migration (#39, viamin/color_matching#110)
must keep green: endpoints, the `printer_profile_id` query parameter, headers,
snake_case envelope decoding, error mapping, and DTO round-tripping through the
offline disk cache (`ProfileColorCache`).
