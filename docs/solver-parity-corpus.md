# Solver parity corpus

`ColorComposerCoreTests/Fixtures/WeightedSquaredError/v1/corpus.json` is the
committed copy of the versioned corpus owned by
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`. The permanent
`WeightedSquaredErrorParityCorpusTests` suite replays every scenario through
both `WeightedSquaredErrorScorer` and the default `CompositionSolver` path.

The corpus is the contract for:

- weighted squared-error totals;
- exclusion when any positive-weight channel is absent;
- ignoring absent zero-weight channels and unknown weight names; and
- exact earliest-index selection on ties.

## Refreshing

After the backend publishes a new corpus version, fetch its committed fixture
and replace the matching test fixture:

```bash
curl --fail --location \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/WeightedSquaredError/v1/corpus.json
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests
```

Review `algorithm_version` before accepting the refresh. A version bump means
the backend intentionally changed the scoring contract and needs a matching
client decision; do not silently update the fixture.

## Criterion verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated client preserves `/api/v1` requests | Focused `PaletteAPIClientTests` request/response tests, extended during implementation for generated transport delegation. |
| Per-server/profile cache, offline-stale badges, cached profile fallback remain | Existing focused `ProfileColorCacheTests` and app-level `ColorCatalog` behavior require implementation-run verification; UI badge rendering is human-visible evidence. |
| Solver selections match the backend corpus, including ties | Permanent `WeightedSquaredErrorParityCorpusTests`, replaying committed upstream vectors exactly. |
| Corpus consumption is documented | This document supplies the refresh provenance and command. The implementation run must mirror this short note into the README, which is outside this tests-only run's writable allowlist. |
