# Issue #39 verification plan

This red-phase change adds a permanent solver regression test before the
generated-client migration.

| Criterion | Verification | Evidence at implementation time |
| --- | --- | --- |
| Generated OpenAPI client serves the existing `/api/v1` calls | Focused client tests for profiles, colors, status mapping, and bearer-token forwarding | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` |
| Per-server/profile disk cache remains isolated | Focused cache unit tests | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` |
| Offline colors and cached profiles remain available after a failed fetch | App/catalog integration coverage, or inspectable manual evidence if the macOS UI cannot run in CI | `ColorMatching/Networking/ColorCatalog.swift` fallback paths and PR evidence |
| Solver selection stays server-compatible | Permanent corpus test covering all v1 scenarios, exact scores, exclusions, and earliest-index ties | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` |
| Corpus refresh stays traceable | Review the upstream v1 fixture against `viamin/color_matching#111`, update the committed fixture, then run the permanent corpus test | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json` |

The committed fixture is the machine-readable semantic data from
`viamin/color_matching`'s `priv/parity/v1/corpus.json`, introduced by issue
[#111](https://github.com/viamin/color_matching/issues/111). Refresh it only
from that upstream file, preserve its algorithm version and scenario IDs, and
run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests`.

The v1 corpus records earliest-index tie breaking, exclusion when any
positive-weight channel is absent, zero-weight channel omission, and ignored
unknown weights. These are compatibility contracts, not invitations to change
solver semantics.
