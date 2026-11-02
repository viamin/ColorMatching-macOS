# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver, and `CompositionSolver` mirrors
the earliest-index-wins selection of `ColorMatching.IlluminantMatching` —
so the macOS client and the `color_matching` server always agree on which
palette color a given target selects.

That parity is **enforced, not assumed**: both sides replay the same
committed golden-vector corpus (introduced by viamin/color_matching#111,
merged as viamin/color_matching#112).

## Where the corpus lives

- **Server (source of truth):** `priv/parity/v1/corpus.json` in
  [viamin/color_matching](https://github.com/viamin/color_matching), generated
  deterministically by `lib/color_matching/parity/corpus.ex`
  (`mix parity.generate`; CI verifies the committed bytes with
  `mix parity.generate --check`).
- **This repo (consumed copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json`,
  byte-identical to the server copy (sha256 recorded below) and replayed by
  `SolverParityCorpusTests.swift`.

## What the test enforces

`SolverParityCorpusTests` (`swift test` in `ColorComposerCore`) asserts, for
every scenario in the corpus:

- **Per-candidate scores match exactly** (numeric within `1e-12`; the corpus
  marks excluded candidates with the string `"excluded"` instead of a number).
- **Selections match exactly, including tie cases**: lowest score wins, and on
  an exact tie the earliest palette index wins (`selection:
  "earliest-index-wins"`). The corpus contains dedicated two-way, duplicate
  -vector, and three-way tie scenarios plus a large mixed palette with an
  8-color tie — removing any of them fails the suite.
- **Exclusions match**: a candidate *or target* missing a measurement for any
  positive-weight light source is excluded — never treated as zero brightness
  (`missing_policy:
  "excluded-when-any-positive-weight-channel-missing"`).
- **Weight handling matches**: zero-weight channels are ignored (a missing
  measurement there does not exclude), and unknown light-source keys in the
  weights map are dropped, mirroring `WeightedSquaredError.filter_weights/1`
  (the corpus's `ultraviolet` key exercises this).
- **End-to-end solver parity**: scenarios whose target carries every
  positive-weight channel are also run through `CompositionSolver().solve` on
  a 1×1 grid — the fast path the app actually uses — asserting the selected
  index, winning error, and excluded-candidate count.

The test also pins the corpus metadata (`algorithm_version`, `scorer`,
`selection`, `missing_policy`) and the scenario count. When the server bumps
`algorithm_version` (scoring semantics changed), this suite fails loudly:
refresh the fixture and review the deltas together instead of silently
re-interpreting new expectations.

One representation difference is intentional: the corpus's
`missing-target-excluded` scenario expresses "the *target* is missing a
positive-weight channel", which `BrightnessGrid` cannot represent (a grid
always supplies values). The test pins that scenario at scorer level (every
candidate excluded, no selection); in the app the equivalent state surfaces
as a solver configuration error (no source image assigned to an active
channel) rather than a silent zero.

## Refreshing the corpus

The corpus is only refreshed when solver semantics change on the server
(`algorithm_version` bump). To pull a new version:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/Parity/v1/corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Notes:

- `priv/parity/v1/corpus.json` is deterministic — the same server commit always
  produces identical bytes, so a refresh diff is meaningful.
- If the server bumps the version directory (`v1` → `v2`), copy the new file
  to a matching `Fixtures/Parity/v2/` directory and update the fixture URL in
  `SolverParityCorpusTests` rather than overwriting history.
- If parity fails after a refresh, the *client* is what needs fixing (or the
  semantics genuinely diverged) — never edit the corpus locally to make the
  test pass; it is generated exclusively by the server repo.

### Current fixture provenance

| Field | Value |
| --- | --- |
| Source | `viamin/color_matching@main` `priv/parity/v1/corpus.json` |
| `algorithm_version` | 1 |
| `scorer` | `ColorMatching.WeightedSquaredError` |
| Scenarios | 12 (5 with tie-breaking, 4 with exclusions) |
| SHA-256 | `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604` |

> README note: when the generated-client migration (issue #39) lands, fold a
> short "Solver parity" section into the root `README.md` pointing here.
