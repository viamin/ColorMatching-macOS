# Solver parity corpus

`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`
is a byte-for-byte copy of the `color_matching` solver corpus from
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/a82aec5441d2a7b0100e8c8ab81d573e11ace9b0/priv/parity/v1/corpus.json).
The SHA-256 of the committed fixture is
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

`WeightedSquaredErrorParityTests` decodes and replays every scenario against
`WeightedSquaredErrorScorer`. It checks each candidate score or exclusion, the
selected candidate and error, and the earliest-index rule for intentional ties.

## Refreshing

When `color_matching` publishes a new corpus version, copy its committed JSON
into `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/`, retain the
upstream commit URL and SHA-256 here, and update the test only for an explicit
schema or algorithm-version change. Run `cd ColorComposerCore && swift test
--filter WeightedSquaredErrorParityTests` before committing the refresh.

## Test-phase verification plan

| Criterion | Smallest credible verification | Status in this tests-only phase |
| --- | --- | --- |
| Generated OpenAPI client preserves palette/profile cache behavior | Permanent focused tests for generated-client request mapping plus existing cache/offline-fallback tests | Deferred to implementation phase; production/package files are disallowed here. |
| Solver agrees with corpus, including ties, exclusions, weights | `WeightedSquaredErrorParityTests` replaying the committed upstream corpus | Added; execution blocked because Swift is not installed in this container. |
| Corpus consumption is documented | This document; implementation phase must link it from the root README | Added; root README is outside the test-phase allowlist. |
| PR migration notes and API shape findings | PR description with a human-readable generated-client diff review | Not applicable until the implementation PR is created. |
