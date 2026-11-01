# Solver parity corpus

The macOS app's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver, and `CompositionSolver` mirrors the
earliest-index-wins selection of `ColorMatching.IlluminantMatching.best_match/4`
(see viamin/color_matching#111). The **solver parity corpus** is the
server-generated golden-vector fixture that keeps the two implementations in
lockstep.

## Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  [viamin/color_matching](https://github.com/viamin/color_matching), regenerated
  with `mix parity.generate` (upstream CI verifies a committed corpus is
  byte-identical to a fresh build via `mix parity.generate --check`).
- **This repo (committed copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json`
  — a byte-identical copy, consumed directly by the test suite.

## How it is consumed

`SolverParityCorpusTests` (in `ColorComposerCore/Tests/ColorComposerCoreTests/`)
loads the committed corpus — located relative to `#filePath`, so no bundle
resources are required — and replays every scenario:

1. Each palette color's score (or `"excluded"` missing-measurement exclusion) is
   compared against the recorded per-candidate score table.
2. The selection is recomputed under the corpus's `earliest-index-wins` policy
   and compared against `selected_index`, `selected_hex_color`, `error`,
   `tie_broke`, and `tied_indices` — ties are deliberately included in the
   corpus and asserted exactly.
3. Each scenario is replayed end-to-end through `CompositionSolver` (the target
   vector becomes a 1×1 source grid per active channel), pinning the tie policy
   in the component that actually implements it.

The corpus is stamped with `algorithm_version` (currently `1`), `scorer`,
`selection`, and `missing_policy`. The metadata test fails on any stamp change:
a version bump means every expectation has moved and the app's scorer must be
re-validated against a regenerated corpus — the corpus, not this repo's
hand-written examples, defines expected behavior.

## Refreshing the corpus

After an upstream solver change bumps the corpus:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json
cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Record the upstream commit (and, ideally, its corpus SHA-256) in the PR so
reviewers can verify the copy is byte-identical. If the parity tests fail after
a refresh, the client and server scorers have diverged — fix the app (or flag
the upstream change) rather than editing the corpus locally.

## Relation to the OpenAPI generated client (issue #39)

The corpus enforces **solver** parity. The **API** contract is enforced in
tandem: the server publishes an OpenAPI 3 document at `GET /api/v1/openapi.json`
(viamin/color_matching#110), and `PaletteAPIClient` is migrating to a
swift-openapi-generated client built from it. `PaletteAPIClientContractTests`
pins the observable wire behavior of that migration — URL shapes, headers,
snake_case response envelopes, and the error taxonomy (`.unauthorized` on 401,
`.badStatus`, `.malformedResponse`) — so the generated client (or a wrapper
around one) cannot silently change behavior the disk-cache and
offline-fallback layers depend on.
