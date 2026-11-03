# Issue #39 verification plan

| Criterion | Smallest credible verification | Status in this test-writing change |
| --- | --- | --- |
| Generated OpenAPI client uses the published `/api/v1` shape | `PaletteAPIClientTests.testFetchColorsUsesProfileScopedOpenAPIPath` checks the profile-scoped OpenAPI route and response decoding. | Red until the generated-client migration changes the request path. |
| Per-server/profile cache and offline-stale fallbacks remain unchanged | Existing `ProfileColorCacheTests` cover server/profile isolation and disk round trips; implementation must run them after migration. | Deferred to implementation verification. |
| Weighted solver matches the committed parity corpus, including ties | `WeightedSquaredErrorParityTests.testVersionOneCorpusMatchesScoresSelectionsAndTies` replays upstream `priv/parity/v1/corpus.json`. | Added; awaiting a Swift-capable test environment. |
| README documents corpus location and refresh steps | Human inspection of README after implementation adds the upstream path and `mix parity.generate` refresh process. | Deferred to implementation. |
| PR records migration notes, API shape changes, and parity results | PR body inspection. | External/human evidence required. |

The committed fixture is copied byte-for-byte from `viamin/color_matching` at
`priv/parity/v1/corpus.json` (SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
Refresh it after the server runs `mix parity.generate`, retain its versioned
filename, and run `cd ColorComposerCore && swift test`.
