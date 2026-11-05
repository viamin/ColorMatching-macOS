# Issue 39 verification plan

This test-writing change establishes the durable regression coverage for solver
parity before the generated-client migration is implemented.

| Criterion | Smallest credible verification | Status in this phase |
| --- | --- | --- |
| Generated OpenAPI client migrates `PaletteAPIClient` | Focused API-client contract tests exercise `/api/v1/printer_profiles` and `/api/v1/colors`, headers, decoding, and status mapping. Review the generated sources and package configuration as inspectable implementation evidence. | Not yet implemented |
| Per-server/profile cache and offline fallbacks remain unchanged | Existing `ProfileColorCacheTests` are permanent unit coverage; add integration coverage at the catalog boundary during implementation. Human review verifies offline-stale presentation. | Not yet implemented |
| Solver matches the server corpus | `WeightedSquaredErrorParityCorpusTests` replays committed v1 golden vectors through both the scorer and `CompositionSolver`, including ties, exclusion, and zero-weight channels. | Added |
| Corpus consumption is documented | Add a README section pointing to the upstream corpus, its pinned version, and its refresh procedure during implementation. | Not yet implemented |
| PR description records migration and parity findings | PR-only inspectable evidence, including the generated source revision and test output. | Not yet implemented |

The canonical upstream fixture is
[`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
The committed test fixture is deliberately local so parity remains testable
offline and under a pinned algorithm version.
