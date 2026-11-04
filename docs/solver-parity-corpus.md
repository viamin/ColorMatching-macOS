# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`
is the committed copy of the server-owned v1 golden-vector corpus from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
`WeightedSquaredErrorParityTests` replays every candidate score and every
one-cell solver selection, including ties and excluded candidates.

To refresh it after a server corpus version is published:

1. Download the exact upstream `priv/parity/vN/corpus.json` revision.
2. Replace the committed fixture with that byte-for-byte JSON and add a new
   version-specific test fixture if its schema or `algorithm_version` changes.
3. Run `swift test` in `ColorComposerCore`; review changes to selected index,
   selected hex color, score, exclusions, and tie cases deliberately.

The production README should link here when the generated-client implementation
phase is approved; this test-writing phase is restricted to test and `docs/`
paths.

## Acceptance-criterion verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated OpenAPI client preserves the two consumed `/api/v1` operations | Focused `PaletteAPIClientTests` with URL-protocol responses for printer profiles and profile-filtered colors. |
| Cache/offline behavior is unchanged | Existing `ProfileColorCacheTests` for per-server/profile persistence; an app-layer `ColorCatalog` integration test must exercise a failed live refresh falling back to cached colors and profiles and asserting the stale state. |
| Swift solver has server parity | `WeightedSquaredErrorParityTests` replays the committed corpus on every test run. |
| Corpus refresh process is documented | This document and the implementation-phase README link are reviewed at PR head. |
