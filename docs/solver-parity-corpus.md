# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver and the `earliest-index-wins`
selection of `ColorMatching.IlluminantMatching` so the macOS client and the
`color_matching` server agree on color selection. The parity corpus turns that
intent into an enforced contract.

## Where the corpus lives

The corpus is the golden-vector fixture generated upstream by
`mix parity.generate` (viamin/color_matching#111) and committed **verbatim** at:

```
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

- Upstream source of truth: `priv/parity/v1/corpus.json` in `viamin/color_matching`
- Committed bytes: sha256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604` (23,995 bytes)

The corpus is stamped with `algorithm_version` (currently `1`). When that
number changes upstream, every expectation has moved: refresh the fixture and
the version pin in `SolverParityCorpusTests` in the same change.

## How to refresh

```sh
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

(or run `mix parity.generate` in a `color_matching` checkout and copy
`priv/parity/v1/corpus.json`). Upstream CI verifies regeneration is
byte-identical (`mix parity.generate --check`), so the file is deterministic —
a diff after refresh means real algorithm drift, review it before committing.

## What the parity test enforces

`SolverParityCorpusTests` (`swift test`) loads the fixture and:

1. **Metadata** — pins `algorithm_version`, `scorer`, `selection`,
   `missing_policy`, and `light_sources`, and requires the corpus to keep
   covering ties, exclusions, and an all-excluded scenario.
2. **Scorer replay** — per the upstream consumption recipe: scores every
   palette color against the target with the scenario's weights and asserts
   exact agreement with the recorded per-candidate score table (`"excluded"`
   markers included), the expected selection, the winner's error, `tied_indices`,
   and `tie_broke` (`null` when nothing was selected). Unknown weight keys
   (e.g. `ultraviolet`) are dropped, matching `PaletteColorDTO.toDomain`.
3. **Solver replay** — drives the production `CompositionSolver` on a 1×1 grid
   per scenario and asserts the same selection and error flow through the real
   earliest-wins path. Scenarios whose *target* omits an active channel cannot
   be expressed as grids and are covered by the scorer replay only.

## README note

This document is the canonical corpus-consumption reference; the top-level
README links here (section added alongside the generated-client migration in
issue #39).
