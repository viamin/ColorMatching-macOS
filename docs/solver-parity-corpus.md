# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver so the macOS client and the
`color_matching` server agree on palette-color selection. The **solver parity
corpus** is the committed, executable proof of that parity: a set of expected
selections produced from the server's semantics, replayed against the Swift
scorer on every `swift test` run.

> Enforced by `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTestFixtures/solver_parity/
└── *.json   # one or more corpus files, all loaded (sorted by filename)
```

Every `*.json` file in that directory is loaded and executed — drop in an
additional corpus file and it is consumed with no test changes. The committed
`weighted-squared-error-seed.json` is a seed corpus hand-derived from the
documented Elixir semantics (the `WeightedSquaredError` doctest, the
missing-measurement exclusion policy, and the `IlluminantMatching.best_match/4`
earliest-wins tie policy). It is replaced by — or joined by — the corpus
generated upstream in
[viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111)
once that lands.

## Format (`color-matching-solver-parity/1`)

```json
{
  "format": "color-matching-solver-parity/1",
  "provenance": { "generator": "...", "source": "...", "note": "..." },
  "cases": [
    {
      "id": "tie-selects-earliest-palette-entry",
      "description": "…",
      "weights": { "white": 1.0, "red": 0.0, "green": 0.0, "blue": 0.0, "lps": 0.0 },
      "palette": [
        { "id": 301, "name": "Tied First", "hex": "#807060",
          "responses": { "white": 0.5 } }
      ],
      "target": { "white": 0.4 },
      "expected": { "selected_id": 301, "score": 0.01, "tied_ids": [301, 302] }
    }
  ]
}
```

Rules:

- **Light-source keys** are the canonical `color_matching` strings — `white`,
  `red`, `green`, `blue`, `lps`. Unknown keys fail the run (corpus bug).
- **`weights`** map light sources to numbers; omitted/zero means the channel
  is inactive. At least one weight `> 0` is required.
- **`responses`** map light sources to normalized brightness (`0.0…1.0`).
  An **omitted** key means *unmeasured* — never zero. Measured `0.0` is a
  real, selectable value.
- **`target`** is the requested brightness per light source (a 1×1 source
  grid per active channel). Every active channel must be present.
- **`expected.selected_id`** is the id of the palette entry the Elixir solver
  selected. **`expected.score`** (optional) is the winner's weighted squared
  error, asserted within `1e-9`. **`expected.tied_ids`** (optional) declares a
  tie set: all tied candidates must score identically (`1e-12`) and the
  **earliest palette entry** in the tie must win. **`expected.unmatched`**
  (`true`) asserts every candidate was excluded.
- **Palette order is significant**: it is the tie-break order.

## What the harness asserts

For each case the harness builds `PaletteColor`s in corpus order, drives
`CompositionSolver` (with `WeightedSquaredErrorScorer`) on a 1×1 grid per
active channel — exactly the production solve path — and asserts:

1. the selected palette id equals `expected.selected_id` (or the cell is
   unmatched when `expected.unmatched` is `true`),
2. the winner's error equals `expected.score` when provided,
3. declared ties score identically and resolve to the earliest palette entry,
4. corpus schema violations (unknown light sources, missing active target
   channels, malformed hex, no active weight, empty palette) fail loudly.

## Refreshing the corpus

The corpus is **generated, not hand-maintained**. To refresh it from the
upstream parity generator (viamin/color_matching#111):

1. In a checkout of `color_matching`, run the parity corpus generator for
   `WeightedSquaredError` (see that PR for the exact mix task/script).
2. Convert (or configure) the output to the
   `color-matching-solver-parity/1` format above — one JSON document whose
   `provenance.source` names the upstream commit/task that produced it.
3. Commit the file as
   `ColorComposerCore/Tests/ColorComposerCoreTestFixtures/solver_parity/weighted-squared-error.json`
   (replacing the seed file, or alongside it), and run:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityCorpusTests
   ```

Any mismatch — including ties breaking differently or an exclusion treated as
zero brightness — fails the suite with the case id in the failure message.

The README should link to this document from the *Palette data* section when
the corpus is refreshed upstream.
