# Solver parity corpus

## Criterion verification plan

| Criterion | Verification |
| --- | --- |
| Generated `/api/v1` client preserves palette/profile behavior | Permanent service tests for authenticated requests and existing `ProfileColorCacheTests` for server/profile isolation and stale fallback. |
| Solver parity, including ties | `ParityCorpusTests.testWeightedSquaredErrorMatchesServerParityCorpus`, replaying the committed upstream vectors. |
| Corpus refresh documentation | This document is reviewed with the fixture update. |

## Corpus source and refresh

The checked-in fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json`
is derived from [`viamin/color_matching` PR #112](https://github.com/viamin/color_matching/pull/112), which closes issue #111. It is the v1 output of the backend's `mix parity.generate` command.

When the backend changes the solver corpus, run `mix parity.generate` in the backend, copy its `priv/parity/v1/corpus.json` here, and run `cd ColorComposerCore && swift test`. Keep the corpus `algorithm_version` in sync; a version change requires reviewing every selection and score expectation.
