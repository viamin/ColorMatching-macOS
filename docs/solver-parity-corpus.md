# Solver parity corpus

`WeightedSquaredErrorParityTests` replays the committed v1 corpus from
`viamin/color_matching` at
`priv/parity/v1/corpus.json`. The fixture is copied into
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/` (with normalized
JSON formatting) so parity tests do not require network access.

To refresh it after the server changes the corpus:

```bash
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json
```

Review the corpus `algorithm_version`, then run `swift test` from
`ColorComposerCore`. A changed algorithm version must be accompanied by
intentional solver compatibility work before the fixture is updated.
