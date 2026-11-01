# Solver parity corpus

`WeightedSquaredErrorScorer` in `ColorComposerCore` deliberately mirrors the
Elixir `WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching). To keep the two
implementations from drifting, the Elixir project exports a **parity corpus** —
a JSON file of solver inputs and the expected outputs computed by the Elixir
solver — and this repository consumes it as a committed test fixture.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-corpus.json
```

`SolverParityCorpusTests` (same directory) loads the corpus relative to its own
file path, so `swift test` needs no environment setup. If the file is missing
the tests fail with a pointer to this document — the corpus is a required
commit, not a generated artifact.

## Corpus schema (version 1)

```json
{
  "version": 1,
  "source": "viamin/color_matching parity corpus (PR #111)",
  "scorer": "weighted_squared_error",
  "cases": [
    {
      "name": "two equidistant colors tie to the earliest",
      "tags": ["tie"],
      "weights": { "red": 1.0, "green": 1.0 },
      "palette": [
        { "id": 1, "hex": "#aaaaaa", "responses": { "red": { "brightness": 0.5 }, "green": { "brightness": 0.5 } } },
        { "id": 2, "hex": "#bbbbbb", "responses": { "red": { "brightness": 0.5 }, "green": { "brightness": 0.5 } } }
      ],
      "targets": [ { "red": 0.5, "green": 0.5 } ],
      "expected_selection_ids": [1],
      "expected_scores": [0.0]
    }
  ]
}
```

- `weights` — per light source (`white`, `red`, `green`, `blue`, `lps`).
  Absent or zero means the channel is inactive; every case needs at least one
  positive weight.
- `palette` — candidate colors in the order the solver sees them; order
  matters for tie-breaking. `responses` keys are the server's light-source
  strings; a missing key means *unmeasured*, never zero brightness.
- `targets` — one target response vector per solved cell.
- `expected_selection_ids` — the selected palette **id** per target
  (aligned with `targets`). `null` means no candidate was eligible.
- `expected_scores` (optional) — the winning weighted squared error per
  target, compared with `1e-9` tolerance; entries may be `null`.
- `tags` — `"tie"` marks exact-tie cases (the tests then additionally prove a
  genuine tie exists and resolves to the **earliest** tied candidate);
  `"exclusion"` marks cases exercising the missing-measurement exclusion
  policy. The test suite requires at least one of each.

## What the tests assert

- Selections match the corpus exactly, target by target, both via the scorer
  directly and end to end through `CompositionSolver`'s fast path.
- Ties resolve to the earliest candidate in palette order (the
  `IlluminantMatching.best_match/4` policy the solver documents).
- Exclusions are exactly the candidates missing a measurement for a
  positive-weight channel (or when the target itself lacks one) — never
  treated as zero brightness.
- Zero-weight channels never exclude a candidate.

## Refreshing the corpus

The corpus is exported by the upstream Elixir project (see
[viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111)
for the export task and its output location there). To refresh:

1. Export the corpus JSON upstream against the `color_matching` revision you
   care about (the file records its provenance in `source`).
2. Copy it over `Fixtures/solver-parity-corpus.json` verbatim — do not
   hand-edit cases; if a case fails after a refresh, that is a parity bug to
   investigate, not a fixture to adjust.
3. Run the suite:

```bash
cd ColorComposerCore && swift test --filter SolverParityCorpus
```

## Related fixture: the OpenAPI document

`Fixtures/openapi.json` (same directory) vendors the OpenAPI spec published by
[viamin/color_matching#110](https://github.com/viamin/color_matching/pull/110).
`OpenAPIContractTests` checks that the spec's `/api/v1/printer_profiles` and
`/api/v1/colors` shapes still match the wire format
`PaletteAPIClient`/`APIModels.swift` decode, and that the response map accepts
every canonical light source. Refresh it alongside the corpus; the contract
tests will name the exact property whenever the API shape drifts.
