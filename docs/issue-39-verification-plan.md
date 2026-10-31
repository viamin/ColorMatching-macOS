# Issue 39 verification plan

This is the red-test phase. Production, package-manifest, and README changes
are intentionally deferred until the implementation run.

| Criterion | Smallest credible verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client replaces handwritten transport | `OpenAPIClientGenerationTests` requires generator/runtime dependencies, the generator plugin, and a committed OpenAPI document; implementation review verifies `PaletteAPIClient` delegates to generated operations. | Red: dependencies, plugin, and document are absent. |
| Disk cache, per-server/profile isolation, and offline fallback remain intact | Existing `ProfileColorCacheTests` permanently verify cache scoping and disk behavior. An implementation-run service test must exercise `ColorCatalog` with an unreachable client and cache-backed profile before/after the migration. | Not yet run against generated transport. |
| Solver selections match the server corpus | `WeightedSquaredErrorParityTests` replays the committed upstream v1 corpus, checks every candidate score, then checks selected index, hex color, and exact error. It includes ties, missing values, zero weights, and unknown weights. | Ready for execution. |
| Corpus consumption is documented in README | Human inspection of README links to the committed fixture and records the upstream refresh command and source revision. | Deferred: README is outside this run's documentation allowlist. |
| PR records migration notes, API shape changes, and parity findings | PR body is inspectable external evidence. | Deferred until a PR exists. |

## Corpus source and refresh

The committed fixture is copied byte-for-byte from
`https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`.
Its SHA-256 at test authoring time is
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

Refresh only after the upstream corpus changes deliberately: download that file,
review its algorithm version and scenarios, replace
`ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted-squared-error-v1.json`,
and run the parity test. The implementation run must copy this note into the
project README as required by the issue.
