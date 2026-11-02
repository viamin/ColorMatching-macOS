# Solver parity corpus

The macOS client deliberately mirrors the `color_matching` Elixir solver
(`ColorMatching.WeightedSquaredError`) so that both sides pick the same palette
color for the same inputs. The parity corpus is the executable proof: a
committed set of inputs and expected selections that the Swift
`WeightedSquaredErrorScorer` (and the `CompositionSolver` selection path) must
reproduce **exactly** — including tie cases, exclusions, and weight handling.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/weighted_squared_error_parity.json
```

It is consumed by
`ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift`
in the ordinary `ColorComposerCoreTests` target:

```bash
cd ColorComposerCore && swift test
```

The tests locate the corpus relative to the test source file, so no bundle
resource wiring is required to run them.

## What the tests enforce

- **Selection parity** — for every case, the argmin of the weighted squared
  error (earliest palette entry wins on ties, matching the Elixir
  `IlluminantMatching.best_match/4` policy) must equal `expected.selected_*`.
- **Score parity** — the selected candidate's score must equal
  `expected.score` within `1e-12`.
- **Exclusion parity** — candidates (or targets) missing a measurement for any
  channel with weight `> 0` are excluded, never treated as zero brightness.
- **Tie parity** — every `tied_ids` member must score equal to the winner, and
  the winner must be the earliest-indexed tied candidate.
- **Solver parity** — a 1×1 `CompositionSolver.solve` per case must land on the
  same selection (this exercises the optimized production fast path), and the
  corpus must keep covering all scenario categories (`nearest`,
  `exact_match`, `tie`, `exclusion`, `zero_weight_channel`,
  `weight_scaling`, `multi_channel`), at least one tie case, one exclusion
  case, and one no-selection case.

## Corpus schema (version 1)

```jsonc
{
  "corpus": "weighted_squared_error",
  "version": 1,
  "cases": [
    {
      "id": "unique-case-id",              // stable; referenced in failure output
      "category": "tie",                   // scenario class (see above)
      "weights": {"red": 1.0, "lps": 1.5}, // per light source; missing/0 = inactive
      "target": {"red": 0.5},              // absent key = no measurement for that channel
      "palette": [
        {
          "index": 0,                      // must equal array position (earliest-wins depends on order)
          "id": 101,                       // stable color id within the case
          "hex": "#C64A35",                // fallback RGB when "rgb" is absent
          "rgb": {"r": 198, "g": 74, "b": 53},
          "responses": {"red": 0.87}       // absent key = unmeasured, NOT zero
        }
      ],
      "expected": {
        "selected_index": 0,               // palette position that must win
        "selected_id": 101,
        "score": 0.205,                    // winner's weighted squared error
        "excluded_ids": [304],             // candidates that must be excluded
        "tied_ids": [101, 102],            // candidates tying the winner (may be empty)
        "no_selection": false              // true when every candidate is excluded
      }
    }
  ]
}
```

Light-source keys are the canonical `color_matching` `light_source` strings:
`white`, `red`, `green`, `blue`, `lps`. The integrity tests reject any other
key, non-sequential palette indices, duplicate ids, and expectations that do
not address the palette.

## Refreshing the corpus

The corpus originates from the `color_matching` solver parity suite
([viamin/color_matching#111](https://github.com/viamin/color_matching/issues/111)):

1. Generate the export on the Elixir side, e.g.
   `mix parity.export weighted_squared_error` (see the upstream repo for the
   exact task name introduced by #111).
2. Replace
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/weighted_squared_error_parity.json`
   with the exported file. Keep the schema above; if upstream bumps the
   format, update `version` together with the test-local schema in
   `WeightedSquaredErrorParityCorpusTests.swift`.
3. Run `cd ColorComposerCore && swift test`. The parity tests fail with the
   offending case id in the message if the Swift scorer disagrees with any
   expected selection.

Until the upstream export lands, the committed file is a hand-seeded snapshot
of the same algorithm; its expected values were cross-checked against the
documented Elixir semantics (including the `WeightedSquaredError` doctest
score of `0.205`).

## Related: generated OpenAPI client guards

`OpenAPIClientMigrationTests.swift` (same test target) guards the adoption of
the generated OpenAPI client
([viamin/color_matching#110](https://github.com/viamin/color_matching/issues/110)):

- The OpenAPI document consumed by `swift-openapi-generator` must be committed
  under `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/`
  (`openapi.yaml`, `openapi.yml`, or `openapi.json`) and describe
  `GET /api/v1/printer_profiles` and `GET /api/v1/colors`.
- The existing `PaletteAPIClient` behavior the migration must preserve is
  pinned by tests: `/api/v1` URL and query building, `Accept` and
  `Authorization` (Bearer, trimmed; absent when the token is blank) headers,
  401 → `unauthorized`, other non-2xx → `badStatus`, undecodable body →
  `malformedResponse`, and envelope decoding.
- Disk-cache and offline-stale behavior is pinned by the existing
  `ProfileColorCacheTests` suite, which runs unchanged against the migrated
  client.
