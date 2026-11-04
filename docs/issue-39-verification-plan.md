# Issue #39 verification plan

This test-only change records the smallest credible verification for each acceptance criterion before the implementation phase.

| Criterion | Verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` without API-shape regression | Permanent unit tests for the generated-client adapter: profile fetch, profile colors, bearer token, non-2xx mapping, and fixture decoding against the committed OpenAPI document | Not implemented; requires production dependency and generated sources |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback stay intact | Existing permanent cache tests plus a `ColorCatalog` integration test using a failing transport and disk-backed cache | Existing cache unit coverage is present; catalog integration coverage is deferred to implementation |
| Solver selections match the backend parity corpus exactly | `SolverParityCorpusTests.testWeightedSquaredErrorMatchesCommittedColorMatchingCorpus`, replaying the pinned corpus from `viamin/color_matching` commit `a82aec5441d2a7b0100e8c8ab81d573e11ace9b0` | Added in this phase |
| README explains corpus location and refresh | Human review of the README change: it must name the upstream URL, pinned revision/version, and refresh command | Deferred to implementation because `README.md` is outside this phase's documentation allowlist |
| PR records generated-client migration notes, API shape changes, and parity findings | PR-description review against the implementation diff and test output | External/human evidence; deferred until implementation PR exists |

The parity test is permanent because solver parity is a recurring behavior. It verifies per-candidate scores, selection, exact tie handling, exclusions, zero-weight missing channels, ignored unknown weight keys, and the fast-path solver selection where a complete target vector can be represented as source grids.
