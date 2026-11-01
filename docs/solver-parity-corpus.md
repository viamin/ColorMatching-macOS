# Solver parity corpus

`ColorComposerCore`'s `WeightedSquaredErrorScorer` deliberately mirrors the
Elixir `ColorMatching.WeightedSquaredError` solver, and `CompositionSolver`
mirrors `ColorMatching.IlluminantMatching`'s earliest-index-wins selection.
The parity corpus is the shared golden-vector fixture both test suites replay
so silent divergence — tie-breaking, missing-measurement exclusion, or channel
weighting — is caught on either side.

## Where the corpus lives

- **Source of truth:** [`viamin/color_matching`](https://github.com/viamin/color_matching)
  at `priv/parity/v1/corpus.json`, generated deterministically by
  `mix parity.generate` (byte-identical on every run; upstream CI verifies the
  committed bytes with `mix parity.generate --check`). See
  `lib/color_matching/parity/corpus.ex` there for the schema and scenario
  definitions.
- **This repo:** the corpus is committed as a test fixture at
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
  and loaded by `SolverParityCorpusTests` **by path** (relative to
  `#filePath`), because SwiftPM does not copy undeclared files into the test
  bundle. SwiftPM emits an "unhandled file" *warning* for it; declaring
  `resources: [.copy("Fixtures")]` in `ColorComposerCore/Package.swift`
  (planned alongside the OpenAPI client work, which already touches the
  manifest) silences the warning — the path-based load keeps working either
  way.

Current fixture: `algorithm_version` **1**, `scorer`
`ColorMatching.WeightedSquaredError`, `selection` `earliest-index-wins`,
`missing_policy` `excluded-when-any-positive-weight-channel-missing`,
12 scenarios. SHA-256 of the committed bytes:
`7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604`.

## What the Swift test asserts

`SolverParityCorpusTests` (in `ColorComposerCore/Tests/ColorComposerCoreTests`)
replays every scenario two ways and asserts **exact** agreement with the
expected outputs (all corpus values are dyadic rationals, so double arithmetic
is exact and order-independent):

1. **Scorer replay** — every palette candidate is scored with
   `WeightedSquaredErrorScorer.score(candidate:target:weights:)`, then
   earliest-index-wins selection is applied. Asserted per scenario:
   per-candidate scores (including the `"excluded"` marker), `selected_index`,
   `selected_hex_color`, `tied_indices`, `tie_broke`, and the winner `error`
   (or no winner at all).
2. **Solver replay** — scenarios whose target covers every positive-weight
   channel are also run through `CompositionSolver`'s optimized contiguous
   fast path on a 1×1 grid, asserting selection, per-cell error, unmatched
   cells, and the excluded-candidate count. (A target missing a
   positive-weight channel models "no source image assigned" in the app and
   never reaches the solver, so those scenarios replay through the scorer
   only.)

The suite also guards the fixture itself: scenario ids are unique, every
candidate carries an expected score, the light-source set matches
`LightingCondition`, and the corpus keeps scenarios covering exact ties,
excluded candidates losing to measurable winners, unmatchable targets, and
unknown light-source weight keys (dropped, mirroring the server's
`filter_weights/1`).

## How to refresh the fixture

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json
```

(or copy the file from a server checkout after running `mix parity.generate`
there — the output is deterministic). Then:

1. Check `algorithm_version` in the refreshed file. If it changed, scoring
   semantics moved: bump `SolverParityCorpusTests.supportedAlgorithmVersion`
   to match — the metadata test fails otherwise, on purpose.
2. Run `swift test` (or `bin/lint`, which runs it) — every scenario must
   still pass exactly. A failure means the client scorer/selection semantics
   diverged from the corpus, which is precisely what this suite exists to
   catch.

The fixture refresh is manual on purpose: it is a deliberate contract update,
reviewed through the parity tests, not an automatic download.

## Related `/api/v1` findings (viamin/color_matching#110 / #111 era)

Recorded for the generated-client migration notes:

- The server now publishes an OpenAPI document at
  `GET /api/v1/openapi.json` (OpenApiSpex, `bearerAuth` security). It is
  generated at runtime — there is no static spec file in the server repo to
  vendor, so the generated-client work needs to export it from a running
  server (or the server repo) first.
- The legacy `GET /api/v1/colors?printer_profile_id=N` route the app uses
  today is unchanged in shape: envelope `{printer_profile, colors[]}` with
  snake_case keys and the same nullable provenance fields the client decodes.
  Upstream now *prefers* `GET /api/v1/printer_profiles/:printer_profile_id/colors`
  for composer-facing retrieval; its colors carry no palette metadata
  (`id`, `palette_id`, `palette_name`, `sort_order` absent), so switching
  routes is a behavior decision, not part of the parity corpus.
