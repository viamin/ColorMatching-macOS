# Solver parity corpus

The permanent solver-parity test is `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift`.
It replays the committed v1 fixture at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`, sourced from `viamin/color_matching` at `priv/parity/v1/corpus.json`.

To refresh it after the backend publishes a new corpus version, copy the upstream committed JSON into a versioned fixture name, update the test to assert the new `algorithm_version`, and run `cd ColorComposerCore && swift test`. Review every changed scenario: the corpus locks score values, missing-positive-channel exclusions, zero-weight handling, and earliest-index tie selection.
