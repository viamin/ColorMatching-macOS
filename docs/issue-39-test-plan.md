# Issue #39 verification plan

This test-writing change establishes the checks that the implementation PR must
make green. It deliberately does not alter production code.

| Criterion | Smallest credible verification | Evidence location |
| --- | --- | --- |
| Generated OpenAPI client replaces hand-written wire decoding | Focused API-contract tests use a `URLProtocol` transport to assert the generated operations request `/api/v1/printer_profiles` and `/api/v1/colors?printer_profile_id=` and decode their current envelopes. | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` |
| Per-server/profile cache and offline-stale fallback stay intact | Focused `ProfileColorCacheTests` cover namespace isolation, cached-profile discovery, and stale cache data. The app-level offline badge needs inspectable UI review because it is outside `ColorComposerCore`. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; manual UI evidence in implementation PR |
| Solver agrees with the backend parity corpus | Permanent corpus-driven XCTest runs every committed case through `CompositionSolver` with `WeightedSquaredErrorScorer`. It asserts the chosen palette id exactly, including ties, exclusions, and weights. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` |
| Corpus can be refreshed safely | Documentation records the upstream corpus location and requires replacing the fixture without editing expected results to fit the client. | `docs/solver-parity-corpus.md` (implementation phase) and README (implementation phase) |

The canonical upstream source is `viamin/color_matching#111`. This environment
cannot read that private pull request (GitHub returns 404), so the initial
fixture contains the published contract categories already present in the
client: weighted selections, earliest-wins ties, missing-measurement exclusion,
and zero-weight omission. Replace its cases verbatim from the upstream corpus
before the implementation PR is considered complete.
