# Issue #39 verification plan

This test-writing change maps the issue contracts to the smallest durable
evidence before implementation.

| Criterion | Verification | Evidence at implementation PR head |
| --- | --- | --- |
| Generated api/v1 client | Focused package/source adoption test | GeneratedOpenAPIClientAdoptionTests validates that the generator and runtime are declared and that PaletteAPIClient delegates to generated-client code. |
| Per-server/profile cache and offline fallback remain intact | Existing focused cache/client tests | ProfileColorCacheTests and PaletteAPIClientTests; implementation must run and record their results. |
| Solver parity, including ties, exclusions, and weights | Permanent corpus replay test | SolverParityCorpusTests loads the committed upstream v1 corpus and checks every recorded score, selection, error, and tie index. |
| Corpus consumption documentation | Human inspection | README update must state the upstream location and refresh command. |
| PR migration notes and API-shape findings | Human inspection | PR body must record generated-client migration, endpoint shape findings, and parity results. |

## Red-phase status

- The solver corpus test is expected to pass against the existing solver and
  establishes the permanent client/server compatibility boundary.
- The generated-client adoption tests are expected to fail until the package
  declares the OpenAPI runtime/generator and PaletteAPIClient is migrated.
- README and PR-body requirements require implementation/PR author evidence;
  this tests-only phase cannot edit the root README under the phase boundary.

## Upstream corpus

The fixture is copied byte-for-byte from viamin/color_matching
priv/parity/v1/corpus.json (issue #111). Refresh it after the upstream solver
changes by replacing
ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json
with that committed upstream file, then run swift test from ColorComposerCore.
