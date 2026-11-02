# Issue #39 verification plan

| Criterion | Smallest credible verification | Evidence status in this tests-only change |
| --- | --- | --- |
| Typed OpenAPI client replaces hand-written wire decoding | Inspect `Package.swift`, generated sources, and the `PaletteAPIClient` adapter in the implementation PR; exercise existing request tests against the generated adapter | Not runnable until implementation adds the generated client |
| Per-server/profile cache, offline-stale badge, and cached-profile fallback remain intact | Existing focused `ProfileColorCacheTests` cover server/profile isolation and disk round trips; the implementation PR must add an adapter-level fallback test if its cache boundary changes | Existing unit coverage; adapter inspection pending |
| Solver selections match the parity corpus | Permanent fixture-driven `SolverParityCorpusTests` executes every committed corpus case, including ties, active-channel exclusions, and weights | Runnable now |
| Corpus consumption is documented | README review links the committed fixture to upstream issue #111 and gives the refresh procedure | Runnable now |
| PR describes migration notes, API shape changes, and parity findings | Inspect the PR body before merge | Human/external evidence required |

The canonical upstream corpus is owned by `viamin/color_matching#111`. This repository vendors a JSON copy under the core test fixtures so CI does not need network access. Refreshes must preserve upstream provenance and add every upstream case before updating the fixture's source revision metadata.

## README wording for the implementation change

Add a "Solver parity corpus" section to `README.md` naming
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`, linking it to `viamin/color_matching#111`, and explaining that
`SolverParityCorpusTests` checks exact selections including ties, exclusions,
and weights. The refresh command is:

```bash
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```
