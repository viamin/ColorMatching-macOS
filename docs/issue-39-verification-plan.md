# Issue #39 verification plan

| Criterion | Verification | Current evidence |
| --- | --- | --- |
| Typed OpenAPI client preserves the consumed `/api/v1` contract | Focused `PaletteAPIClientTests` exercises profile and color requests through `URLProtocol`, including the versioned path, profile query, bearer auth, and decoded response data. | Test coverage will be extended in this test-writing PR; generated-client wiring requires the unavailable #110 OpenAPI document. |
| Per-server/profile disk cache, offline-stale badge, and cached-profile fallback remain unchanged | Existing cache unit tests remain the permanent regression suite; the application-level offline badge needs a human run against a reachable server followed by an offline refresh. | Human/external evidence required after generated-client integration. |
| Solver selections match the server parity corpus | `WeightedSquaredErrorParityTests` loads one committed JSON corpus and asserts the selected palette ID (or no selection) for every case. It covers ties, exclusions, zero weights, and non-uniform weights. | The authoritative `viamin/color_matching#111` corpus cannot be fetched in this environment (GitHub returns 404); replace the bootstrap fixture before implementation approval. |
| Corpus consumption is documented | README documents the corpus location and refresh procedure. | Deferred: README is outside the test-writing allowlist. |
| PR records migration, shape, and parity findings | PR description contains generated-client migration notes, `/api/v1` shape delta, and test results. | Deferred to the implementation/PR-publishing run. |
