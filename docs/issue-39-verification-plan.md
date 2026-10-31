# Issue #39 verification plan

This is the test-writing run for issue #39. Production client generation,
package dependencies, fixture vendoring, README updates, and cache integration
remain for the implementation run after `paid-tests-approved`.

| Criterion | Smallest credible verification | Current result |
| --- | --- | --- |
| Generated OpenAPI client replaces/wraps the `/api/v1` client | Unit tests in `PaletteAPIClientTests` assert the generated client's printer-profile and colors operations retain the versioned paths, query serialization, bearer token behavior, and malformed/unauthorized mapping. | Not run: generated client does not exist in this phase. |
| Per-server/profile disk cache remains intact | Existing `ProfileColorCacheTests` permanently exercise server/profile isolation and cache disk round trips. Extend the app-level catalog tests in implementation to assert cached profile and stale-color fallback behavior through the generated-client adapter. | Existing core cache coverage has not run: Swift is unavailable in this container. |
| Solver parity corpus selects exactly as the backend | `WeightedSquaredErrorParityCorpusTests` replays every candidate score plus one-cell `CompositionSolver` selection, expected error, and earliest-wins ties from the committed upstream corpus. | Intentionally red: `Fixtures/weighted-squared-error-v1.json` must be vendored from `viamin/color_matching@14320c33f93258a331cf17af7323ce9035c8a44d:priv/parity/v1/corpus.json` in the implementation run. Expected SHA-256: `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`. |
| Corpus consumption is documented | README links the committed local fixture and names the upstream path, pinned commit/SHA, and copy/verification refresh command. | Not run: README is intentionally outside this test-only phase's allowlist. |
| PR records generated-client migration and parity findings | PR body explicitly states operation/shape differences, cache adapter preservation, test result, ties, exclusions, and weights. | Human/external evidence required when the implementation PR is opened. |

The parity harness deliberately checks both scorer outputs and the solver's
selection. This prevents a fast-path-only tie or exclusion drift from escaping
even when individual score calculations still agree.
