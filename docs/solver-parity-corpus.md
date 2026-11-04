# Solver parity corpus

## Contract and source

ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver-parity-v1.json
is an exact committed copy of the upstream parity contract at
[viamin/color_matching priv/parity/v1/corpus.json](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json).
SolverParityCorpusTests decodes it and verifies exact per-candidate scores,
exclusions, selected index, selected error, and earliest-index tie behavior
through WeightedSquaredErrorScorer and CompositionSolver.

## Refresh procedure

1. Update the server corpus with mix parity.generate in viamin/color_matching,
   review it, and commit it there.
2. Copy the resulting priv/parity/v1/corpus.json byte-for-byte into this
   repository's fixture path above.
3. Update the test only when the versioned schema changes; do not silently
   reinterpret scores, missing measurements, weights, or ties.
4. Run cd ColorComposerCore && swift test.

The server's mix parity.generate --check verifies its fixture against a fresh
deterministic generation. This repository verifies its vendored copy by
replaying all scenarios on every Swift test run.

## Criterion verification plan

| Criterion | Verification | Evidence at implementation handoff |
| --- | --- | --- |
| Generated OpenAPI client handles the used API operations | focused API-client unit tests using the generated transport | PaletteAPIClientTests.swift |
| Per-server/profile cache and offline-stale fallback remain unchanged | focused cache and catalog tests, plus manual app inspection of stale badge and cached profile picker | existing cache tests; manual evidence required |
| Solver matches the server including ties, exclusions, and weights | permanent unit/service test replaying the committed upstream corpus | SolverParityCorpusTests.swift |
| Corpus consumption is documented | documentation review | this document, then README in the implementation phase |
