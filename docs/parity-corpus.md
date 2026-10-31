# Solver parity corpus & generated OpenAPI client

Working notes for issue #39: consuming `color_matching`'s published parity
corpus (viamin/color_matching#111) and OpenAPI spec (viamin/color_matching#110)
from this repository. The README should link here once the implementation
lands; this document is the canonical reference in the meantime.

## Solver parity corpus

### Where the corpus lives

- **This repo (committed fixture):** `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
- **Upstream source of truth:** [`priv/parity/v1/corpus.json`][upstream-corpus]
  in `viamin/color_matching`, generated deterministically by
  [`ColorMatching.Parity.Corpus`][corpus-module] via `mix parity.generate`
  (viamin/color_matching#111).

The local fixture is a **byte-identical copy** of the upstream file (same
sha256). The `v1` path segment tracks the corpus `algorithm_version` field
(currently `1`); upstream bumps that version whenever scoring semantics
change, at which point the fixture must be re-copied into a new versioned
directory.

### What the parity suite asserts

`SolverParityCorpusTests.swift` (in the `ColorComposerCoreTests` target)
mirrors the server-side `ColorMatching.Parity.CorpusTest`:

1. **Fixture integrity** — the corpus is committed, decodable, stamped with
   `algorithm_version: 1`, `scorer: ColorMatching.WeightedSquaredError`,
   `selection: earliest-index-wins`, and the canonical light-source order
   `white, red, green, blue, lps` (the same order as
   `LightingCondition.allCases`).
2. **Corpus self-coverage** — it still contains intentionally tied scenarios,
   all-excluded scenarios, and per-candidate `"excluded"` outcomes, so it
   cannot silently degrade into a corpus that no longer guards parity.
3. **Exact replay** — every scenario replays through
   `WeightedSquaredErrorScorer` with the client-side mirror of
   `IlluminantMatching.best_match/4` (earliest index wins on ties) and must
   match the server-computed expectations **exactly**:
   - per-candidate scores (bit-identical doubles — every corpus value is an
     exactly representable dyadic rational, so no epsilon is used — or the
     `"excluded"` marker),
   - the selected index, hex color, and winning error,
   - tie evidence: the full tied-index set, whether a tie was broken, and
     that the winner is the earliest member of the tied set.

Covered behaviors include: exact ties (symmetric around the target,
duplicate vectors, three-way ties), missing-measurement exclusion on the
candidate **and** the target, zero-weight channels neither excluding nor
contributing, unknown light-source weight keys being ignored, and exact-match
zero-error selection.

### Refreshing the corpus

```bash
curl -fsSL \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json \
  -o ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json

cd ColorComposerCore && swift test --filter SolverParityCorpus
```

Never hand-edit the fixture; it is regenerated upstream with
`mix parity.generate` (upstream CI enforces byte-stability with
`mix parity.generate --check`). If replay fails after a refresh, the scorer
has genuinely diverged from the server — fix the divergence or bump the
fixture directory/`algorithm_version` together with an upstream bump.

> Note for the implementation run: `Package.swift` should declare the
> `Fixtures` directory as a `.copy` resource for the test target so the
> loader can eventually move from `#filePath`-relative resolution to
> `Bundle.module`. The `#filePath`-relative loader works today under both
> `swift test` and the Xcode-generated project without any package change.

## Generated OpenAPI client

The migration (implementation phase) generates a typed client from the
OpenAPI document published by viamin/color_matching#110:

1. Export the document from a running server: `GET /api/openapi.json`
   (rendered by `ColorMatchingWeb.ApiSpec` / OpenApiSpex).
2. Commit it at `openapi/color-matching.json` (repo root) — see
   `OpenAPIDocumentTests.swift` for the accepted locations.
3. Add `swift-openapi-generator` (plugin) + `swift-openapi-runtime`
   dependencies to `ColorComposerCore/Package.swift` and generate the client
   target from the committed document.
4. Migrate `PaletteAPIClient` onto it (or wrap it), keeping the observable
   contract pinned by `PaletteAPIClientContractTests`:
   - `GET /api/v1/printer_profiles` and `GET /api/v1/colors?printer_profile_id=N`
     with `Accept: application/json`,
   - trimmed `Authorization: Bearer <token>` header, omitted when the token is
     blank; HTTP 401 → `PaletteAPIError.unauthorized` (re-auth flow trigger),
   - snake_case envelopes and merged response provenance (human responses
     priority over instrument measurements) decoded into the same DTOs,
   - non-2xx → `.badStatus`, undecodable body → `.malformedResponse`.

Because `ProfileColorCache` persists those same DTOs in their snake_case wire
format, **decoding drift breaks existing disk caches** — the contract tests
plus the existing `ProfileColorCacheTests` suite are the regression net for
the offline-stale badge and cached-profile fallback flows.

No `/api/v1` shape changes were found while pinning the contract: the
envelopes (`printer_profiles`, `printer_profile` + `colors`), nullable
fields, and response detail keys all match `ColorPaletteController` on
upstream `main`.

## Acceptance criteria → verification mapping

| Criterion | Verification | Where |
| --- | --- | --- |
| Generated OpenAPI client adopted; `PaletteAPIClient` migrated with cache/offline behavior intact | Wire-contract tests that must stay green across the migration | `PaletteAPIClientContractTests.swift`, existing `PaletteAPIClientTests.swift`, existing `ProfileColorCacheTests.swift` |
| OpenAPI document committed as the generation source | Document presence + endpoint/bearer coverage test (red until committed) | `OpenAPIDocumentTests.swift` |
| Parity corpus consumed; `WeightedSquaredErrorScorer` selections match expected outputs exactly, including ties | Corpus replay suite over the committed fixture | `SolverParityCorpusTests.swift` + `Fixtures/parity/v1/corpus.json` |
| Corpus consumption documented | This document (README link to be added by the implementation run) | `docs/parity-corpus.md` |
| PR description records migration notes, `/api/v1` findings, parity results | Summarized above under "Generated OpenAPI client"; parity status: 12/12 scenarios replay with exact agreement (verified pre-commit in IEEE-754 arithmetic against the upstream corpus bytes) | PR body |

[upstream-corpus]: https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json
[corpus-module]: https://github.com/viamin/color_matching/blob/main/lib/color_matching/parity/corpus.ex
