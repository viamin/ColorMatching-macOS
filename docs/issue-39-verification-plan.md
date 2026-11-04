# Issue #39 verification plan

| Criterion | Smallest credible verification | Current phase |
| --- | --- | --- |
| Generated OpenAPI client is declared and adopted | `GeneratedOpenAPIClientContractTests` first proves the package dependency contract; implementation phase adds route/transport behavior tests against `MockURLProtocol`. | Red test written |
| Per-server/profile cache and offline fallback remain intact | Existing `ProfileColorCacheTests` cover server/profile isolation and disk round trips; implementation phase must add/retain `ColorCatalog` integration coverage for cached-profile fallback and offline-stale status. | Existing coverage + implementation follow-up |
| Solver matches the parity corpus | `SolverParityCorpusTests` decodes the committed upstream corpus and checks every score, exclusion, selection, and tied winner. | Permanent unit test written |
| Corpus refresh is documented | README records the pinned upstream source, revision/checksum, and refresh command. | Implementation follow-up; root README is outside this red-phase allowlist |
| PR records migration findings | PR description includes generated-client migration notes, API-shape changes, and parity results. | Human/external evidence at PR creation |

The committed fixture is copied unchanged from
`https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json`
(issue #111). Its SHA-256 is
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.
