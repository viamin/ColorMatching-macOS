# Issue #39 acceptance plan

This test-writing change maps each acceptance criterion to the smallest
credible verification. The implementation PR must replace the planned status
with the actual test command and result.

| Criterion | Verification | Evidence at PR head |
| --- | --- | --- |
| Generated client dependencies and typed migration | Focused unit/service test that checks the package declares both OpenAPI packages; compilation of the generated client provides the typed integration check. | `ColorComposerCore/Tests/ColorComposerCoreTests/GeneratedClientPackageTests.swift` |
| Per-server/profile disk cache and offline fallback remain unchanged | Existing permanent cache tests cover server/profile isolation; implementation must retain and run them. Offline UI badges/fallback require inspectable app-level evidence. | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; human/external evidence in implementation PR |
| Solver selections match the upstream parity corpus, including ties | Permanent unit test replays every committed vector, candidate score, selected index/hex/error, and earliest tie winner. | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift`; `Fixtures/weighted_squared_error_v1.json` |
| Corpus consumption is documented | Human-inspectable README update describing upstream location and refresh command. | Not possible in this tests-only phase; implementation PR |
| PR records migration notes, API-shape changes, and parity findings | Human/external evidence in PR description. | Not automated |

## Corpus provenance and refresh

The fixture is copied byte-for-byte from
`viamin/color_matching` commit `47057afd58f7d46b4d4b740ca7d2d08947774471`,
`priv/parity/v1/corpus.json` (SHA-1 `a4e14fa5f57c651aefb8982a546ece2df2d8e624`).
Refresh it from that upstream path after regenerating the corpus with the
server's `mix parity.generate` task, then run the parity test before updating
the recorded provenance.
