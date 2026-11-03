# Issue #39 verification plan

This test-writing change establishes the parity-corpus regression test before
the generated-client migration is implemented.

| Criterion | Smallest credible verification | Current evidence |
| --- | --- | --- |
| Generated OpenAPI client replaces the hand-written `/api/v1` client | Focused client integration tests using generated operation types plus mocked HTTP responses from the committed OpenAPI document | Not run: requires the implementation-phase generated target and committed spec. |
| Per-server/profile disk cache and offline-stale fallback remain unchanged | Existing cache unit tests, plus an app-level mocked-network test that verifies cached profile fallback and stale-state presentation | Existing cache coverage is present; app-level fallback verification remains for the implementation phase. |
| Solver matches the upstream corpus, including ties, exclusions, and weights | Permanent unit test that decodes the committed upstream corpus, checks every individual score and selection, then checks the default solver for complete targets | `SolverParityCorpusTests` (new). |
| Corpus consumption is documented | README section naming upstream corpus location and refresh command | Not changed in this test-only phase because repository policy permits documentation commits only under `docs/`; implementation phase must add the README section. |
| PR records shape changes and parity results | Inspectable PR description based on generated-client output and test run | Human/external evidence required after the implementation PR exists. |

The corpus fixture is copied verbatim from
`viamin/color_matching/priv/parity/v1/corpus.json` at algorithm version 1.
Refresh it only from the upstream deterministic `mix parity.generate` output,
then run `swift test --package-path ColorComposerCore`.
