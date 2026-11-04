# Issue #39 acceptance verification plan

This red-phase change establishes the executable and inspectable evidence that
the implementation phase must satisfy.

| Criterion | Verification | Evidence to record after implementation |
| --- | --- | --- |
| Generated OpenAPI client serves the existing palette/profile workflow | Focused `PaletteAPIClient` unit tests with a mocked HTTP transport, exercising profile and color requests, authentication, and API envelopes | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` test results plus review of generated sources and `Package.swift` dependencies |
| Per-server/profile disk caching and offline fallback remain unchanged | Existing focused cache tests and `ColorCatalog` behavior tests; implementation review confirms the generated-client boundary stays inside `PaletteAPIClient` | `ProfileColorCacheTests.swift`, relevant `ColorCatalog` tests, and manual UI inspection of offline-stale badge and cached-profile fallback |
| Solver selections exactly match the server corpus, including ties | Permanent corpus-backed unit test loading the committed v1 fixture and checking selection, minimum error, and all tied indexes for every scenario | `WeightedSquaredErrorParityCorpusTests.swift` result; fixture SHA/source recorded in README |
| Corpus consumption is maintainable | README documents the upstream source, committed fixture path, and explicit refresh procedure | README review |
| PR records migration and parity findings | Human-inspectable PR description | PR body: generated-client migration, API shape changes, and corpus findings for ties, exclusions, and weights |

The permanent corpus test is deliberately at scorer level: the corpus includes a
missing-target case that a pixel grid cannot represent, while
`WeightedSquaredErrorScorer` is the shared contract that must agree with the
Elixir solver.
