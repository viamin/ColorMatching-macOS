# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir `WeightedSquaredError`
solver in [`color_matching`](https://github.com/viamin/color_matching); the client
and the server must agree on color selection for a shared palette. The parity
corpus is the executable contract that keeps them in agreement (issue #39,
upstream viamin/color_matching#111).

## Where the corpus lives

- **Corpus:** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
- **Loader/ assertions:** `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
- **Run:** `swift test --filter SolverParityCorpusTests` (from `ColorComposerCore/`)

The corpus is committed JSON, loaded relative to the test file — no package
resource declaration is required.

> **Status:** the corpus committed today is a *seed*, hand-derived from the
> documented `WeightedSquaredError` semantics (the `elixir-doctest` case
> reproduces the Elixir doctest, expected score `0.205`). The canonical corpus
> from viamin/color_matching#111 was not yet published when this seed landed;
> replace the seed with the canonical corpus using the refresh procedure below.

## What the corpus pins

Each case states `weights`, a `target` response vector, named `candidates`
(response vectors; absent key = *missing measurement*, never zero), and the
expected outcome. Selection must match `expected_selection` **exactly**:

- **Scoring** — sum of `weight * (candidate − target)²` over channels with
  `weight > 0` (case `elixir-doctest`).
- **Ties** — equal scores select the *earliest* candidate in input order,
  mirroring the Elixir `best_match` policy (cases `tie-earliest-candidate-wins`,
  `tie-three-way-earliest-wins`; tie values are binary-exact so equality is
  deterministic).
- **Exclusions** — a candidate (or target) missing a measurement for any
  `weight > 0` channel is excluded, even when closer on the channels it has;
  when *every* candidate is excluded the cell stays unmatched
  (`expected_selection: null`), never an arbitrary fallback
  (cases `missing-measurement-excluded`, `all-candidates-excluded-unmatched`).
- **Weight handling** — zero-weight channels are neither scored nor required
  (`zero-weight-channel-not-required`), and weight ratios flip selection
  (`weights-flip-selection-heavy-white` / `-heavy-red`).

The corpus must retain at least one case for each tag in `doctest`, `tie`,
`exclusion`, and `weights`, and at least the seed's nine cases — the loader
enforces this coverage, so a refresh that drops a pinned behavior fails loudly.

## Format

```json
{
  "version": 1,
  "source": "seed",
  "upstream": "viamin/color_matching#111",
  "cases": [
    {
      "id": "case-id",
      "description": "what behavior this case pins",
      "tags": ["tie"],
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "target": { "red": 0.2, "green": 0.7 },
      "candidates": [
        { "name": "candidate-a", "responses": { "red": 0.1, "green": 0.4 } }
      ],
      "expected_selection": "candidate-a",
      "expected_score": 0.205,
      "expected_excluded": []
    }
  ]
}
```

- Light-source keys must be canonical `LightingCondition` raw values
  (`white`, `red`, `green`, `blue`, `lps`); anything else fails the test run.
- `expected_selection: null` means the case must produce an unmatched cell.
- `expected_score` (optional) is compared with `1e-9` tolerance.
- `expected_excluded` (optional) lists candidates that must be excluded.

## Refreshing from the upstream corpus

1. Wait for / locate the parity corpus published by viamin/color_matching#111.
2. Copy it to
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`,
   preserving `version` (bump when the format changes), `upstream`, and the
   per-case `tags` — the loader requires tag coverage.
3. Run `swift test --filter SolverParityCorpusTests`. Any selection mismatch is
   a solver-semantics divergence between this app and the Elixir backend —
   treat it as a bug, not as a corpus update.

## Implementation-run notes (issue #39)

Deferred from the tests-only phase and landing with the implementation run:

- The generated OpenAPI client (`swift-openapi-generator` +
  `swift-openapi-runtime` in `ColorComposerCore/Package.swift`, guarded by
  `OpenAPIClientMigrationTests`) and the `PaletteAPIClient` migration onto it
  (wire contract pinned by `PaletteAPIClientContractTests`).
- A link to this document from the top-level `README.md`.
- Promoting `SolverParityCorpusTests` to a dedicated SPM test target, if
  desired, once `Package.swift` is editable.
