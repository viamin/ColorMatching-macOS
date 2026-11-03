# Issue #39 verification plan

This tests-only change establishes the verification contract before the generated-client migration.

| Acceptance criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client serves the palette endpoints | Focused mock-transport test of the generated operations, including authorization and both /api/v1 response envelopes | Deferred to implementation: generated symbols do not exist yet |
| Server/profile disk cache and offline fallback are unchanged | Existing focused cache service tests, plus the migration's mock-transport regression test | Existing coverage: ProfileColorCacheTests.swift; migration-specific verification deferred |
| Solver matches the published parity corpus, including ties | Permanent unit test that replays the committed upstream v1 corpus through the scorer and earliest-wins selection policy | Added: SolverParityCorpusTests.swift |
| Corpus refresh procedure is documented | README review against the upstream corpus path and version | Deferred to implementation because this red-phase allowlist does not permit root README edits |

The committed fixture is copied verbatim from viamin/color_matching at
priv/parity/v1/corpus.json (blob
70e9999065c81334d1f2b5038a96c67cfd5d59d1). To refresh it, fetch that file
from the backend's default branch, replace
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json,
and run the parity test. Review any algorithm_version change as a solver
contract change, not a fixture-only update.
