# Issue #39 verification plan

This tests-only change maps each acceptance criterion to evidence required in
the implementation PR. It intentionally leaves the generated-client manifest
test red until the implementation phase adds the dependencies and generated
client.

| Criterion | Smallest credible verification | Evidence at this head |
| --- | --- | --- |
| Typed OpenAPI client replaces the handwritten API transport | Focused package-manifest contract test, then API-client request/response tests against the generated operations | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientDependencyTests.swift` (expected red) |
| Per-server/profile cache, offline-stale badge, and cached-profile fallback remain unchanged | Permanent integration coverage in the app target with an unreachable server and pre-seeded cache | Existing cache unit coverage: `ProfileColorCacheTests`; app-flow coverage must be added in implementation phase |
| Solver choices exactly match the corpus, including ties | Permanent corpus-driven solver test | `SolverParityCorpusTests.swift` and `Fixtures/weighted_squared_error_parity_corpus.json` |
| Corpus consumption is documented | Inspectable README section naming upstream corpus location and refresh command/process | Not yet permitted in this tests-only phase; implementation phase must update `README.md` |
| PR records migration and parity findings | Human-inspectable PR description | Not created in this run; no push/PR authority was requested |

## Corpus refresh

The fixture lives at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`.
During implementation, replace it with the committed corpus from
`viamin/color_matching#111` and preserve the JSON schema consumed by
`SolverParityCorpusTests`. Review the resulting cases for tie ordering,
missing-measurement exclusions, and zero/non-zero channel weights before
updating expected results.
