# Solver parity corpus

This repo's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver in
[`color_matching`](https://github.com/viamin/color_matching) so the macOS client
and the server always agree on color selection. The server publishes a
deterministic golden-vector corpus that this repo consumes as a test fixture to
enforce that parity (viamin/color_matching#111).

## Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  `viamin/color_matching`, regenerated with `mix parity.generate` (the server's
  CI verifies the committed copy with `mix parity.generate --check`).
- **This repo (consumed copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`,
  kept byte-identical to upstream (sha256
  `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`).

## How to refresh it

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

The corpus is stamped with `algorithm_version` (currently `1`). When that number
changes, every expectation has moved: the scorer and the fixture must be updated
in the same change, and `SolverParityCorpusTests.testCorpusStampMatchesImplementedContract`
fails until they are.

## How it is consumed

`SolverParityCorpusTests` (in `ColorComposerCore/Tests/ColorComposerCoreTests/`)
decodes the fixture and replays every scenario through
`WeightedSquaredErrorScorer`: each palette color is scored against the scenario
target with the scenario weights, then the client asserts **exact** agreement
with the recorded

- per-candidate score table (an `"excluded"` marker encodes the
  missing-measurement exclusion),
- selected index and hex color (ties resolve **earliest-index-wins**, matching
  `ColorMatching.IlluminantMatching`),
- total error of the selected candidate,
- tie evidence (`tie_broke`, `tied_indices`).

Every corpus value is an exact binary fraction (a multiple of 1/256), so
comparisons use exact `Double` equality — any bit of drift fails the test.

## Parity findings (corpus v1, algorithm_version 1)

All 12 scenarios replay green against the current Swift scorer:

| Scenario | What it pins |
| --- | --- |
| `distinct-errors` | straightforward minimum-error selection |
| `tie-symmetric-around-target` | two-way tie broken by earliest index |
| `tie-duplicate-vectors` | duplicate response vectors tie, earliest wins |
| `tie-three-way-on-lps` | three-way tie on a single active channel |
| `missing-candidate-excluded` | candidate missing a weighted channel is excluded, not zero-filled |
| `missing-target-excluded` | target missing a weighted channel excludes **every** candidate (no selection) |
| `zero-weight-channel-missing` | weight-zero channels are not required; missing measurements there do not exclude |
| `all-excluded` | no survivors → `selected_index`/`error`/`tie_broke` are null |
| `single-channel-lps` | single-channel weights |
| `exact-match-zero-error` | exact match scores 0 |
| `unknown-weight-ignored` | unknown weight keys (`ultraviolet`) are ignored, not rejected and not required |
| `mixed-large-palette` | combined ties + exclusions in one palette |

Summary: tie handling (earliest-index-wins), exclusion policy
(`excluded-when-any-positive-weight-channel-missing`), and unknown/zero-weight
handling all agree between the Swift scorer and the Elixir solver.

README note: the "Solver parity corpus" section of the upstream README describes
the same consumption contract for this client.
