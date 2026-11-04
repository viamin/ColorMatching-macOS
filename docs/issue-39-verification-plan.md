# Issue #39 verification plan

This tests-only change maps each acceptance criterion to the smallest
credible evidence to collect in the implementation PR.

| Criterion | Verification | Current evidence |
| --- | --- | --- |
| Generated typed API client replaces the hand-written `/api/v1` transport | Focused `PaletteAPIClientTests` with a mocked `URLSession`, asserting endpoint, query, authorization, successful decoding, and malformed/non-2xx errors | Not yet implemented in this test-writing phase |
| Per-server/profile disk cache, stale badge, and cached profile fallback remain intact | Permanent unit/service tests for `ProfileColorCache` plus a catalog-level test that drives an unreachable client and observes cache-backed profile/color state | Existing cache unit tests cover storage boundaries; catalog-level migration regression test is pending implementation support |
| Solver selections match the committed parity corpus | Permanent `SolverParityTests.testWeightedSquaredErrorSelectionsMatchParityCorpus`, which decodes the committed corpus and asserts one-cell solver selection by palette ID | Added in this change |
| Corpus consumption is documented | README documents the committed corpus location and a refresh command pinned to `viamin/color_matching#111` | Deferred: this phase may only modify tests and LID documentation |
| PR captures generated-client migration and parity findings | Inspectable PR description with endpoint-shape diff and test result | Human/external evidence; record during PR creation |

## Corpus refresh procedure

The implementation PR must copy the canonical corpus from
`viamin/color_matching#111` into
`ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpus/weighted_squared_error.json`
without translating its cases. Run `cd ColorComposerCore && swift test --filter
SolverParityTests` after every refresh. The README must repeat this procedure
for contributors.

The local fixture currently makes the contract explicit for exact selections,
earliest-candidate ties, missing-active-channel exclusions, zero-weight
channels, weighted selection, and no eligible candidate. Before merging the
implementation, replace/verify it byte-for-byte against the upstream committed
corpus and record the upstream commit SHA in the PR description.
