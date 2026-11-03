# Issue #39 verification plan

This is the red-phase verification map for adopting the generated OpenAPI
client and the server solver corpus. Tests are committed before the production
migration so they can expose a behavior change.

| Criterion | Smallest credible verification | Test / evidence |
| --- | --- | --- |
| Generated OpenAPI client and committed contract | Focused structural contract test | `OpenAPIClientContractTests`: generator/runtime dependencies, committed document, endpoints, required query parameter |
| Existing palette wire behavior | Focused integration-style unit test with a `URLProtocol` transport double | `PaletteAPIClientContractTests`: paths, bearer token, response mapping, and error mapping |
| Per-server/profile cache and offline fallback unchanged | Permanent system test plus cache unit checks | `ColorCatalogOfflineCacheTests` exercises an unreachable server with a disk fixture; `PaletteAPIClientContractTests` and `ProfileColorCacheTests` cover cache handoff and isolation |
| Solver parity corpus, including ties | Permanent unit/service corpus replay | `SolverParityTests`: exact scores, exclusions, weights, selected index/error, tied indices, and app solver selection |
| Corpus consumption documentation | Inspectable documentation | `docs/solver-parity-corpus.md` and `Tests/Fixtures/parity/README.md` state location and refresh steps |
| PR migration notes and parity findings | Human review of PR body after implementation | Not automatable in this red phase; implementation run must record the generated-client notes, API shape findings, and test result |

The implementation run must run `swift test` on a host with Swift installed,
and attach its result to the PR evidence. This environment does not provide a
Swift executable, so it can only validate fixture integrity and static test
content.
