# Issue #39 verification plan

This test-writing change maps each acceptance criterion to the smallest
credible verification. Implementation, generated code, and the root README are
intentionally deferred to the follow-on implementation run.

| Criterion | Verification | Evidence at this head |
| --- | --- | --- |
| Generated OpenAPI client migrates the palette API calls | Focused client-contract tests covering typed profiles, colors, authentication, and `/api/v1` paths | Existing `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift`; add generated-client tests in implementation run |
| Per-server/profile cache and offline-stale fallback remain unchanged | Focused cache and catalog tests; manual inspection of the app badge is required for the UI badge | Existing `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift`; UI evidence pending implementation run |
| Solver selections exactly match the corpus, including ties | Permanent unit test that loads the committed fixture and checks selected ID, score, exclusions, ties, and zero-weight behavior | `ColorComposerCore/Tests/ColorComposerCoreTests/WeightedSquaredErrorParityCorpusTests.swift` |
| README says where the corpus lives and how to refresh it | Inspectable documentation review | Pending implementation run; this red-phase policy permits only `docs/` documents, not the root README |
| PR description records migration notes and parity findings | Inspectable PR body | Pending PR creation; this run must not push |

## Corpus refresh procedure

The committed fixture is
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`.
It is intended to be copied from `viamin/color_matching#111`, preserving its
case names, expected selected color IDs, expected scores, and exclusion counts.
When the upstream corpus changes, replace this fixture without changing the
test harness, then run:

```bash
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests
```

At test-authoring time the upstream private repository returned 404 anonymously
and 403 through the configured GitHub proxy, so its exact artifact revision
could not be independently retrieved in this environment. The implementation
run must replace this seed fixture with the upstream committed corpus before
claiming parity verification.
