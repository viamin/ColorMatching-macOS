# Issue #39 verification plan

This is the tests-only phase. The generated OpenAPI client, package dependency,
and production migration are deliberately deferred to the implementation phase.

| Criterion | Smallest credible verification | Evidence at this revision |
| --- | --- | --- |
| Generated OpenAPI client serves the existing palette calls | Focused HTTP contract test for `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=N`, including bearer authentication and response mapping. The implementation run must run these against the generated-client wrapper. | `PaletteAPIClientTests.swift`; implementation wiring not yet present. |
| Disk cache and offline fallback remain unchanged | Existing permanent cache unit tests cover server/profile scoping, cache reads, cached-profile enumeration, and corrupt/missing entries. The implementation run must additionally exercise the network-failure fallback in `ColorCatalog`. | `ProfileColorCacheTests.swift`; app-level fallback remains implementation-run evidence. |
| Solver matches server parity corpus, including ties | Permanent corpus replay test loads the vendored v1 JSON and checks every candidate score, selected index, error, exclusions, and earliest-index tie selection through `CompositionSolver`. | `WeightedSquaredErrorParityCorpusTests.swift`; `Fixtures/weighted_squared_error_v1.json`. |
| README describes corpus refresh | Inspect the README change in the implementation PR: source path, pinned upstream revision, and copy/refresh command. | Not runnable in this tests-only phase because `README.md` is outside the allowed change set. |
| PR records generated-client migration and parity findings | Human/PR review of the final PR description, including API shape differences, tie/exclusion behavior, and weighting. | Not applicable until the implementation PR. |

## Corpus provenance and refresh

The committed fixture is copied byte-for-byte from
`viamin/color_matching` PR #112 at
`priv/parity/v1/corpus.json` (the published parity-corpus PR; issue text
references #111, which is no longer fetchable). Refresh only from the
upstream versioned path, preserve its `algorithm_version`, and run:

```bash
cd ColorComposerCore && swift test --filter WeightedSquaredErrorParityCorpusTests
```

The fixture has 12 deterministic scenarios and includes candidate scores,
selection, error, tied indices, positive-weight missing-data exclusions,
zero-weight omissions, and an unknown upstream weight.
