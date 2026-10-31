# Solver parity corpus

Issue #39 consumes the deterministic corpus published by `viamin/color_matching`
at `priv/parity/v1/corpus.json`. The copy committed to this repository is
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.

`WeightedSquaredErrorParityTests` decodes every scenario and verifies each
candidate score, missing-measurement exclusion, winning palette index and hex
color, expected error, and the earliest-index tie outcome. The fixture includes
zero-weight and unknown channels so only the five supported lighting conditions
influence the macOS solver.

## Refreshing

1. In `viamin/color_matching`, run `mix parity.generate` and verify it with
   `mix parity.generate --check`.
2. Copy `priv/parity/v1/corpus.json` over the committed fixture above without
   reformatting it.
3. Update the expected `algorithmVersion` assertion when the upstream corpus
   version changes, then run `cd ColorComposerCore && swift test`.

The implementation-phase README update should link here and record the upstream
revision used for each corpus refresh.

