# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json` is a vendored copy of the server's deterministic solver corpus from [`viamin/color_matching`](https://github.com/viamin/color_matching), `priv/parity/v1/corpus.json`.

`WeightedSquaredErrorParityTests` decodes every scenario, compares every candidate score (including exclusions), and verifies earliest-index selection and tie indices. It also exercises the one-cell `CompositionSolver` path when the corpus target has all required measurements.

To refresh the fixture after a server-side solver change:

1. In `viamin/color_matching`, run `mix parity.generate` and commit the resulting `priv/parity/v<algorithm_version>/corpus.json`.
2. Copy that committed file into `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v<algorithm_version>.json`.
3. Update the parity test's expected algorithm version and run `swift test` from `ColorComposerCore`.

The fixture must be updated only with a committed server corpus. Changes to selection semantics, missing-value exclusions, or weights require reviewing the server corpus and macOS parity result together.
