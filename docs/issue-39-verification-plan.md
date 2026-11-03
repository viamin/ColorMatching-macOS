# Issue #39 verification plan

This tests-only change records the smallest credible evidence for each acceptance criterion before the implementation phase.

| Criterion | Verification | Evidence at implementation PR head |
| --- | --- | --- |
| Generated typed OpenAPI client replaces the hand-written API transport while retaining its public behavior | Focused service tests for the profile and color operations, plus source/package inspection that the generated client and runtime are package dependencies and PaletteAPIClient delegates to it | PaletteAPIClientTests.swift; Package.swift; generated-client configuration/source |
| Per-server/profile disk cache, cached profile fallback, and offline-stale presentation are unchanged | Existing permanent service tests exercise cache separation, cached-profile fallback, and stale state; implementation must run their focused set | ProfileColorCacheTests.swift; ColorCatalog cache tests |
| The Swift weighted-squared-error scorer stays in lockstep with color_matching, including ties | Permanent corpus replay test decodes the committed corpus and compares every candidate score, exclusions, selected candidate, selected error, and tie evidence | SolverParityCorpusTests.swift; Fixtures/corpus.json |
| README tells maintainers where the corpus is and how to refresh it | Human/source inspection of the README after it links the vendored fixture to viamin/color_matching priv/parity/v1/corpus.json and documents the upstream mix parity.generate refresh process | README.md |
| PR description reports migration notes, API shape changes, and parity findings | Human/external evidence: the implementation PR description must link the generated source/spec version, enumerate observed API-shape changes (or state none), and cite the focused parity result (ties, exclusions, and weights) | PR description |

## Parity corpus provenance and refresh

The committed fixture is copied from viamin/color_matching at priv/parity/v1/corpus.json, algorithm version 1. The upstream server owns generation (mix parity.generate) and validates byte-level determinism with mix parity.generate --check.

When the backend changes the corpus, copy its committed priv/parity/v1/corpus.json into ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/corpus.json, update the expected algorithm-version assertion only as part of reviewing the semantic change, then run the focused Swift test. Do not regenerate the fixture in this repository: it is a consumer of the server's contract.

## Test-phase result

The test deliberately replays every score rather than merely asserting a scenario name. It also recomputes tied indices from the Swift scores, so a change to earliest-wins selection, positive-weight missing-measurement exclusion, or weight handling fails with the scenario and candidate index that diverged.
