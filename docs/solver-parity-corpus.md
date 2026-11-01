# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`
loads `Fixtures/weighted_squared_error_parity.json` and runs every case through
the default `CompositionSolver` path. It asserts the selected palette ID,
excluded-candidate count, and weighted error exactly. The fixture includes the
contract-sensitive cases: earliest-candidate ties, missing required responses,
and zero-weight channels.

The canonical corpus is owned by
[`viamin/color_matching#111`](https://github.com/viamin/color_matching/pull/111).
When that change is available to this repository, replace the fixture contents
without changing its schema, then run:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

Do not generate expected selections in Swift while refreshing the fixture: the
committed expected values must remain data produced by `color_matching`, so the
test detects solver drift rather than restating the implementation.
