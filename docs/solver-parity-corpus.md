# Solver parity corpus

`WeightedSquaredErrorScorer` in `ColorComposerCore` deliberately mirrors
`ColorMatching.WeightedSquaredError` in the Elixir
[`color_matching`](https://github.com/viamin/color_matching) service so the
client and the server agree on color selection. The parity corpus makes that
mirror an enforced contract instead of a comment.

## Where the corpus lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
```

The test harness (`SolverParityCorpusTests.swift` in the same directory tree)
resolves the file relative to its own source via `#filePath`, so a plain
checkout — `swift test` from `ColorComposerCore/`, or CI — reads it without any
resource-bundling step.

## What the harness asserts

For every `selection`-scope case the harness builds a one-cell composition
whose per-condition source values are the case's target vector, then asserts
through `CompositionSolver` (production scorer + fast path + tie-breaking):

- the selected color id matches `expected.selected_color_id` exactly
  (`null` means the cell must stay unmatched);
- the solver error and a direct `WeightedSquaredErrorScorer` score both equal
- `expected.score` within `tolerance`;
- exactly the colors listed in `excluded_color_ids` come back `.excluded` —
  missing a required measurement excludes, a *measured* zero does not;
- on `tie` cases every tied color shares the winning score and the winner is
  the tied color appearing **earliest in palette order** (the
  `IlluminantMatching.best_match/4` policy) — palette ids are deliberately
  non-monotonic in tie cases so id-ordering cannot masquerade as the policy.

`scorer_only`-scope cases (a target that itself lacks a required condition —
inexpressible through solver grids) are asserted against the scorer directly.

The harness also self-checks the corpus: it fails on an unsupported
`schema_version`, on duplicate case ids, and when any required category is
missing (`exact_match`, `weighting`, `tie`, `exclusion_candidate_missing`,
`exclusion_all`, `exclusion_target_missing`, `zero_weight_optional`,
`multi_channel`) — an empty or degraded corpus can never pass silently.

## Corpus format

```json
{
  "schema_version": 1,
  "tolerance": 1e-09,
  "cases": [
    {
      "id": "tie-symmetric-distinct-vectors",
      "category": "tie",
      "description": "…",
      "scope": "selection",              // or "scorer_only"; default "selection"
      "weights": { "red": 1.0 },         // omitted keys weigh 0 (inactive)
      "target": { "red": 0.5 },          // omitted keys are missing (not zero)
      "palette": [
        { "id": 410, "hex": "#661f1f", "name": "…", "responses": { "red": 0.4 } }
      ],
      "expected": {
        "selected_color_id": 410,        // null → nothing selectable
        "score": 0.01,                   // null only when nothing is selected
        "excluded_color_ids": [],
        "tie": true,
        "tied_color_ids": [410, 305]     // required when tie is true
      }
    }
  ]
}
```

Condition keys are the canonical `color_matching` light-source strings (`white`, `red`,
`green`, `blue`, `lps`); unknown keys fail the run rather than being ignored.

## Refreshing from upstream

The committed file is currently a **seed corpus**: expected outputs are
hand-computed from the documented `WeightedSquaredError` semantics (including
the Elixir doctest example, 0.205) and were cross-checked against an
independent re-implementation of those semantics before commit.

When the generated corpus from viamin/color_matching#111 lands:

1. Replace the fixture file in place (same path, same name).
2. Keep `schema_version` aligned: if the generated format differs, extend the
   harness decodables and bump `supportedSchemaVersion` in
   `SolverParityCorpusTests.swift` in the same change — the schema check
   exists so a changed format can never silently mis-decode.
3. Confirm the required categories are still represented (the category
   coverage test names anything missing).
4. Run `cd ColorComposerCore && swift test` — any selection that disagrees
   with the Elixir-generated expectation fails the parity run.

## `/api/v1` wire contract notes (issue #39)

`PaletteAPIWireContractTests.swift` pins the HTTP surface
`PaletteAPIClient` consumes so the migration to the generated OpenAPI client
(swift-openapi-generator + swift-openapi-runtime, from the spec published in
viamin/color_matching#110) is verified behavior-preserving. Shape facts any
migration must preserve:

- `GET /api/v1/printer_profiles` → `{"printer_profiles": [...]}`; profile
  fields `printer_make_model`, `paper_type`, `ink_type` are nullable.
- `GET /api/v1/colors?printer_profile_id=N` →
  `{"colors": [...], "printer_profile": {...}|null}` — the envelope profile is
  optional and observed as `null` in practice.
- Color/response keys are snake_case on the wire (`palette_id`, `sort_order`,
  `apparent_brightness`, `raw_value`, `raw_unit`, `measured_at`,
  `test_run_id`); `responses` is a map keyed by light-source string; `rgb`
  may be `null` (hex fallback).
- Requests carry `Accept: application/json` and a `Authorization: Bearer`
  header only when a usable (non-empty, trimmed) token exists.
- Status mapping: 401 → `.unauthorized` (re-auth flow), other non-2xx →
  `.badStatus(code)`, undecodable 2xx body → `.malformedResponse`;
  `testConnection` accepts any 2xx including bodyless 204.
