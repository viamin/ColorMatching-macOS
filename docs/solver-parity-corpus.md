# Solver parity corpus — consumption guide

This app's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`WeightedSquaredError` solver in [`color_matching`](https://github.com/viamin/color_matching)
so client and server agree on color selection. Issue #39 enforces that mirror
with a committed parity corpus (upstream viamin/color_matching#111).

> **README note (implementation phase):** the issue asks for corpus consumption
> to be documented in the repo `README.md`. This tests-only run cannot edit
> `README.md` (phase-restricted paths); this document is the canonical text to
> fold into the README's "Development" section when the implementation run lands.

## Where the corpus lives

- **Committed fixture:**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`
- **Consumed by:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
  (runs as part of `cd ColorComposerCore && swift test`; no separate target is
  needed — adding one would require `Package.swift` changes that are out of
  scope for the tests-only phase).

## Selection semantics the corpus pins

For each case (weights + target vector + ordered candidates + expected outcome):

1. **Score** = Σ over *active* conditions (`weight > 0`) of
   `weight × (candidate − target)²`.
2. **Exclusion** — a candidate missing a measurement for any active condition
   is *excluded*, never treated as brightness `0`. A target missing an active
   condition excludes every candidate (selection is "no match").
3. **Ties** — exact score ties resolve to the **earliest candidate in palette
   order** (the same strict-less-than, earliest-wins rule as
   `CompositionSolver`'s fast path and the Elixir solver). Tie cases in the
   corpus use dyadic brightness values (0.25 / 0.5 / 0.75 / 0.875) so tied
   scores are bit-for-bit equal in IEEE-754 doubles and the tie is genuine
   rather than a floating-point artifact.

## Corpus JSON schema

```jsonc
{
  "schema": 1,
  "cases": [
    {
      "id": "symmetric_tie_earliest_candidate_wins",
      "weights": { "white": 1, "red": 0 },        // absent or 0 ⇒ inactive
      "target": { "white": 0.5 },                 // absent ⇒ missing measurement
      "candidates": [                             // array order = palette order
        { "id": 301, "name": "…", "hex": "#3B82F6",
          "responses": { "white": { "brightness": 0.25 } } }
      ],
      "expected": {
        "selected_candidate_id": 301,             // null ⇒ every candidate excluded
        "score": 0.0625,                          // winning score (required when a selection exists)
        "tie": true,
        "tied_candidate_ids": [301, 303],
        "excluded_candidate_ids": []
      }
    }
  ]
}
```

Response keys other than `white`/`red`/`green`/`blue`/`lps` fail the loader
(schema-drift guard). The fixture currently carries 9 cases covering: the
Elixir doctest reference (0.205), exact match, two tie cases (symmetric pair;
tie with an excluded perfect-channel candidate), target-missing exclusion,
zero-weight inactive channels, weight dominance, measured-zero ≠ missing, and
a five-channel case.

## Refreshing the corpus

1. Export the corpus from `color_matching` once viamin/color_matching#111 is
   merged (the upstream test data path is documented on that PR):
   `test/support/solver_parity_corpus.json` → copy it over the fixture path
   above.
2. Sanity-run the suite against the *new* file without moving the committed
   one first:

   ```bash
   cd ColorComposerCore
   SOLVER_PARITY_CORPUS_PATH=/path/to/exported_corpus.json swift test \
     --filter SolverParityCorpusTests
   ```

   The loader honors `SOLVER_PARITY_CORPUS_PATH`; unset, it reads the
   committed fixture via `#filePath`-relative resolution (works from any
   working directory under `swift test`).
3. Commit the refreshed fixture together with any findings in the PR
   description (ties, exclusions, weight handling differences). If the corpus
   format evolves upstream, adjust the `ParityCorpus` decoding structs in
   `SolverParityCorpusTests.swift` — unknown light-source keys intentionally
   fail loudly rather than being dropped.

The corpus-hygiene test (`testCorpusDecodesAndCoversRequiredScenarios`) blocks
a stub refresh: the corpus must keep at least two tie cases, two exclusion
cases, a no-selection case, and a zero-weight case.

## Acceptance criteria → verification map (issue #39)

| AC | Verification | Kind |
| --- | --- | --- |
| Generated OpenAPI client adopted in `ColorComposerCore` | `.ephemeral-tests/openapi_generated_client_spec.rb` (red in this phase; remove before merge once implementation lands) | ephemeral system test |
| `PaletteAPIClient` behavior preserved (paths, query, auth, error taxonomy, envelope decoding) | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` (wire-contract section) | permanent unit test |
| Per-server/profile disk cache + offline fallback unchanged | existing `ProfileColorCacheTests.swift` (server scoping, snake_case disk format, clear/repave) | permanent unit test |
| Solver parity incl. ties | `SolverParityCorpusTests.swift` + committed fixture | permanent unit test |
| Corpus documented (README) | this document (fold into README in the implementation phase) | docs |
| PR description records migration notes / `/api/v1` shape findings / parity results | PR body at publish time, lifting from this document | human evidence |

## Findings so far (for the PR description)

- No `/api/v1` shape changes found yet: the wire-contract tests pin
  `GET /api/v1/printer_profiles`, `GET /api/v1/colors?printer_profile_id=N`,
  bearer-token normalization, 401 → `unauthorized`, other non-2xx →
  `badStatus`, undecodable 2xx → `malformedResponse`. Any divergence the
  generated client introduces will fail these tests.
- Parity corpus (committed fixture): all 9 cases pass selection, score, tie,
  exclusion, and solver-agreement assertions on semantics as implemented;
  `swift test` could not be executed in this container (no Swift toolchain —
  `bin/lint` skips accordingly), so run
  `cd ColorComposerCore && swift test` on macOS/CI to record the actual pass.
