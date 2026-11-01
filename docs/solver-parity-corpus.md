# Solver parity corpus & the generated OpenAPI client

Working notes for issue #39 (adopt the generated OpenAPI client and enforce
solver parity with the parity corpus). The README-facing summary of corpus
consumption belongs in `README.md`; until the implementation change set
lands, this document is the source to fold in.

## Solver parity corpus

### What the corpus is

The `color_matching` server commits a deterministic golden-vector corpus at
`priv/parity/v1/corpus.json` (viamin/color_matching#111; see the server
README section “Solver parity corpus (macOS clients)”). Every scenario
records palette response vectors, a target vector, channel weights, and the
**Elixir solver's** expected output: the per-candidate score table
(`"excluded"` marks missing-measurement exclusions), the selected candidate
and its error, and explicit tie evidence (`tie_broke`, `tied_indices`).
Ties, exclusions, zero-weight channels, unknown weight keys, and
no-selection cases are all intentionally present.

The corpus is stamped with an `algorithm_version` (currently `1`). When that
number changes, every expectation has moved: refresh the mirror **and**
confirm `WeightedSquaredErrorScorer` matches the new semantics before
updating `implementedAlgorithmVersion` in the test.

### Where the mirror lives

```
ColorComposerCore/Tests/ColorComposerCoreTests/
├── Fixtures/ParityCorpus/
│   ├── v1/corpus.json        # byte-for-byte mirror of priv/parity/v1/corpus.json
│   └── verify_corpus.py      # independent replay used to sanity-check a refresh
└── SolverParityCorpusTests.swift
```

The mirror keeps the server's versioned layout (`v1/`, `v2/`, …); the test
replays the **newest** version directory present.

### How the tests consume it

`SolverParityCorpusTests` resolves the fixture from `#filePath` (the
checkout on disk), replays every scenario through
`WeightedSquaredErrorScorer` plus the earliest-wins selection, and asserts
**exact** agreement — scores, selection, error, and tie indices. Exact
double equality is deliberate: every corpus value is a dyadic rational, so a
faithful implementation reproduces the server's doubles bit-for-bit and any
drift is itself a parity bug.

It also pins the corpus stamps (`scorer`, `selection`, `missing_policy`,
`light_sources`) and the full upstream scenario-id set, so a truncated or
stale mirror fails loudly instead of silently narrowing parity coverage.

> Implementation note: once `Package.swift` declares the fixture as a
> resource (`resources: [.copy("Fixtures")]`), the loader can switch to
> `Bundle.module`; until then `#filePath` needs no manifest change.

### How to refresh the mirror

```bash
cd ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/ParityCorpus
curl -fsSL -o v1/corpus.json \
  https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json
python3 verify_corpus.py          # independent replay must print OK
cd ../../../.. && swift test --filter SolverParityCorpusTests
```

`verify_corpus.py` re-derives every recorded expectation from the scenario
inputs using an independent implementation of the documented policy
(weighted squared error; exclude when any positive-weight channel is
missing; earliest-index wins on exact ties; unknown light-source weight keys
ignored). If it reports mismatches, the fetched file is truncated, stale, or
the server changed semantics — do not commit it blindly.

When the server bumps to `v{n+1}`: add the new `v{n+1}/corpus.json` (keep
`v{n}` until the scorer is updated), update `implementedAlgorithmVersion`,
rerun everything, then delete the old version directory.

### Parity findings (recorded for the PR description)

Replay of the committed corpus (12 scenarios) — all exact:

- **Ties** (5 scenarios): exact-tied minima always resolve to the earliest
  palette index — symmetric ±0.125 offsets, duplicate vectors, and a
  three-way LPS tie all included. Matches
  `IlluminantMatching.best_match/4`'s documented earliest-wins policy and
  `CompositionSolver`'s tie-breaking.
- **Exclusions** (2 no-selection scenarios + excluded candidates inside
  others): a candidate missing any positive-weight channel is `excluded`,
  never treated as zero brightness; a target missing a positive-weight
  channel excludes every candidate. Matches the corpus
  `missing_policy` stamp exactly.
- **Weight handling**: zero-weight channels neither exclude nor contribute
  (a candidate missing an unweighted channel ties with one measured wildly
  differently on it), and unknown weight keys (`ultraviolet`) are ignored —
  the `unknown-weight-ignored` scenario's score table is identical to
  `distinct-errors`.

## Generated OpenAPI client

### Target layout (asserted by `GeneratedOpenAPIClientTests`)

- `ColorComposerCore/Package.swift` depends on `swift-openapi-runtime` and
  applies the `swift-openapi-generator` SwiftPM plugin (`OpenAPIGenerator`)
  to the `ColorComposerCore` target.
- The server's published OpenAPI document is committed at
  `Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}` — the exact
  path the generator plugin reads — so `swift build` regenerates the typed
  client deterministically with no network access.
- The document must describe `GET /api/v1/printer_profiles`,
  `GET /api/v1/colors`, and the `bearerAuth` security scheme, i.e. the
  whole surface `PaletteAPIClient` uses.
- Generated sources are build-time artifacts and are never committed.

### Migration strategy the tests enforce

`PaletteAPIClient` keeps its public surface and wraps the generated client;
`PaletteAPIClientMigrationTests` pin the observable behavior (endpoint
paths, `printer_profile_id` query, `Accept`/`Authorization` headers, envelope
decoding, `unauthorized`/`badStatus`/`malformedResponse` mapping), so the
disk cache (`ProfileColorCache`) and the offline-stale/cached-profile
fallback layers above it are untouched. No new API surfaces are adopted
(issue non-goal).

### `/api/v1` shape findings (from the server's OpenAPI spec)

- `ColorsResponse.printer_profile` is **required** by the server spec; the
  app DTO decodes it as optional. No server change — the client keeps its
  lenient decoding.
- Color fields `name`, `palette_id`, `sort_order` are required server-side
  but optional in the DTOs (with `hex` fallback in `toDomain()`); leniency
  stays.
- `rgb` is optional in the spec (required only in `ProfileColorsResponse`);
  the app's hex fallback remains necessary.
- Auth is `http bearer` (`bearerAuth`), matching the client's
  `Authorization: Bearer <token>` header.
- The server also exposes
  `GET /api/v1/printer_profiles/{id}/colors` (`ProfileColorsResponse`); the
  app intentionally keeps using `GET /api/v1/colors?printer_profile_id=N`.
