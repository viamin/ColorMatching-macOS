# Solver parity corpus

`v1/corpus.json` is a **verbatim copy** of the solver parity corpus published by
the `color_matching` server:

| | |
| --- | --- |
| Upstream repository | [`viamin/color_matching`](https://github.com/viamin/color_matching) |
| Upstream path | `priv/parity/v1/corpus.json` |
| Upstream dependency | [`viamin/color_matching` #111](https://github.com/viamin/color_matching/issues/111) |
| Upstream generator | `mix parity.generate` (Elixir, in `color_matching`) |
| Upstream CI check | `mix parity.generate --check` fails when the committed bytes drift |
| Copied on | 2026-11-03 (corpus `algorithm_version` 1) |
| SHA-256 | `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604` |
| Size | 23 995 bytes |

The corpus is the shared golden-vector source of truth for the Elixir
`ColorMatching.WeightedSquaredError` scorer plus the earliest-wins selection of
`ColorMatching.IlluminantMatching`, and for this app's mirrored
`WeightedSquaredErrorScorer`. `SolverParityTests` replays it.

## Why the copy lives here

The Swift package is consumed by the Xcode app target, which has no Elixir
toolchain and no running server, so the corpus is committed next to the tests
that replay it. The bytes are never edited by hand: they are replaced wholesale
when the upstream corpus is refreshed.

## Refreshing the corpus

1. In a checkout of `viamin/color_matching`, regenerate (or take the committed
   file) of the corpus for the current algorithm version:

   ```bash
   mix parity.generate          # writes priv/parity/v1/corpus.json
   mix parity.generate --check  # CI guard: fails when the committed bytes drift
   ```

2. Copy the regenerated file over this one, keeping the directory layout
   (`priv/parity/v1/` → `ColorComposerCore/Tests/Fixtures/parity/v1/`):

   ```bash
   cp /path/to/color_matching/priv/parity/v1/corpus.json \
      ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json
   ```

3. Update the table above (copied-on date, SHA-256, size) and the
   `expectedSHA256` / expected metadata constants in
   `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityTests.swift`.

4. Run the parity tests:

   ```bash
   cd ColorComposerCore && swift test --filter SolverParityTests
   ```

If the upstream `algorithm_version` changed, the scoring semantics changed and
every expectation in the corpus moved — the parity test fails loudly instead of
silently accepting a different algorithm.
