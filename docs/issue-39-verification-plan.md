# Issue #39 verification plan

This red-phase change adds the permanent tests that will gate the implementation
run. The upstream dependencies are `viamin/color_matching#110` (OpenAPI) and
`viamin/color_matching#111` (solver corpus).

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused request-shape/auth tests plus inspection of the generated client and package dependency | Tests exist; generated-client inspection awaits implementation |
| Per-server/profile disk cache and cached profile fallback are preserved | Existing `ProfileColorCacheTests` exercise per-server/profile entries and `allEntries`; implementation run must add/retain a catalog-level offline fallback test | Existing cache unit coverage; catalog integration remains implementation work |
| Offline-stale badges are preserved | Human/UI inspection of the app state rendered after a failed refresh with a usable cache | Not automatable in the core package; implementation run evidence required |
| Solver selections match the committed corpus, including ties | `WeightedSquaredErrorParityCorpusTests` loads the committed JSON fixture and asserts selected ID and error for each vector | Permanent unit test added |
| Corpus consumption is documented | README documents the checked-in corpus location and a pinned refresh procedure | Deferred: this test-writing phase may edit only tests and LID docs |
| PR captures migration/parity findings | PR body records API shape differences, ties, exclusions, and weight handling | Deferred to implementation PR |

## Corpus refresh contract

The committed fixture loader reads
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-parity.json`.
When `color_matching#111` is available, replace that file verbatim with its
published corpus, retain its source revision in the fixture metadata, and run:

```bash
cd ColorComposerCore
swift test --filter WeightedSquaredErrorParityCorpusTests
```

The loader intentionally has no network dependency: CI must test the exact
committed corpus snapshot. The currently committed vectors are a temporary
schema-and-loader smoke set, not an assertion that the unavailable upstream
corpus was imported. At the time this plan was written, GitHub returned 404
for the dependency from this environment, so the implementation run must
replace them with the published corpus and verify its revision before claiming
parity completion.
