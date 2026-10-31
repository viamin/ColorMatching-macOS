# Solver parity corpus

This package's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver (plus the earliest-wins selection of
`ColorMatching.IlluminantMatching`) in [`viamin/color_matching`](https://github.com/viamin/color_matching).
The **parity corpus** is the server-generated golden-vector fixture both test suites replay so silent
divergence — tie-breaking, missing-measurement exclusion, or channel weighting — is caught.

## Where the corpus lives

| What | Where |
| --- | --- |
| Committed fixture (consumed by tests) | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json` |
| Upstream source of truth | `priv/parity/v1/corpus.json` in `viamin/color_matching` |
| Upstream generator | `lib/color_matching/parity/corpus.ex` + `mix parity.generate` |
| Provenance of the committed copy | `viamin/color_matching@main` (landed as PR #112, closes #111; commit `a82aec5441d2`), byte-identical — sha256 `7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604` (verified against `https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`) |

The fixture filename is versioned (`parity-v{algorithm_version}-corpus.json`); the corpus's
`algorithm_version` field is bumped upstream whenever scoring semantics change, and the
loader constant in `SolverParityCorpusTests.swift` must move with it.

## How to refresh

1. In a checkout of `viamin/color_matching`:
   ```bash
   mix parity.generate          # writes priv/parity/v1/corpus.json (deterministic)
   mix parity.generate --check  # CI guard: fails if the committed fixture drifted
   ```
2. Copy the artifact byte-for-byte into
   `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity-v1-corpus.json`
   (if `algorithm_version` changed, rename both fixture and loader constant first, and keep the old file only if backwards compatibility is being tested).
3. Run `cd ColorComposerCore && swift test` — the parity suite must stay green
   with zero code changes; any red indicates real solver drift, not a stale fixture.

Verify the copy with `sha256sum` against the upstream file before committing.

## What the parity test asserts

`ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` loads the
fixture and, for every scenario (12 in v1):

- **Per-candidate scores** from `WeightedSquaredErrorScorer` match `expected.scores` exactly
  (float scores within 1e-12; the literal `"excluded"` maps to `ScorerResult.excluded`).
- **Selection** — replicating `IlluminantMatching.best_match/4` (reject excluded, minimum
  score, earliest index wins) — matches `expected.selected_index`, `selected_hex_color`,
  and `error`; `nil` selection when every candidate is excluded.
- **Ties** — the recomputed set of indices sharing the minimum score matches
  `tied_indices`, and `tie_broke` matches "more than one tied index", including the
  three-way LPS tie and the duplicate-vector tie.
- **Solver end-to-end** — each replayable scenario is also solved through
  `CompositionSolver` as a 1×1 composition; the selected cell index, cell error, and
  excluded-candidate count must match the corpus. (Scenarios whose *target* is missing a
  positive-weight channel can only be expressed at the scorer level and are skipped for
  the solver leg — source grids always carry values.)
- **Corpus invariants** — version, canonical light sources, missing-data policy string,
  scorer/selection policy strings, unique scenario ids, and coverage of every category
  (tie, exclusion, zero-weight channel, unknown weight key, exact match, nil selection).

### Parity findings baked into the corpus (record these in the PR description)

- **Ties** break to the earliest palette index on both sides (`Enum.min_by` keeps the
  first minimum; the Swift solver uses strict `<` while scanning in order).
- **Exclusions** — a candidate *or target* missing a measurement for any channel with
  weight `> 0` is excluded, never treated as zero brightness
  (`missing_policy: excluded-when-any-positive-weight-channel-missing`).
- **Weights** — zero-weight channels neither exclude nor contribute; unknown light-source
  keys in the weights map (e.g. `ultraviolet`) are filtered exactly like the Elixir
  `filter_weights/1` (the Swift `ChannelWeights` has no field for them, so the loader drops them).
- **Float parity** — corpus values are dyadic rationals, so score sums are exact in
  `Double` despite different accumulation order (Elixir map order vs canonical
  `[white, red, green, blue, lps]`); the 1e-12 tolerance is a guard, not a necessity.

## Acceptance-criterion → verification map (issue #39)

| Criterion | Verification | Locator |
| --- | --- | --- |
| Generated OpenAPI client in place (`swift-openapi-generator` + runtime) | Structural guard test (fails until adopted) | `Tests/ColorComposerCoreTests/GeneratedClientAdoptionTests.swift` |
| `PaletteAPIClient` migrated, behavior preserved (endpoints, headers, auth, errors, decoding) | Contract tests against the public client surface via stubbed `URLSession` | `Tests/ColorComposerCoreTests/PaletteAPIClientContractTests.swift` |
| Disk cache / offline-stale / cached-profile fallback unchanged | Existing permanent suite (unchanged by this work) | `Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` |
| Solver parity with the committed corpus, including ties | Corpus replay suite (permanent) | `Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` + `Fixtures/parity-v1-corpus.json` |
| Corpus consumption documented | This document (merge the "where/how" sections into `README.md` in the implementation run — `README.md` sits outside this phase's edit allowlist) | `docs/solver-parity-corpus.md` |
| PR description records migration notes + `/api/v1` shape findings + parity results | Human/assembled evidence at PR time — pull findings from this file and the contract tests | PR body |

Note on the "parity test target" wording: the corpus suite currently lives as its own file
inside the existing `ColorComposerCoreTests` target because splitting out a dedicated
SwiftPM test target requires editing `Package.swift` (an implementation-path change).
The implementation run may split it into `SolverParityTests` verbatim; the fixture loader
resolves the file either by test-bundle resource or by `#filePath`, so the move is mechanical.

Related `Package.swift` follow-through for the implementation run: `swift build` only
*warns* about the undeclared `Tests/ColorComposerCoreTests/Fixtures/` resource files, and
the loader's `#filePath` fallback means the suite passes regardless — but declaring
`resources: [.copy("Fixtures")]` on the test target silences the warning and makes the
bundle-resource lookup path the one that runs.
