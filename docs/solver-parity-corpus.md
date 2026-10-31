# Solver parity corpus

`WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver so the macOS app and the
`color_matching` server always agree on palette-color selection. That promise
is enforced, not assumed: this repository replays the **golden-vector parity
corpus** the server generates, and fails CI the moment the two implementations
diverge.

## Where the corpus lives

- **Upstream (source of truth):** [`priv/parity/v1/corpus.json`][upstream] in
  `viamin/color_matching` (issue [#111][issue-111], landed in [#112][pr-112]).
  It is produced by the upstream `mix parity.generate` task, which runs the
  Elixir solver over a deterministic scenario set; upstream CI re-generates it
  and requires a byte-identical result, so the corpus cannot drift silently.
- **This repo (consumed copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-corpus-v1.json`
  — a verbatim copy of the upstream file (upstream commit `a82aec5`).

## How the tests consume it

`SolverParityCorpusTests` (same directory) loads the fixture with
`JSONDecoder` and replays every scenario in two layers:

1. **Scorer level** — each candidate is scored by `WeightedSquaredErrorScorer`
   and compared against the corpus's expected `scores` entries (exact match;
   exclusions must be exclusions), then the selection is recomputed with the
   corpus's declared `earliest-index-wins` policy and compared against
   `selected_index`, `selected_hex_color`, `error`, `tied_indices`, and
   `tie_broke`.
2. **Solver level** — every scenario expressible as source grids (all but
   `missing-target-excluded`, whose target itself lacks a required channel —
   impossible to author via source images) is replayed through
   `CompositionSolver` on a 1×1 grid, exercising the production fast path's
   tie-breaking and exclusion.

The fixture is located relative to the test file (`#filePath`), so it runs
under plain `swift test` without a bundle-resource declaration. The corpus is
decoded through its own `Decodable` model with explicit snake_case
`CodingKeys` — independent of the API client's decoding strategies — and a
**stamp test** first asserts the corpus still declares the semantics we
consumed: `algorithm_version == 1`, `scorer ==
"ColorMatching.WeightedSquaredError"`, `selection == "earliest-index-wins"`,
`missing_policy ==
"excluded-when-any-positive-weight-channel-missing"`, and the five canonical
light sources. If upstream revises any of those, the stamp test fails and the
fixture must be refreshed and re-reviewed rather than silently replayed.

## Refreshing the fixture

```bash
curl -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-corpus-v1.json \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

Upstream may append scenarios freely (the replay tolerates growth); anything
else — a shrunk scenario list, a changed stamp, or changed expectations —
should be treated as a semantic change and reviewed before the fixture is
committed.

## What the corpus pins (v1 findings)

Replay results at the time this fixture was committed (all 12 scenarios agree,
bit-for-bit on scores):

- **Ties** — five scenarios end in ties (a symmetric pairwise tie, a
  duplicate-vector pair, a three-way tie on `lps`, a zero-weight tie, and a
  larger mixed-palette tie). All resolve to the earliest palette index,
  matching `IlluminantMatching.best_match/4` and the Swift solver's strict
  `<` comparison.
- **Exclusions** — a candidate missing *any* positively-weighted channel is
  excluded and never scored as if the channel were zero; `all-excluded`
  produces no selection at all, and a target missing a required channel
  excludes every candidate.
- **Weight handling** — zero-weight channels neither exclude nor contribute
  (`zero-weight-channel-missing` ties a missing-blue candidate with a measured
  one), and unknown light-source keys in the weights map (`ultraviolet`) are
  ignored outright.
- **Exactness** — all corpus values are dyadic rationals, so Swift `Double`
  arithmetic reproduces every expected score exactly (asserted to 1e-12).

## Relationship to the OpenAPI client work

Issue #39 also migrates `PaletteAPIClient` to a client generated from the
OpenAPI 3 document the server now publishes at `GET /api/v1/openapi.json`
(viamin/color_matching [#110][issue-110], landed in [#113][pr-113]).
`PaletteAPIContractTests` pins the wire contract of the two `/api/v1` routes
the app uses — including the offline disk-cache round-trip — as the migration
safety net. Shape findings against that spec: `rgb` is optional and
`palette_name` is nullable in every color item (the Swift DTO already treats
them so), while `name` (per color) and the `printer_profile` envelope are
spec-required yet optional in the Swift DTO — the migration must keep decoding
real server payloads, and those tolerances are the only places the Swift model
is looser than the published spec.

[upstream]: https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json
[issue-111]: https://github.com/viamin/color_matching/issues/111
[pr-112]: https://github.com/viamin/color_matching/pull/112
[issue-110]: https://github.com/viamin/color_matching/issues/110
[pr-113]: https://github.com/viamin/color_matching/pull/113
