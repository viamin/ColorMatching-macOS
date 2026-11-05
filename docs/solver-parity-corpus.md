# Solver parity corpus

`ColorComposerCoreTests/Fixtures/weighted-squared-error-parity-v1.json` is a committed projection of the upstream [`color_matching` v1 corpus](https://github.com/viamin/color_matching/blob/47057afd58f7d46b4d4b740ca7d2d08947774471/priv/parity/v1/corpus.json). `WeightedSquaredErrorParityTests` replays every scenario through the app scorer and solver, including ties, exclusions, and channel weights.

When upstream publishes a new algorithm version, copy its `priv/parity/vN/corpus.json` into the fixture, retain the source commit URL, and update the expected algorithm version in the test. Run `cd ColorComposerCore && swift test` before committing the refresh.
