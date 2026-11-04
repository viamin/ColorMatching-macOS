# Issue #39 verification plan

| Criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client migrates palette/profile requests | `OpenAPIClientAdoptionTests` requires both generator and runtime package dependencies; implementation phase will add mocked generated-operation request/response tests. | Red test now |
| Per-server/profile disk cache and offline-stale fallback remain intact | Existing `ProfileColorCacheTests` exercises server/profile scoping and persisted entries. Implementation phase must run it with the generated-client adapter. | Permanent unit/service test |
| Solver matches the external parity contract | `WeightedSquaredErrorParityTests` decodes the committed v1 fixture and checks every candidate score, excluded result, selected index, error, and earliest-wins ties. | Permanent unit/service test |
| Corpus consumption is documented | Update README with the upstream corpus location and refresh command after implementation is approved. README edits are outside this tests-only phase. | Human/inspectable documentation |
| PR notes capture shape changes and parity findings | PR author records generated-client migration notes, `/api/v1` differences, and test outcomes. | Human/external evidence |

The canonical corpus is `viamin/color_matching` at `priv/parity/v1/corpus.json` (issue #111). The committed fixture is a focused v1 conformance subset; implementation must replace it with the byte-for-byte full upstream corpus and keep the decoder schema-compatible when the corpus is refreshed.
