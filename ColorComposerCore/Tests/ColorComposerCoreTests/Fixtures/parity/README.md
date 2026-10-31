# Solver parity corpus

This directory holds the committed solver-parity corpus consumed by
`SolverParityCorpusTests.swift`. Every case pairs an input (palette, channel
weights, target response vector) with the selection and scores the Elixir
`ColorMatching.WeightedSquaredError` solver produces for it, so the Swift
`WeightedSquaredErrorScorer` can be held to exact parity — including ties,
exclusions, and weight handling.

- Current file: `solver_parity_corpus.json` (schema version 1)
- Status: **placeholder** — hand-authored from the documented mirror semantics
  (including the Elixir doctest value `0.205`). The generated corpus from
  [viamin/color_matching#111](https://github.com/viamin/color_matching/pull/111)
  was not yet published when this harness landed (PR 404 as of 2026-10-31).

## Refreshing

Once viamin/color_matching#111 merges and exports a corpus:

1. Download the exported `weighted_squared_error` corpus JSON.
2. Map it onto schema version 1 (or extend the Codable models in
   `SolverParityCorpusTests.swift` and bump `schema_version` — the hygiene test
   pins the supported version).
3. Overwrite `solver_parity_corpus.json` and update `source`/`server_ref` to
   the upstream commit or release that produced it.
4. Run `cd ColorComposerCore && swift test` — the parity suite must stay green
   with zero edits to the assertions.

The corpus hygiene test requires the refreshed file to keep at least one case
of each kind (`tie`, `exclusion`, `zero-weight`, `all-excluded`), so a
refresh that drops coverage fails loudly instead of silently weakening parity.
