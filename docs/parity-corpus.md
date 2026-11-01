# Solver parity corpus consumption

This app's `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
`ColorMatching.WeightedSquaredError` solver and the earliest-wins selection of
`ColorMatching.IlluminantMatching` ("so client and server agree on selection").
The `color_matching` server publishes a deterministic golden-vector corpus that
is the shared source of truth both test suites replay, so silent divergence —
tie-breaking, missing-measurement exclusion, or channel weighting — is caught.

*(This note is the tests-phase companion to issue #39; the implementation run
should fold a shorter version of it into the root `README.md`.)*

## Where the corpus lives

- **Upstream (source of truth):** `priv/parity/v1/corpus.json` in
  [`viamin/color_matching`](https://github.com/viamin/color_matching)
  (issue #111, landed as PR #112; regenerate upstream with `mix parity.generate`,
  byte-determinism enforced by upstream CI).
- **This repo (vendored copy):**
  `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
  — byte-identical copy, committed so `swift test` runs offline and every
  checkout pins the exact corpus revision it was validated against.

The fixture is loaded by `ParityCorpusTests.swift` via a `#filePath`-relative
path (no `Package.swift` resource declaration needed, so it also works under
`bin/lint`'s Linux harness).

## How to refresh

1. Pull the new corpus from upstream
   (`https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json`)
   and copy it over the vendored fixture — byte for byte, do not reformat.
2. Check `algorithm_version`. If it changed, **every expectation in the corpus
   has moved**: the scorer semantics changed upstream, and this app must adopt
   the matching semantics in the same PR (the parity suite will fail until it
   does — that is its job). `ParityCorpusTests.supportedAlgorithmVersion` must
   be bumped in lockstep.
3. Run `cd ColorComposerCore && swift test`. All 12 scenarios must replay with
   bit-exact scores, selections, errors, and tie indices.

Upstream refresh cadence is upstream-driven: this repo refreshes whenever the
server PR changes the solver or bumps `algorithm_version`.

## What the corpus covers (parity findings, corpus v1)

All values in the corpus are dyadic rationals, so Elixir and Swift IEEE-754
doubles compute identical results and the suite asserts **exact** equality
(no tolerance):

| Class | Scenarios | Verified semantics |
| --- | --- | --- |
| Distinct errors | `distinct-errors`, `mixed-large-palette` | weighted sum `Σ (c−t)²·w` over active channels |
| Exact ties (earliest index wins) | `tie-symmetric-around-target`, `tie-duplicate-vectors`, `tie-three-way-on-lps`, `zero-weight-channel-missing` | strict `<` comparison ⇒ first of the tied set wins; `tie_broke`/`tied_indices` evidence replayed exactly |
| Missing candidate measurement | `missing-candidate-excluded`, `mixed-large-palette` | missing positive-weight channel ⇒ `excluded`, never treated as brightness 0 |
| Missing target measurement | `missing-target-excluded` | target missing a positive-weight channel ⇒ every candidate excluded, no selection (`selected_index`/`error`/`tie_broke` = `null`) |
| All candidates excluded | `all-excluded` | no selection exists |
| Zero-weight channels | `zero-weight-channel-missing` | unweighted channels neither exclude nor contribute (missing vs. wildly-off tie exactly) |
| Single active channel | `single-channel-lps` | unmeasured zero-weight channels ignored; exact match scores `0.0` |
| Unknown light sources in weights | `unknown-weight-ignored` | non-canonical keys (e.g. `ultraviolet`) ignored; score table identical to the canonical twin scenario |
| Exact match | `exact-match-zero-error` | channel-for-channel clone scores `0.0` |

Replay result at the time of writing: **12/12 scenarios match bit-exactly**
against the current `WeightedSquaredErrorScorer` (also cross-validated with an
independent exact-arithmetic replay during test development).

## Acceptance-criterion → verification map (issue #39)

| Criterion | Verification | Where |
| --- | --- | --- |
| Generated OpenAPI client keeps `PaletteAPIClient`'s `/api/v1` wire behavior (URLs, bearer header, envelope decode, error mapping) | Focused unit tests pinning the transport contract; must stay green across the migration | `ColorComposerCore/Tests/ColorComposerCoreTests/PaletteAPIClientTests.swift` |
| DTO decoding conforms to the published OpenAPI shapes (required fields, nullable `palette_name`, optional `rgb`) | Focused decoding tests | `ColorComposerCore/Tests/ColorComposerCoreTests/APIDecodingTests.swift` |
| Per-server/profile disk caching, offline-stale fallback, cached profile fallback unchanged | Existing unit suite (no source changes; suite is the regression net) | `ColorComposerCore/Tests/ColorComposerCoreTests/ProfileColorCacheTests.swift` (69 tests) |
| `WeightedSquaredErrorScorer` selections match the corpus exactly, including ties | Corpus replay suite (permanent) | `ColorComposerCore/Tests/ColorComposerCoreTests/ParityCorpusTests.swift` + vendored fixture |
| Corpus consumption documented | This document (fold into `README.md` during the implementation run) | `docs/parity-corpus.md` |

Notes for the implementation run:

- `swift-openapi-generator`/`swift-openapi-runtime` wiring, the OpenAPI
  document, and the `PaletteAPIClient` migration are implementation-phase
  work; the transport tests above are the acceptance net for it.
- The server serves its spec at `GET /api/v1/openapi.json`; `/api/v1` shape
  review vs the current DTOs found **no breaking differences** — the DTOs are
  strictly more lenient than the spec requires (spec-required fields
  `name`/`palette_id`/`sort_order` are optional in the DTOs; spec-nullable
  `palette_name` maps to a Swift optional).
