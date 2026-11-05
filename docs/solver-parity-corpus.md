# Solver parity corpus

ColorComposerCoreTests replays the committed v1 fixture at
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json
through WeightedSquaredErrorScorer.

The fixture is sourced unchanged from
[viamin/color_matching's priv/parity/v1/corpus.json](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
It asserts every candidate score, missing-measurement exclusion, winning
selection, and earliest-index tie evidence.

To refresh it after an upstream corpus release:

1. Run mix parity.generate --check in the color_matching repository.
2. Copy the published versioned corpus into this fixture path.
3. Run cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests.

Do not overwrite a v1 fixture with a new algorithm_version; commit the new
version beside it and update the test deliberately so solver changes remain
reviewable.
