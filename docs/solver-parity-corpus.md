# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[viamin/color_matching](https://github.com/viamin/color_matching). The parity
corpus is the executable statement of that contract: expected **selections**
(highest-priority), **scores**, **ties**, and **exclusions** for a fixed set
of inputs, produced by the Elixir solver. The Swift scorer must reproduce
them exactly.

## Where the corpus lives

- Fixture: `ColorComposerCore/Tests/Fixtures/solver_parity_corpus.json`
- Tests: `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
- Run from `ColorComposerCore/`:

  ```bash
  swift test --filter SolverParityCorpus
  ```

The fixture sits outside the `ColorComposerCoreTests` directory on purpose:
SwiftPM only compiles the test target's own folder, so a fixture kept in
`Tests/Fixtures/` is visible to the tests (they locate it relative to
`#filePath`) without needing a `resources:` declaration in `Package.swift`.

The README (root `README.md`) links to this document from the architecture
section describing the scorer.

## Corpus format

```json
{
  "version": 1,
  "scorer": "weighted_squared_error",
  "generator": "…provenance…",
  "case_count": 10,
  "cases": [
    {
      "id": "kebab-case-identifier",
      "description": "…",
      "tags": ["tie" | "exclusion" | "weight-handling" | "nearest" | "doctest"],
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "target": { "red": 0.5, "green": 0.5 },
      "candidates": [
        { "id": 40, "hex": "#0a0000", "responses": { "red": 0.5 } }
      ],
      "expected_selection": 41,
      "expected_score": 0.02,
      "expected_excluded_ids": [40]
    }
  ]
}
```

Semantics the expectations encode (matching the Elixir solver):

- Score = `Σ weight_c · (candidate_c − target_c)²` over channels with
  `weight > 0`.
- A candidate — or the target — missing a measurement for any channel with
  `weight > 0` **excludes** the candidate; missing is never zero brightness.
  When the target itself lacks a required channel, every candidate is
  excluded and `expected_selection` is `null`.
- Channels with weight `0` are fully inactive: they score nothing and their
  absence excludes nobody.
- Lowest score wins; on an **exact tie** the earliest candidate in input
  order wins (mirroring `IlluminantMatching.best_match/4`). Tie-tagged cases
  use exact binary-fraction values so ties are bitwise in IEEE 754 and the
  earliest-wins rule is genuinely exercised.

Channel keys are the canonical API `light_source` strings (`white`, `red`,
`green`, `blue`, `lps`); the loader rejects anything else.

## Refreshing the corpus

The corpus generator is viamin/color_matching#111. When an updated corpus is
published there:

1. Export the corpus JSON in the schema above (the Elixir solver computes
   `expected_*` values — never derive expectations from this Swift
   implementation, that would be circular).
2. Overwrite `ColorComposerCore/Tests/Fixtures/solver_parity_corpus.json`.
3. Run `swift test --filter SolverParityCorpus` — all cases must pass; any
   divergence is a parity bug in one of the two solvers and blocks the release.

Until #111 publishes, the committed fixture is a **seed corpus**: 10 cases
hand-derived from the documented `WeightedSquaredError` semantics and the
Elixir doctest vector (score `0.205`), covering doctest, nearest, tie (×3),
exclusion (×3), and weight-handling (×3) tags. It is a placeholder for —
not a substitute for — the generated corpus, and is expected to be replaced
wholesale by the upstream artifact.

## Related

- `PaletteAPIClientContractTests` pins the `/api/v1` HTTP contract that the
  generated OpenAPI client migration (swift-openapi-generator /
  swift-openapi-runtime, from viamin/color_matching#110) must preserve.
- `OpenAPIClientMigrationTests` asserts the structural side of that
  migration: manifest dependencies, the OpenAPI generator build plugin, and
  the committed OpenAPI document.
