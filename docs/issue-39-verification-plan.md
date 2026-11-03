# Issue #39 verification plan

This is the test-writing phase for adopting the generated OpenAPI client and
enforcing solver parity. Production and package-manifest changes are deferred
to the implementation phase.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Permanent configuration test asserts the generator/runtime dependencies, generator plugin, and committed v1 spec paths. Focused `PaletteAPIClient` tests exercise both operations' adapter contract. | Added; red until the implementation phase adds the package/spec artifacts |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain intact | Existing `ProfileColorCacheTests` cover server/profile cache namespaces and usable cache entries; `PaletteAPIClientTests` cover the two operations' wire contracts. The macOS UI badge needs implementation-phase human inspection because this Linux test run cannot build the app. | Existing regression coverage; re-run in implementation |
| Solver selections exactly match the upstream corpus, including ties | Permanent unit test: `WeightedSquaredErrorParityCorpusTests` replays each committed v1 scenario against both scorer and one-cell solver selection. | Added in this phase |
| Corpus consumption is documented | README documents the checked-in Swift fixture, upstream source, versioning, and refresh procedure. This is inspectable documentation evidence. | Planned for implementation (README is outside the tests-only allowlist) |
| PR records migration notes, API-shape findings, and parity result | PR description, reviewed as human/inspectable evidence after implementation. | Planned for implementation |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` at `priv/parity/v1/corpus.json` (algorithm version 1).
The permanent test deliberately never fetches it during a build. When upstream
bumps the algorithm version, refresh the fixture from that path, review the
scenario and expected-result diff, and update the test metadata assertion in
the same change.

The corpus supplies externally generated expected scores, selected index/color,
ties, and missing-measurement exclusions. Its scenarios cover the solver rules
that are most likely to drift: positive-weight exclusions, ignored zero-weight
channels, numeric channel weights, no-match outcomes, and earliest-index tie
selection.
