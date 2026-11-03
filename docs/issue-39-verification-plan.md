# Issue #39 verification plan

This is the test-writing baseline for adopting the `color_matching` OpenAPI
client and solver parity corpus.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated API client replaces the hand-written `/api/v1` wire contract | Focused `PaletteAPIClient` integration tests using a `URLProtocol` fixture, including authorization and both endpoint responses | Existing coverage; implementation test to be added with the generated wrapper |
| Per-server/profile disk cache, stale offline badge, and cached-profile fallback are unchanged | Permanent service tests for `ProfileColorCache`, plus app-level catalog tests when the generated wrapper is wired in | Existing cache unit coverage; catalog-flow test to be added in implementation phase |
| Solver selections match the server corpus, including ties and exclusions | Permanent corpus-driven XCTest, committed with the corpus | `SolverParityCorpusTests` |
| Corpus consumption is documented | README link and refresh command | Deferred: this test-only phase permits `docs/` but not `README.md` |

## Parity corpus

The committed fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json`
is copied byte-for-byte from
`viamin/color_matching/priv/parity/v1/corpus.json`. The test decodes it and
checks each recorded candidate score or exclusion, then runs
`CompositionSolver` against every representable target to assert the selected
palette index and error. That covers exact-score selection, earliest-index tie
breaking, excluded missing measurements, zero-weight channels, and unknown
upstream weights.

To refresh it after an upstream algorithm-version change:

1. Run `mix parity.generate --check` in `viamin/color_matching` and commit the
   regenerated `priv/parity/vN/corpus.json` there first.
2. Copy that committed file into the matching Swift test fixture path.
3. Update the XCTest's asserted `algorithmVersion` and run `swift test`.
4. Record the corpus revision and tie/exclusion/weight findings in the PR
   description.

The implementation PR must move this concise consumption note into the README,
because the current test-writing gate intentionally permits only tests and
`docs/` changes.
