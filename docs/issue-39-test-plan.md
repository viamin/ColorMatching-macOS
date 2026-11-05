# Issue #39 verification plan

This red-phase change establishes the recurring solver-parity guard before the
generated-client migration is implemented.

| Acceptance criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client is used for the palette endpoints | Focused `PaletteAPIClient` request/response contract tests using a generated-client transport seam | implementation |
| Disk cache, cached-profile fallback, and offline-stale state remain intact | Existing cache unit tests plus a focused catalog integration test of a failed refresh | implementation |
| Solver selections retain server parity, including ties | `WeightedSquaredErrorParityTests` replays the committed upstream v1 corpus | this change |
| Corpus consumption is documented | README update naming the upstream source and reproducible refresh command | implementation (README is outside this test-writing allowlist) |
| PR records API-shape and parity findings | PR description populated from implementation test results and generated-client diff | implementation |

The committed fixture is copied byte-for-byte from
`viamin/color_matching` at `priv/parity/v1/corpus.json` (SHA-256
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).
The implementation run must refresh it from that location when its
`algorithm_version` changes, review the diff, and update the README usage
note. The parity test intentionally ignores unknown channel names in the
fixture because this client has a closed `LightingCondition` enum; this is
covered by the upstream `unknown-weight-ignored` vector.
