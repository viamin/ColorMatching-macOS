# Issue #39 test plan

| Acceptance criterion | Smallest credible verification | Phase |
| --- | --- | --- |
| Generated OpenAPI client supplies palette/profile data | Focused `URLProtocol` contract tests against generated operations, including bearer auth and the published `/api/v1` response shapes | Implementation |
| Per-server/profile disk cache, offline-stale UI state, and cached-profile fallback remain intact | Existing focused cache tests plus an app-model/service test that forces a client failure after a cached fetch | Implementation |
| Solver choices retain server parity | `WeightedSquaredErrorParityCorpusTests` loads the checked-in `viamin/color_matching#111` corpus and asserts selection, exact score, exclusions, ties, and weight handling | Test-writing |
| README documents corpus refresh | Review the documented upstream source, revision, and refresh command after the corpus is imported | Implementation |
| PR captures migration and parity findings | Human inspection of the PR description against generated-client diff and parity test output | Implementation |

The upstream parity PR is not accessible from this environment at test-writing time. The fixture establishes the intended checked-in JSON contract and edge-case coverage; replace or extend it with the upstream corpus revision when the dependency becomes available.
