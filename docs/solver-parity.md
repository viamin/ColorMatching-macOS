# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
is the committed v1 corpus shared with the
[`color_matching`](https://github.com/viamin/color_matching) backend. The
permanent `SolverParityCorpusTests` test replays every scenario through the
macOS weighted scorer and `CompositionSolver`, checking each candidate score,
selection, error, exclusion, and earliest-index tie result.

Refresh the fixture only together with an intentional backend scorer contract
change:

1. In the backend repository, run `mix parity.generate` and commit the
   resulting `priv/parity/v1/corpus.json`.
2. Copy that committed file byte-for-byte into the fixture path above.
3. Run `cd ColorComposerCore && swift test` and review all selection changes,
   particularly ties, excluded vectors, and zero/unknown weight handling.

The current fixture was imported from backend commit `47057afd58f7d46b4b4b740ca7d2d08947774471`,
which contains the corpus introduced by viamin/color_matching#111.

# Issue 39 verification plan

| Criterion | Verification | Phase status |
| --- | --- | --- |
| Generated typed API client | `GeneratedOpenAPIClientPackageTests` asserts the package declares the runtime and generator products; focused HTTP tests verify the public client contract. | Red: dependencies are not yet declared. |
| Disk cache and offline fallback | Existing `ProfileColorCacheTests` plus `PaletteAPIClientTests`; implementation run must run the focused suite after the migration. | Not run in this test-writing phase. |
| Solver parity | `SolverParityCorpusTests` permanently replays the committed backend corpus, including scores, exclusions, selection and ties. | To run after compiling the new tests. |
| README corpus instructions | Human inspection of README's new corpus location and refresh steps. | Deferred: this test-writing phase only permits `docs/` documentation changes. |
| PR migration notes and parity findings | Inspectable PR description, including API shape comparison and the test result. | Requires PR creation; not available in this local run. |
