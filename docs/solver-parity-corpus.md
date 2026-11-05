# Solver parity corpus

`ColorComposerCoreTests/SolverParityCorpusTests.swift` replays the committed
`ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json` fixture against both
`WeightedSquaredErrorScorer` and the default `CompositionSolver` path.

The fixture is copied verbatim from
[`viamin/color_matching`'s `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
Its SHA-256 at import is
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

To refresh it after the backend deliberately changes the solver contract:

1. Run `mix parity.generate --check` in `viamin/color_matching` and review the
   corresponding `algorithm_version` change.
2. Copy `priv/parity/v<algorithm_version>/corpus.json` into
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v<algorithm_version>/`.
3. Update the corpus test's supported `algorithmVersion`, then run
   `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

The main README should link to this note when the implementation phase lifts
the tests-only file restriction.

# Acceptance-criterion verification plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client migrates palette requests | Focused mocked-transport tests assert generated-operation request/response mapping. | Implementation |
| Server/profile cache and offline-stale fallback remain intact | Existing `ProfileColorCacheTests` plus an app-model integration test of cached-profile fallback and badge state. | Implementation |
| Solver parity corpus matches exactly, including ties | `SolverParityCorpusTests` replays every committed v1 scenario through the scorer and one-cell default solver. | This phase |
| Corpus consumption is documented | This maintained corpus note; add the README link in implementation phase. | This phase |
| PR records migration and parity findings | PR body with generated-client notes, API-shape diff, and test evidence. | Implementation |
