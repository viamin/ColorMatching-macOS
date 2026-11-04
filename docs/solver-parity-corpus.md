# Solver parity corpus

`ColorComposerCore` consumes the versioned golden vectors published by the
backend at
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
The committed copy lives at
`ColorComposerCore/Tests/SolverParityTests/Resources/ParityCorpus/v1/corpus.json`
and is exercised by `SolverParityCorpusTests`.

When the backend intentionally changes the solver, regenerate its corpus with
`mix parity.generate`, review the algorithm-version change and resulting
selection/tie/exclusion differences, then refresh the committed copy:

```bash
curl --fail --location https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json -o ColorComposerCore/Tests/SolverParityTests/Resources/ParityCorpus/v1/corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Do not refresh the fixture without the backend corpus's version bump or a
documented parity review. The test asserts each candidate score, expected
selection, selected color, error, and earliest-wins tie set.
