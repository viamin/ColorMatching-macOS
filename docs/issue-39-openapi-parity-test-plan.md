# Issue #39 verification plan

This tests-only change records the acceptance criteria before the generated
client migration is implemented. The implementation change must update the
README's solver-parity section with the same corpus-consumption instructions;
this run is intentionally limited to test and LID documentation paths.

| Criterion | Smallest credible verification | Test/status in this change |
| --- | --- | --- |
| Typed generated client fetches profiles and colors | Focused `URLProtocol` contract test for generated operations: `/api/v1/printer_profiles`, `/api/v1/colors?printer_profile_id=N`, bearer authentication, response decoding, and HTTP error mapping | Add alongside the implementation; existing `PaletteAPIClientTests` remains baseline coverage |
| Per-server/profile caching and offline fallback do not regress | Permanent service tests for separately scoped server/profile entries and cached profile/color retrieval after an API failure; inspect the UI's offline-stale state in the implementation PR | Existing `ProfileColorCacheTests`; implementation must add a focused fallback test where required |
| Solver stays in parity with `color_matching` | Permanent fixture-driven unit test replaying every upstream v1 scenario and asserting scores, earliest-wins selections, no-match cases, and tie evidence | `WeightedSquaredErrorParityTests` |
| Corpus consumption is documented | README links the committed client fixture, identifies upstream canonical source, and gives the refresh command/source revision | Deferred to the implementation run because README is outside this run's permitted paths |

## Corpus source and refresh procedure

The canonical corpus is generated in
[`viamin/color_matching`](https://github.com/viamin/color_matching) at
`priv/parity/v1/corpus.json`. The committed client copy is
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.

When the server changes the solver or increments `algorithm_version`:

1. In `color_matching`, run `mix parity.generate` and commit the reviewed
   `priv/parity/v<N>/corpus.json`; `mix parity.generate --check` verifies that
   fixture remains deterministic.
2. Copy the reviewed corpus bytes to the client fixture path above.
3. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests`.
4. Review score, exclusion, and tie failures as compatibility changes; do not
   update expected values independently of the backend corpus.

The v1 fixture deliberately includes exact and multi-way ties, missing
positive-weight candidate and target channels, all-excluded cases, ignored
zero-weight channels, single-channel LPS matching, and unknown server weight
keys. It is a protocol contract, not generated test data that the client may
rewrite.
