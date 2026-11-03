# Issue #39 verification plan

This test-only change establishes the acceptance checks for adopting the
published `color_matching` OpenAPI client and solver corpus.

| Criterion | Smallest credible verification | Evidence location |
| --- | --- | --- |
| Generated OpenAPI client serves the palette endpoints | Focused HTTP client tests assert the documented profiles and colors request/response contract; implementation review confirms `swift-openapi-generator` and `swift-openapi-runtime` are package dependencies. | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; implementation-phase package diff |
| Per-server/profile disk cache, stale badge, and cached-profile fallback remain intact | Existing focused cache tests cover server-scoped persistence and cache lookup. A UI-level check of stale-badge presentation remains implementation-phase evidence because it is not exercised by the pure Swift package. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; implementation-phase manual evidence |
| Solver results agree with the upstream corpus, including ties | Permanent corpus replay test checks every candidate score and the `CompositionSolver` selected palette position against upstream `priv/parity/v1/corpus.json`. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift` |
| Corpus refresh instructions are available to contributors | README records the pinned upstream path and copy/verification command. | implementation phase: `README.md` |
| PR records endpoint shape changes and parity findings | Inspectable PR description based on the generated-client diff and corpus test output. | implementation phase: PR body |

The v1 fixture was copied verbatim from
`https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`.
It must be refreshed only by replacing the committed fixture with that upstream file,
then running `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests`.
