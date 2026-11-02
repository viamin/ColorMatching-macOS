# Generated OpenAPI client (issue #39)

Plan and contract for migrating `PaletteAPIClient` to a typed client generated
from the `color_matching` OpenAPI document
([viamin/color_matching#110](https://github.com/viamin/color_matching/issues/110)).

## Artifacts the migration must add

Pinned by `ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift`
(these tests are red until the migration lands, then guard against removal):

1. **OpenAPI document** committed at the `swift-openapi-generator` build-plugin
   default location:
   `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`,
   describing both consumed operations:
   - `GET /api/v1/printer_profiles`
   - `GET /api/v1/colors?printer_profile_id=N`
2. **Package dependencies** in `ColorComposerCore/Package.swift`:
   - `swift-openapi-generator` (build plugin)
   - `swift-openapi-runtime`

Suggested shape (wrap, don't rewrite — keeps the public surface unchanged):

- Keep `PaletteAPIClient`'s initializer and method signatures as the stable API;
  replace the hand-rolled `URLSession` transport with the generated `Client`
  driven by a `URLSessionTransport`.
- Map generated errors back onto the existing `PaletteAPIError` cases
  (`.unauthorized` for 401, `.badStatus`, `.malformedResponse`) so callers —
  including the re-auth flow from issue #16 — are untouched.

## Behavior that must be provably unchanged

The migration PR must leave these permanent suites green:

| Suite | Pins |
| --- | --- |
| `PaletteAPIClientContractTests` | endpoint URLs, `printer_profile_id` query, `Accept` header, 401/5xx/undecodable error mapping, envelope decoding |
| `PaletteAPIClientTests` | trimmed bearer token, 401 → `.unauthorized` |
| `APIDecodingTests` | `/api/v1` wire shapes (snake_case envelopes, missing-measurement handling) |
| `ProfileColorCacheTests` | per-server/per-profile disk cache, offline-stale `fetchedAt` markers, cached-profile fallback integrity, Clear Cache |

Any `/api/v1` shape changes discovered while generating the client (new
optional fields, renamed keys) must be recorded in the PR, not silently
re-coded around.

## PR description checklist (for the implementation run)

- [ ] Generated-client migration notes (wrap vs. replace decision, transport setup)
- [ ] Any `/api/v1` shape changes found while generating from the spec
- [ ] Solver parity results from the corpus run (`SolverParityCorpusTests`),
      including tie handling, exclusions, and weight handling
- [ ] Confirmation that disk cache + offline fallback suites stayed green

## Corpus consumption

See [`docs/solver-parity-corpus.md`](solver-parity-corpus.md) for where the
parity corpus lives, its schema, and how to refresh it from
viamin/color_matching#111.
