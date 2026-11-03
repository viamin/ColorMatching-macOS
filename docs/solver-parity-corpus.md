# Solver parity corpus

`ColorComposerCoreTests` consumes the server-owned corpus from
`viamin/color_matching` issue #111. The committed copy is
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`.

To refresh it after a server solver change, regenerate the source corpus in
the server repository with `mix parity.generate`, then copy
`priv/parity/v1/corpus.json` into the fixture path above without reformatting.
Run `swift test` from `ColorComposerCore` to replay every vector. The test
checks per-candidate scores, missing-measurement exclusions, exact selected
index and error, and earliest-wins tie evidence.
