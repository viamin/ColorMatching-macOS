# Issue 39 verification plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated `/api/v1` client retains profile/color request behavior | Focused `URLProtocol` service tests for the generated-client adapter, including auth and endpoint/query serialization | Implementation |
| Disk cache, offline-stale badges, and cached-profile fallback are unchanged | Permanent service tests for cache read/write and offline fallback state | Implementation |
| Solver matches the shared parity corpus, including ties | Permanent corpus-replay unit test at `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` | Tests |
| Corpus provenance and refresh process are documented | Human review of the README instructions and upstream corpus revision | Implementation |
| PR notes record API shape and parity findings | Inspectable PR description | Implementation |

The corpus fixture is copied from `viamin/color_matching` at
`priv/parity/v1/corpus.json`. Its committed SHA-256 is
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.
