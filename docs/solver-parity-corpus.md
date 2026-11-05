# Solver parity corpus

`ColorComposerCoreTests` replays the upstream `color_matching` weighted-squared-error golden vectors from `Fixtures/weighted_squared_error_v1.json`.

The fixture is copied from `viamin/color_matching` at `priv/parity/v1/corpus.json`. It records each candidate score, exclusion, selected candidate, selection error, and tie evidence. The test intentionally treats those outputs as exact values so solver behavior cannot drift on weighting, exclusions, or earliest-index tie resolution.

To refresh the fixture after the backend changes its algorithm version:

1. In `viamin/color_matching`, run `mix parity.generate` and commit its `priv/parity/v1/corpus.json` output.
2. Copy that committed file to `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.
3. Update the expected `algorithmVersion` in `SolverParityCorpusTests` and run `cd ColorComposerCore && swift test`.

The implementation run must add a concise link to this document in the root README, because this red-phase run is deliberately restricted to test and documentation paths.
