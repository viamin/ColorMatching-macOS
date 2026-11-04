# Issue #39 verification plan

This tests-only change establishes the acceptance evidence required before the generated-client implementation is added.

| Criterion | Smallest credible verification | Phase/status |
| --- | --- | --- |
| Typed client replaces the handwritten `/api/v1` transport | Focused `PaletteAPIClient` contract tests covering generated operations, authorization, and the two API responses | Deferred to the implementation phase; no generated client exists yet |
| Per-server/profile cache, stale badge, and cached-profile fallback are preserved | Permanent service/unit tests for cache keys, stale metadata, and offline fallbacks | Existing cache tests will be retained and expanded if migration changes their seam |
| Solver selections match the server parity corpus | Permanent corpus replay test covering each candidate score, exclusion, selected index/color, exact error, and ties | Added in this change |
| Corpus consumption is documented | README links the versioned fixture and states the refresh command/review policy | Deferred because this tests-only phase permits documentation only under `docs/` |
| PR records migration notes and parity result | PR description with generated-client/API-shape review plus test result | Implementation/PR phase |

The committed fixture is copied byte-for-byte from `viamin/color_matching` at `priv/parity/v1/corpus.json` (SHA-256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`). The implementation phase must refresh it only from that upstream versioned path and must review its `algorithm_version` before accepting changed expectations.
