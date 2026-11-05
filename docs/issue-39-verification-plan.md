# Issue #39 verification plan

This is the test-phase evidence for adopting the generated `color_matching`
OpenAPI client and its solver parity corpus.

| Criterion | Smallest credible verification | Test-phase status |
| --- | --- | --- |
| Generated client preserves the `/api/v1` calls used by `PaletteAPIClient` | Focused `URLProtocol` contract tests assert the profiles path, colors path/query, JSON accept header, bearer authorization, and decoding boundary. The implementation phase will make these tests exercise the generated-client adapter. | Added |
| Per-server/profile disk cache and offline fallback remain unchanged | Existing permanent `ProfileColorCacheTests` cover server/profile isolation, persisted entries, stale timestamps, cached profiles, and clear behavior. The implementation phase must rerun the focused suite after the adapter migration. | Existing coverage; rerun required |
| Solver parity—including ties, exclusions, and weights | Permanent corpus-driven unit test decodes the committed JSON fixture and solves each one-cell vector, asserting selected palette ID and error exactly. | Added |
| Corpus refresh is documented | Human-inspectable README update, including upstream corpus location and pinned refresh process. | Implementation-phase documentation task |

The upstream pull requests named by the issue are not reachable from this
isolated checkout, so the fixture introduced in this phase records the v1
contract cases already described by the issue (weighted selection, tie order,
exclusions, and zero weights). Replace or extend it with the exact committed
artifact from `viamin/color_matching#111` during implementation, retaining the
same corpus-driven test.
