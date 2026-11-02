# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is the committed golden-vector contract for `WeightedSquaredErrorScorer`.
It is copied byte-for-byte from the `color_matching` server repository at
`priv/parity/v1/corpus.json`; the initial import came from revision
`47057afd58f7d46b4d4b740ca7d2d08947774471` and has SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

`WeightedSquaredErrorParityTests` decodes the fixture and asserts every
candidate score, exclusion, selected palette index and color, selected error,
and earliest-index tie result. The fixture deliberately includes all-excluded
and missing-target cases, exact ties, zero-weight missing channels, unknown
weights, and LPS-only matching.

## Refreshing the fixture

1. In a checkout of `viamin/color_matching`, run `mix parity.generate --check`.
   If the server solver intentionally changed, run `mix parity.generate` and
   review the generated `priv/parity/v1/corpus.json` plus its
   `algorithm_version`.
2. Copy that file exactly to
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.
   Do not hand-edit expectations.
3. Update the source revision and SHA-256 above, then run
   `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests`.
4. Review failures as solver-contract changes: weights, missing-channel
   exclusions, and tie ordering are all part of the shared behavior.

The server fixture is produced by `mix parity.generate`; this client does not
regenerate it locally because Elixir is the contract authority.
