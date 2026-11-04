# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase status |
| --- | --- | --- |
| Generated typed OpenAPI client replaces the handwritten transport | `GeneratedOpenAPIClientAdoptionTests.testPackageUsesOpenAPIGeneratorAndRuntimeForPaletteClient` checks the package wiring and runtime use. Existing `PaletteAPIClientTests` continue to exercise authorization and the two used API endpoints. | Red: generator/runtime are not wired yet. |
| Per-server/profile cache, offline-stale state, and cached profile fallback stay intact | `ProfileColorCacheTests` is the permanent focused regression suite for server namespace isolation, usable cached colors, timestamps, corruption/miss handling, and cached profile enumeration. | Existing coverage; rerun after migration. |
| Solver selections exactly match the upstream parity corpus | `SolverParityCorpusTests.testWeightedSquaredErrorAndSelectionMatchVersionOneCorpus` decodes the committed v1 corpus, compares every candidate score/exclusion, earliest winner, expected error, and tie indices. | Added in this tests-only run. |
| Corpus consumption is documented | Add the README consumption/refresh instructions in the implementation phase; this phase cannot modify README under the test-only allowlist. | Deferred by phase boundary. |

The committed fixture is copied byte-for-byte from `viamin/color_matching` PR #112 (which closes #111): `priv/parity/v1/corpus.json`. Its SHA-256 is `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

When refreshing, download that upstream path from the server revision being adopted, replace `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`, verify the checksum/review the version stamp, then run `cd ColorComposerCore && swift test`. Update the README in the implementation phase with the adopted revision and any `algorithm_version` change.
