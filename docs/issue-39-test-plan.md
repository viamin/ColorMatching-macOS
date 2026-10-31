# Issue #39 criterion verification plan

This is the tests-only run for issue #39. The implementation run must execute
the listed checks and replace provisional statuses in
`tmp/paid-agent-verification.json` with actual results.

| Criterion | Smallest credible verification | Status in this run |
| --- | --- | --- |
| Generated OpenAPI client replaces or wraps `PaletteAPIClient` | Focused mocked-transport tests in `PaletteAPIClientTests` for profiles/colors request shape, decoding, authorization, and typed client integration; inspect the generated source and package dependency. | Not run: generated client is implementation work. |
| Disk cache and offline fallback are unchanged | Existing `ProfileColorCacheTests` covering per-server/profile isolation, persisted fallback and stale entries; implementation run must run them. | Not run: no Swift toolchain available. |
| Solver selections exactly match the committed parity corpus | Permanent `WeightedSquaredErrorParityTests` replaying every upstream v1 scenario, including score table, exclusions, selection, error, and ties. | Not run: no Swift toolchain available. |
| Corpus consumption documentation | Inspect this document and the implementation-phase README update. | Passed: this document records source and refresh procedure; README remains implementation-phase work under the tests-only file allowlist. |
| PR description records migration and parity findings | Human/PR inspection of description with generated-client notes, `/api/v1` shape changes, and tie/exclusion/weight results. | Not run: no PR is opened in this run. |
