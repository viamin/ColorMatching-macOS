# Issue #39 verification plan

This test-writing change maps each acceptance criterion to evidence that the
implementation change must produce. The parity fixture is the committed v1
corpus published by `viamin/color_matching` at
`priv/parity/v1/corpus.json` (SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).

| Criterion | Verification | Evidence at implementation completion |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten transport | Focused client service tests plus package/source inspection | `PaletteAPIClientTests` asserts request paths, query encoding, authorization, response decoding, 401 mapping, and malformed-response mapping; inspect `Package.swift` for `swift-openapi-generator` and `swift-openapi-runtime`, generated source, and the wrapper boundary. |
| Per-server/profile disk cache and offline-stale fallback remain unchanged | Focused unit/service tests | Existing `ProfileColorCacheTests` verifies server+profile keys and disk round trips. Add/retain a `ColorCatalog` service test covering a transport failure that serves the selected server/profile cache and marks it stale. This requires app-target testability and is not settled by core tests alone. |
| Solver selections remain server-parity exact, including ties | Permanent unit/service test | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` replays every upstream corpus case, including candidate scores, exclusions, selected index/hex/error, and tied indices. |
| Corpus consumption is documented | Human/source inspection | README links the vendored fixture and upstream generator command, describes the pinned revision/checksum, and gives the refresh command. |
| PR records client migration and parity findings | Human/external evidence | PR description names the generated client source/spec revision, reports any `/api/v1` contract deltas, and records the corpus result (ties, exclusions, and weight handling). |

The parity fixture must be refreshed only from the upstream committed corpus:

```bash
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json
shasum -a 256 ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json
```

Record the upstream commit and resulting checksum in the README and PR when it
changes. The implementation phase must move this short operational note into
the README, which is outside this test-writing phase's file allowlist.
