# Solver parity corpus — consumption guide

This documents deliverable "Document corpus consumption in the README" from
issue #39 (kept in `docs/` so the tests-only PR can carry it; fold into the
root `README.md` when implementing).

## Where the corpus lives

- **Source of truth (server):** [`viamin/color_matching`](https://github.com/viamin/color_matching)
  at `priv/parity/v1/corpus.json`, produced by `mix parity.generate`
  (published via viamin/color_matching#111). The server's CI verifies the
  committed corpus is byte-identical to a fresh build
  (`mix parity.generate --check`).
- **Committed copy (this repo):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
  — a byte-identical copy so `swift test` enforces parity offline.

## How the tests consume it

`SolverParityCorpusTests` (`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift`)
decodes the committed corpus and replays every scenario through
`WeightedSquaredErrorScorer` exactly as the upstream README prescribes:

1. Score every palette color against the scenario's target using the
   scenario's weights.
2. Assert **exact** agreement with the recorded per-candidate score table
   (`"excluded"` marks missing-measurement exclusions).
3. Assert the earliest-index-wins selection, the selected hex, the minimum
   error, and the explicit tie evidence (`tie_broke`, `tied_indices`) —
   ties are intentionally included in the corpus.

The corpus is stamped with an `algorithm_version` (currently `1`). The test
fails loudly when the server bumps it: refresh the committed corpus and the
`implementedAlgorithmVersion` constant in the same change. A refreshed
corpus that drops the hard cases (ties, exclusions, no-selection) also
fails the coverage check.

## How to refresh the committed corpus

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

If the parity run fails after a refresh, the server's solver semantics
changed (tie-breaking, missing-measurement exclusion, or channel weighting);
reconcile `WeightedSquaredErrorScorer` with the server's
`ColorMatching.WeightedSquaredError` — do not weaken the test.

## OpenAPI document (viamin/color_matching#110)

The migration's typed client is generated from an OpenAPI document that must
be committed inside `ColorComposerCore` (`openapi.yaml`/`openapi.json`,
enforced by `OpenAPIClientAdoptionTests`). The live server publishes its
spec at `GET /api/v1/openapi.json`. Wire behavior the generated client must
preserve is pinned in `PaletteAPIWireContractTests`; the disk-cache/offline
fallback path in `OfflineFallbackAfterFetchTests` and
`ProfileColorCacheTests`.
