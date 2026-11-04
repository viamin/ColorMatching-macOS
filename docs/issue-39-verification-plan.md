# Issue 39 verification plan

This test-writing change establishes the checks that the implementation change
must satisfy. The generated OpenAPI client and its package dependencies cannot
be added during this test-only phase.

| Criterion | Smallest credible verification | Evidence at this revision |
| --- | --- | --- |
| Typed OpenAPI client replaces the handwritten `/api/v1` transport | Focused `PaletteAPIClient` tests assert the profile and color requests, authorization, and OpenAPI fixture decoding. | Existing `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; add generated-client-specific assertions with the implementation. |
| Per-server/profile cache and stale fallback stay intact | Focused service tests exercise a cached profile/color response when the transport fails, and assert the stale state. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; implementation run must execute them. |
| Solver selections match the external corpus | Permanent unit test decodes the committed corpus and asserts selected candidate IDs through `CompositionSolver`. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift` and its fixture. |
| Corpus consumption is documented | Inspect the corpus-consumption documentation and ensure the final implementation also links it from the README. | `docs/solver-parity-corpus.md`; README edit is deferred by the test-only boundary. |
| PR records migration and parity findings | Human review of the PR description against the generated-client diff and test output. | Not automatable; record when the implementation PR is opened. |

The upstream GitHub API proxy did not permit access to
`viamin/color_matching#111` during this run (HTTP 403). Before implementation
is merged, replace the seeded fixture with the exact committed upstream corpus
and record its source revision. The loader deliberately uses a committed local
fixture rather than deriving expected results from Swift.
