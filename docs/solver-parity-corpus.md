# Solver parity corpus

The committed test fixture at
`ColorComposerCore/Tests/ColorComposerCoreTests/Resources/Parity/v1/corpus.json`
is copied verbatim from
[`viamin/color_matching`'s `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).

`SolverParityCorpusTests` decodes and replays every scenario through
`WeightedSquaredErrorScorer`. It checks each candidate score, excluded
candidate, selected color, selected error, and every tied index. This keeps
the server's earliest-index-wins selection contract enforceable in the macOS
package.

## Refresh procedure

1. In `viamin/color_matching`, run `mix parity.generate --check`; refresh the
   upstream fixture with `mix parity.generate` if it reports a stale corpus.
2. Copy the resulting `priv/parity/v1/corpus.json` byte-for-byte into this
   repository's fixture path above.
3. Review its `algorithm_version` and update the metadata expectation only
   when the upstream solver contract intentionally changed.
4. Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

The upstream corpus encodes ties, missing positive-weight measurements,
zero-weight channels, unknown weights, and exact score values. Do not replace
it with hand-written examples.

## Acceptance verification plan for #39

| Criterion | Smallest credible verification |
| --- | --- |
| Generated OpenAPI client migrates `/api/v1` calls | Unit tests assert generated-client request construction and decoded profile/color responses; inspect generated sources and package dependencies. |
| Disk cache and offline fallback remain unchanged | Existing `ProfileColorCacheTests` plus a focused `ColorCatalog` integration test using a failing transport and disk-backed fixture. |
| Solver matches server parity corpus | `SolverParityCorpusTests` replays the committed upstream corpus on every PR. |
| Corpus consumption is documented | This document records the upstream location and refresh procedure; the implementation run must also add the required README link. |
| PR records migration findings | Human-visible PR description, based on the generated client diff and test output. |
