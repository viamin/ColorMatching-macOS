# Solver parity corpus

Issue #39 consumes version 1 of the `color_matching` parity corpus in
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`.
The fixture is copied verbatim from
[`viamin/color_matching` PR #112](https://github.com/viamin/color_matching/pull/112),
which closed upstream issue #111.

To refresh the fixture, update the server corpus with `mix parity.generate`,
commit it in the backend, then replace the macOS fixture with the corresponding
versioned corpus. Keep the test's version assertion in sync with the
`algorithm_version` field. The replay test verifies every candidate score,
missing-measurement exclusion, earliest-wins selection, final error, and
tie evidence through `WeightedSquaredErrorScorer` and `CompositionSolver`.

## Issue #39 verification plan

| Criterion | Smallest credible verification |
| --- | --- |
| Generated client preserves the `/api/v1` contract | Focused `PaletteAPIClient` request/response tests plus review of generated source and package configuration. |
| Per-server/profile caching and offline fallback stay unchanged | Existing focused cache and catalog tests; inspect the app's offline-stale UI behavior after migration. |
| Solver mirrors backend selection semantics | Permanent corpus replay test, including ties, exclusions, zero weights, and unknown weights. |
| Corpus refresh is documented | This runbook; implementation phase must also link it from the README. |
| PR notes capture migration and parity findings | Human review of the PR description against the corpus replay output. |
