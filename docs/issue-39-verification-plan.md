# Issue #39 verification plan

This test-writing change maps each acceptance criterion to the smallest
credible verification before the generated-client implementation begins.

| Criterion | Verification | Test / evidence |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten `/api/v1` transport | Focused integration-style client tests using a mock URL protocol | Add/update `PaletteAPIClientTests` in the implementation change to assert generated operations preserve authorization, paths, query encoding, decoding, and status mapping. Inspect the generated source and `Package.swift` dependency at review time. |
| Per-server/profile disk cache, offline-stale badge, cached-profile fallback remain unchanged | Permanent focused unit/service tests | Existing `ProfileColorCacheTests` cover server/profile separation and disk round trips. Implementation change must add the UI/catalog fallback regression test if generated-client migration alters the client injection or failure boundary. The offline badge is a UI-facing criterion and needs inspectable review evidence in addition to unit tests. |
| Solver selections match the server corpus, including ties | Permanent unit/service test | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityTests.swift` replays the committed v1 server corpus. It checks every candidate score/exclusion and executes `CompositionSolver` for representable targets, asserting exact selected index, selected hex, and error. |
| Corpus consumption is documented | Inspectable documentation | Update `README.md` in the implementation change with the committed fixture path, upstream canonical location, pinned revision/checksum policy, and refresh command. This test-only phase cannot change the README under its path allowlist. |
| PR description records migration notes, API shape changes, and parity results | Human/external evidence | Populate the PR body after implementation with generated-client source/spec revision, discovered `/api/v1` shape differences, cache/fallback verification, and corpus outcomes for ties, exclusions, and weights. |

## Corpus source and refresh contract

The test fixture is a committed copy of upstream `color_matching` corpus v1,
from upstream commit `47057afd58f7d46b4d4b740ca7d2d08947774471`:
`https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json`.
It is intentionally read from the test bundle's source fixture so ordinary
`swift test` runs are offline and deterministic. Refreshes must be deliberate:

1. Download the upstream corpus after its server-side regeneration is merged.
2. Replace `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json` exactly.
3. Update the test's accepted `algorithm_version` only with the related solver
   compatibility review.
4. Run `cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityTests` and record the upstream commit SHA and results in the PR description.

The corpus contains selection output as well as per-candidate scores. The
per-score assertions cover server scenarios whose target deliberately omits an
active channel; `CompositionSolver` cannot construct that invalid target from
source grids, so selection is correctly asserted through the scorer there.
