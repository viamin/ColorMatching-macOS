# Issue 39 verification plan

This tests-only change establishes the regression contract before the generated-client implementation.

| Criterion | Smallest credible verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client migrates palette/profile requests | Focused transport-decoding tests plus a client integration test against the generated types | Implementation phase |
| Cache remains isolated by server and profile; offline-stale and cached-profile fallback remain intact | Existing ProfileColorCacheTests plus focused PaletteAPIClient fallback tests | Existing permanent tests; rerun in implementation phase |
| Weighted squared-error selection matches the server | Permanent corpus-driven unit test replaying every committed color_matching v1 case through the scorer and representable one-cell solver cases | ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift |
| README describes corpus location and refresh process | Inspectable documentation review | Implementation phase; the tests-only phase may not change the repository-root README |
| PR records generated-client notes, API-shape findings, and parity result details | Inspectable PR description | Implementation phase |

The corpus source is viamin/color_matching issue #111:
priv/parity/v1/corpus.json at commit/blob 70e9999065c81334d1f2b5038a96c67cfd5d59d1.
The local fixture is deliberately committed under the Swift test target so offline
test runs do not depend on GitHub availability.
