# Solver parity corpus consumption

This document describes how the macOS app consumes the solver parity corpus
published by the `color_matching` Elixir service (viamin/color_matching#111),
and the companion OpenAPI client contract (viamin/color_matching#110).

## Why

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver so the client and the server agree
on color selection. Until now that parity was guarded only by hand-written unit
tests. The Elixir repository now publishes a parity corpus — generated fixture
inputs with expected solver outputs — and this repository loads it in its test
suite so any drift between the two implementations fails CI.

## Where the corpus lives

Corpora are committed under `ColorComposerCore/Tests/Fixtures/parity/`:

| File | Role |
| --- | --- |
| `corpus.json` | **Canonical corpus** exported from viamin/color_matching#111. Loading and passing it is the enforced parity contract. |
| `seed_corpus.json` | Hand-derived corpus (from the Elixir `WeightedSquaredError` doctest plus the documented selection semantics). Validates the harness itself and must always pass. |

Tests locate the fixtures relative to the test source file, so no SwiftPM
resource declaration is needed.

## Corpus schema (schema 1)

```json
{
  "meta": {
    "schema": 1,
    "generator": "…who produced this corpus…",
    "source": "…where it came from…",
    "notes": "…free-form provenance…"
  },
  "cases": [
    {
      "id": "case-slug",
      "kind": "selection | tie | exclusion | weights",
      "description": "…what behavior the case pins…",
      "weights": { "white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5 },
      "candidates": [
        { "id": 1, "hex": "#402060", "responses": { "white": 0.5, "red": 0.1 } }
      ],
      "target": { "white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5 },
      "expected_selection": 1,
      "expected_score": 0.205,
      "expected_excluded_ids": [30]
    }
  ]
}
```

Rules the loader enforces (`SolverParityCorpusTests`):

- Light-source keys must be the canonical `white`, `red`, `green`, `blue`,
  `lps` raw values — unknown keys are a corpus error, not silently dropped.
- Omitted weight keys default to `0`; only conditions with weight `> 0` are
  required and contribute to the score.
- `expected_selection` is the winning candidate id, or `null` when every
  candidate must be excluded (cell stays unmatched).
- `expected_score` (optional) is compared with `1e-9` accuracy.
- Ties must resolve to the **earliest candidate in corpus order**, mirroring
  the Elixir `IlluminantMatching.best_match/4` policy; cases marked
  `"kind": "tie"` are additionally checked to really contain a tie.

Each case is asserted at two levels: scorer-level ranking
(`WeightedSquaredErrorScorer` scores and exclusions) and solver-level selection
(`CompositionSolver` on a 1×1 grid built from the case target).

## Refreshing the canonical corpus

1. In a `color_matching` checkout, run the parity-corpus export task added in
   viamin/color_matching#111 (see that PR for the exact `mix` task).
2. Copy the exported JSON to
   `ColorComposerCore/Tests/Fixtures/parity/corpus.json`.
3. Run `swift test` in `ColorComposerCore/` — `SolverParityCorpusTests` must
   pass. If the export schema changed (`meta.schema` != 1), update the loader
   in `SolverParityCorpusTests.swift` in the same commit.
4. Commit the refreshed corpus together with the loader change, if any.

Until the export is committed here, `testCanonicalCorpusIsCommittedAndPasses`
fails by design — that commit is part of issue #39's deliverables.

## Related contract: the generated OpenAPI client

Issue #39 also migrates `PaletteAPIClient` to a typed client generated from
the server's OpenAPI document (viamin/color_matching#110). The artifacts the
migration must commit are pinned by `OpenAPIClientAdoptionTests`:

- `ColorComposerCore/OpenAPI/openapi.yaml` — the OpenAPI document.
- `Package.swift` declaring `swift-openapi-generator` (build-time code
  generation) and `swift-openapi-runtime` (generated-code support).

Behavior that the migration must preserve is pinned by existing tests:
`PaletteAPIClientTests` (endpoint paths, `printer_profile_id` query parameter,
`Accept`/`Authorization` headers, 401/bad-status/malformed-response error
mapping, envelope decoding), `APIDecodingTests` (wire shapes), and
`ProfileColorCacheTests` (per-server/profile disk cache and offline fallback,
which is fed by the same DTOs).
