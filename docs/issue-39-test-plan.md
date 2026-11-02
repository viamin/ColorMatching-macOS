# Issue #39 test plan and run evidence

## Criterion mapping

| Criterion | Smallest credible verification | Evidence status in this test-writing PR |
| --- | --- | --- |
| Generated OpenAPI client replaces the handwritten `/api/v1` transport | Focused contract test that requires the Swift package to declare `swift-openapi-generator` and `swift-openapi-runtime`, plus generated client source | Red test added; implementation pending |
| Existing palette/profile requests preserve the `/api/v1` contract | Focused `PaletteAPIClient` unit tests with a mocked URL protocol for request path, query, response decoding, and bearer authorization | Existing test coverage; expanded before implementation |
| Per-server/profile disk cache, stale-offline badge, and cached-profile fallback stay intact | Existing cache unit suite, plus an implementation-phase app/catalog integration test driven by transport failure and two server URLs | Not run in this tests-only phase; requires app-target harness |
| Solver parity with the backend | Permanent corpus test that replays every committed v1 scenario through `WeightedSquaredErrorScorer` and `CompositionSolver` | Added with upstream corpus; not run because this container has no Swift toolchain |
| README explains corpus refresh | Human-inspectable README update linking the upstream corpus and refresh command | Deferred: this phase permits `docs/` but not root `README.md` |
| PR captures migration and parity findings | PR description checked against this document after implementation | Deferred until a PR is opened |

## Corpus consumption

The committed fixture is `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_v1.json`. It is copied from [`viamin/color_matching`'s `priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json), generated upstream with `mix parity.generate`.

Refresh procedure:

1. Update the fixture from the upstream committed corpus and review the complete JSON diff, including `algorithm_version`.
2. Run `swift test --filter SolverParityCorpusTests` from `ColorComposerCore`.
3. Record changed score, tie, exclusion, or weighting semantics in the PR description. An algorithm-version increase requires an explicit client review; it is not a blind fixture update.

The test checks every expected candidate score, treats the corpus string `"excluded"` as exclusion rather than zero, verifies earliest-index selection through the default solver whenever the target supplies all active channels, and verifies tie indices and errors exactly.

## Upstream findings captured before implementation

- Corpus version: `1`; 12 deterministic scenarios.
- Selection: `earliest-index-wins`, including two- and three-way ties.
- Positive-weight missing candidate or target channels exclude; missing zero-weight channels do not.
- Weight contributions are weighted squared differences; unknown weight keys are ignored by the finite client channel set.
- The upstream default branch currently provides the parity corpus but no OpenAPI document was found there; generated-client work remains gated on the document from dependency #110.
