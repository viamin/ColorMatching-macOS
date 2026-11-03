# Issue #39 verification plan

| Criterion | Smallest credible verification | Current phase |
| --- | --- | --- |
| Generated OpenAPI client fetches the `/api/v1` palette/profile contract | Focused `URLProtocol` client tests verify generated-operation paths, query encoding, bearer authorization, decoding, and error mapping. | Implementation phase |
| Cache and offline fallbacks are unchanged | Existing permanent `ProfileColorCacheTests` cover server/profile isolation and cached-entry retrieval; implementation adds `ColorCatalog` integration coverage for offline-stale and cached-profile fallback. | Implementation phase |
| Solver stays in parity with `color_matching` | Permanent corpus replay test loads the committed upstream v1 fixture, checks every candidate score, winner, error, exclusions, and earliest-wins ties. | This PR |
| Corpus consumption is documented | README documents source location, pinned version, and refresh command/review procedure. | Implementation phase (README is outside this test-writing run allowlist) |
| Generated-client migration and parity results are recorded | PR description references the generated sources/spec revision and the corpus test result; a maintainer verifies actual API shape changes. | Human/external evidence |

The corpus fixture is copied from `viamin/color_matching` at
`priv/parity/v1/corpus.json`. Refresh it only from the upstream deterministic
generator (`mix parity.generate`); review the fixture diff and update this
consumer test if the published schema changes.
