# Issue 39 verification plan

| Criterion | Verification | Test / evidence |
| --- | --- | --- |
| Generated client preserves `/api/v1` request contracts | Focused API-client tests for request path, authentication, decoding, and errors | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` (implementation phase extends these for generated operations) |
| Per-server/profile cache and offline fallback remain unchanged | Focused service tests covering cache keys, stale colors, cached profiles, and cache misses | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` |
| Solver matches the server | Permanent parity-corpus replay test | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift` |
| Corpus is inspectable and refreshable | Committed, pinned upstream fixture with source/version documented here | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` |

## Parity corpus consumption

The committed fixture is the upstream `color_matching` v1 corpus from
`priv/parity/v1/corpus.json`, pinned to commit
`a82aec5441d2a7b0100e8c8ab81d573e11ace9b0`. The permanent replay test checks
candidate scores, exclusions, selected palette indices, errors, and earliest-wins
ties against that fixture.

When the server publishes a new corpus version, download its committed JSON into
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/`, update the test's
version assertion, and run `swift test`. Do not refresh from an unpinned branch;
record the upstream commit in the README during the implementation PR update.
