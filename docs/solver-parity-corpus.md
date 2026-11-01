# Solver parity corpus & OpenAPI contract consumption

This package enforces two contracts with the [`color_matching`](https://github.com/viamin/color_matching) server at test time:

1. **Solver parity** — `WeightedSquaredErrorScorer` must select exactly what the server's `ColorMatching.WeightedSquaredError` + earliest-wins selection would select, including ties and exclusions.
2. **Wire contract** — `PaletteAPIClient` must speak the `/api/v1` shape the server publishes as an OpenAPI document.

## Where the corpus lives

The parity corpus is *generated upstream* and *consumed here*:

| What | Where |
| --- | --- |
| Generator | `ColorMatching.Parity.Corpus` (`lib/color_matching/parity/corpus.ex`), deterministic; `mix parity.generate` rewrites it, CI checks the committed bytes with `mix parity.generate --check` |
| Published location | [`priv/parity/v1/corpus.json`](https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json) (viamin/color_matching#111) |
| Committed copy (this repo) | `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json` — byte-identical to the published file (24 995 bytes, algorithm version 1) |
| Replay test | `ColorComposerCore/Tests/ColorComposerCoreTests/SolverParityCorpusTests.swift` |

The corpus header pins the semantics it captures: `scorer: ColorMatching.WeightedSquaredError`, `selection: earliest-index-wins`, `missing_policy: excluded-when-any-positive-weight-channel-missing`, `algorithm_version: 1`.

### What the replay test asserts

For all 12 scenarios, per candidate index:

- the exact weighted squared-error score, or exclusion (missing measurement on any positively-weighted channel — candidate **or** target side),
- the selected index under earliest-index-wins, **including exact ties** (`tie-symmetric-around-target`, `tie-duplicate-vectors`, `tie-three-way-on-lps`, `mixed-large-palette`): the full `tied_indices` set, `tie_broke`, and the winning `error`,
- zero-weight channels neither exclude nor contribute (`zero-weight-channel-missing`),
- unknown light-source keys in the weights map are ignored (`unknown-weight-ignored` — `ultraviolet` carries weight 3.0 upstream and must be dropped),
- every scenario is also replayed through `CompositionSolver` on a 1×1 grid, so the production selection path (eligible filtering + strict `<` earliest-wins comparison, `excludedCandidateCount`, infinite error when nothing is eligible) honors the corpus, not just the scorer function.

The test additionally pins the corpus **scenario id list** and coverage shape (at least one tie, one three-way tie, one all-excluded, one exact match, …), so a corpus refresh that silently narrows coverage fails loudly.

### How to refresh the committed corpus

The corpus moves only when upstream scoring semantics change (upstream bumps `algorithm_version` then). To refresh:

```bash
# Option A — fetch the published bytes (requires the upstream default branch):
curl -fsSL https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json

# Option B — from a local server checkout (regenerates deterministically):
cd color_matching && mix parity.generate
cp priv/parity/v1/corpus.json ../ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/

cd ColorComposerCore && swift test --filter SolverParityCorpusTests
```

A deliberate refresh must update the pinned scenario-id list in `SolverParityCorpusTests.testCorpusCarriesPinnedScenarioSet` (and, if semantics changed, the pinned `algorithm_version`). Any scorer change on *this* side that diverges from the corpus fails `testScorerScoresMatchCorpusExactlyIncludingExclusions` / `testSelectionMatchesCorpusIncludingTieBreaking` — that is the point of the corpus.

## OpenAPI document consumption

The server publishes its OpenAPI 3 contract at `GET /api/v1/openapi.json` (viamin/color_matching#110; built by `ColorMatchingWeb.ApiSpec` from the router + `ApiSchemas`).

- A snapshot of the two operations this app consumes (`GET /api/v1/printer_profiles`, `GET /api/v1/colors`) is committed at `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/openapi/v1/openapi.json`, translated 1:1 from `lib/color_matching_web/api_spec.ex`, `api_schemas.ex`, and the `OpenApiSpex.ControllerSpecs` declarations in `color_palette_controller.ex`.
- `PaletteAPIContractTests.swift` binds `PaletteAPIClient` to that snapshot: request paths/method/`Accept`/trimmed bearer token, the required `printer_profile_id` query parameter, decoding of schema-conforming payloads, and the 401/`badStatus`/`malformedResponse` error mapping. These tests are the migration harness for the generated-client adoption (issue #39): they must stay green before and after the migration.
- `PaletteAPIContractTests.testPackageShipsOpenAPIDocumentForCodegen` fails until the package carries the `swift-openapi-generator` plugin, the `swift-openapi-runtime` dependency, and a committed OpenAPI document at a conventional path (`openapi.yaml` at the package root or `Sources/ColorComposerCore/OpenAPI/`).

### Refreshing the OpenAPI snapshot

```bash
# From a running server (any environment):
curl -fsSL "$COLOR_MATCHING_URL/api/v1/openapi.json" \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/openapi/v1/openapi.json

# Verify the drift-sensitive pins still hold:
cd ColorComposerCore && swift test --filter PaletteAPIContractTests
```

The snapshot deliberately contains only the two consumed operations; the upstream document additionally covers capture, measurement, and mapping endpoints this app does not use (non-goal per issue #39).

## `/api/v1` shape findings (for the issue #39 PR description)

Comparing the published contract with the hand-rolled DTO decoding in `APIModels.swift`:

- **No breaking shape changes.** Envelope keys (`printer_profiles`, `colors`, `printer_profile`) and snake_case field names match what `PaletteAPIClient` decodes today.
- The spec is **stricter than the client**: `name`, `palette_id`, `sort_order` on color items, `printer_profile` in `ColorsResponse`, and `printer_make_model`/`paper_type`/`ink_type` on `PrinterProfile` are all spec-*required*, while the client DTOs decode them as optionals. A generated client typed from the spec will reject payloads missing those fields; the hand-rolled decoder tolerates them. Keeping the lenient decoding behind the client boundary (wrap the generated client, feed the existing DTOs) preserves offline/legacy-cache compatibility.
- `palette_name` is explicitly nullable in the spec; the client already models it as `String?`.
- `rgb` is *optional* in the spec; the client falls back to parsing `hex` when absent — still required behavior.
- `/api/v1/colors` also accepts an optional `palette_id` query parameter (unused here); the app's single `printer_profile_id` parameter is spec-required with `minimum: 1`.
- The server routes wrong-verb requests on both paths to a `405` MethodNotAllowedController, and documents 400/401/404/422 on `/api/v1/colors`. The client already maps any non-2xx (other than 401) to `PaletteAPIError.badStatus`, which covers these.

## Parity findings (for the issue #39 PR description)

- `WeightedSquaredErrorScorer` matches all 12 corpus scenarios exactly at HEAD: per-candidate scores (all exact binary fractions), exclusions, tie sets, earliest-wins selection, and winning errors. No code changes were needed — the corpus test now enforces it permanently.
- Tie handling is exact-equality based (`sum < best`, strict less-than) on both sides, and corpus values are chosen as dyadic fractions so summation order cannot perturb ties.
- Weight handling: only positively-weighted channels are required and contribute; weight-0 channels never exclude; unknown light-source keys are dropped at the mapping boundary (`LightingCondition(rawValue:)`), verified by the `unknown-weight-ignored` scenario.
