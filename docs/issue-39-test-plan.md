# Issue #39 verification plan

This tests-only change maps each issue acceptance criterion to its smallest
credible evidence. The implementation run must update the recorded result at
`tmp/paid-agent-verification.json` after the generated client and upstream
artifacts are available.

| Criterion | Verification | Current test / evidence |
| --- | --- | --- |
| Typed OpenAPI client is adopted by `ColorComposerCore` | Focused package-contract test, then generated-client request tests | `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientAdoptionTests.swift` (red until the package dependencies are added) |
| Per-server/profile disk cache and offline fallback remain unchanged | Focused cache unit tests; app-level offline badge needs inspectable UI evidence because the app target is outside the Swift package | `ProfileColorCacheTests.swift`; implementation PR must record a manual offline-badge check |
| Solver selections agree with the parity corpus, including ties | Permanent corpus-driven solver test | `SolverParityCorpusTests.swift` and `Fixtures/weighted_squared_error_parity.json` |
| Corpus consumption is documented | Documentation review | This document, followed by the README update in the implementation run |

## Corpus refresh procedure

The canonical corpus is maintained by
[`viamin/color_matching` PR #111](https://github.com/viamin/color_matching/pull/111).
Replace `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity.json`
with the exact upstream artifact, preserving its version and provenance metadata.
Run `cd ColorComposerCore && swift test --filter SolverParityCorpusTests` and record
the upstream commit SHA and test result in the PR description. Do not hand-edit
expected selections: refresh the whole artifact so new exclusions, weights, and
tie cases remain server-authored.

## Current dependency status

At test authoring time, neither upstream artifact was accessible from the
configured remote: `refs/pull/110/head` and `refs/pull/111/head` were absent.
The checked-in fixture establishes the loader contract and the known selection
classes; the implementation run must replace it with the official #111 corpus
before merge.
