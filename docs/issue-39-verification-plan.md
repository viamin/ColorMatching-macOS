# Issue 39 verification plan

This tests-only change establishes the durable regression check before the
generated-client migration is implemented.

| Criterion | Smallest credible verification | Evidence in this change |
| --- | --- | --- |
| Generated `/api/v1` client preserves the palette contract | Focused `PaletteAPIClient` request/response tests using a URL protocol; implementation review confirms generated types are the transport boundary. | Existing `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; implementation-phase evidence required. |
| Per-server/profile cache and offline fallback stay intact | Focused cache tests plus the app-model offline-state tests, since cached data and stale badges are user-visible behavior. | Existing `ProfileColorCacheTests.swift`; implementation-phase evidence required for app-model behavior. |
| Solver remains in parity with `color_matching` | Permanent, local corpus test that evaluates every server-generated candidate score and solver selection. | `SolverParityCorpusTests.swift` and `Fixtures/solver-parity-v1.json`. |

## Parity corpus

The committed fixture is copied from
[`viamin/color_matching` `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json),
the artifact produced for [color_matching#111](https://github.com/viamin/color_matching/issues/111).
It intentionally covers weighted errors, exclusions for missing measurements,
zero-weight channels, and earliest-candidate tie-breaking.

When the backend publishes a new corpus version, copy its committed JSON into
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/`, update the expected
`algorithm_version` in `SolverParityCorpusTests`, and run `swift test` from
`ColorComposerCore`. The implementation phase must add the same concise refresh
instruction to the root README, which is outside this tests-only phase's
permitted documentation paths.
