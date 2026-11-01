# Issue #39 verification plan

This tests-only change establishes the parity regression test before the
generated-client migration is implemented.

| Criterion | Smallest credible verification | Current phase |
| --- | --- | --- |
| Generated OpenAPI client migrates the two `/api/v1` calls | Implementation review plus focused mocked `PaletteAPIClient` request/response tests for printer profiles and profile colors | Pending implementation |
| Cache remains namespaced per server/profile | `ProfileColorCacheTests` disk round-trip and server-isolation tests | Existing permanent unit coverage; re-run after migration |
| Offline-stale badge and cached-profile fallback remain intact | SwiftUI/catalog integration evidence is required because it crosses the app UI boundary | Pending implementation; not inferred from core tests |
| Solver mirrors the server, including ties/exclusions/weights | `WeightedSquaredErrorParityTests` replays every committed upstream corpus scenario and checks scores, selections, errors, and earliest-index ties | Added in this change |
| Corpus consumption is documented | README describes the upstream fixture path and refresh procedure | Pending implementation (README is outside the tests-only allowlist) |
| PR records API shape and parity findings | Inspectable PR description, including generated-client migration notes and test output | Pending PR creation |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` `priv/parity/v1/corpus.json` (algorithm version 1;
SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
When upstream changes it, replace the fixture from that path and run the parity
test before committing the update.
