# Solver parity corpus

The Swift parity harness is `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`.
It loads the committed fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
and asserts the exact `CompositionSolver` selection and score for every case.

The authoritative source is `viamin/color_matching` PR #111. Refresh the
fixture by copying the upstream corpus without changing its values or case
ordering, then run:

```bash
cd ColorComposerCore
swift test --filter SolverParityCorpusTests
```

Keep tie cases, excluded candidates, and zero/non-zero weight cases in the
fixture: they are semantic compatibility requirements, not implementation
details. The fixture currently records bootstrap cases because upstream PR #111
was not accessible from this test-authoring environment; replace it with the
published artifact before the implementation PR is merged.
