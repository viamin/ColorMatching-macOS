# Issue #39 — tests-only run: criterion → verification map

Test-writing phase for "Adopt generated OpenAPI client and enforce solver
parity with the parity corpus" (#39). This run commits **tests and LID docs
only**; implementation (the `swift-openapi-generator`/`swift-openapi-runtime`
dependency, generated client sources, `PaletteAPIClient` migration, README
section) belongs to the follow-up implementation run gated on
`paid-tests-approved`.

## Acceptance criteria → smallest credible verification

| AC | Verification | Kind | Status at this head |
| --- | --- | --- | --- |
| Generated OpenAPI client adopted; `PaletteAPIClient` migrated/wrapped | Wire-contract unit tests pinning every `/api/v1` behavior the migration must preserve: paths, `printer_profile_id` query, `Accept`/`Authorization` headers, 401→`.unauthorized`, 5xx→`.badStatus`, non-JSON→`.malformedResponse`, envelope decoding (`PaletteAPIClientTests.swift`) | `unit_or_service_test` (migration guard); codegen itself is implementation | Tests written; **not executed** — no Swift toolchain in the authoring container (`swift: command not found`) |
| Existing behavior preserved: per-server/profile color caching, offline-stale badges, cached profile fallback | Existing permanent suite `ProfileColorCacheTests` (69 tests: per-server namespacing, corrupt-file-as-miss, ownership marker, clear-cache) plus the wire-contract tests above; offline-stale *badge* rendering is app-layer UI (`ColorMatching/Networking/ColorCatalog.swift`) reviewed by humans on macOS | `unit_or_service_test` | Unchanged by this run (no implementation edits); not executed here |
| Solver parity test target loads the committed corpus and asserts exact selections incl. ties | New permanent test target `SolverParityCorpusTests` + committed corpus fixture (7 cases) | `unit_or_service_test` | Written; expectations cross-checked against an independent re-implementation of the selection policy (all 7 cases consistent); **not executed** (no Swift toolchain) |
| README documents corpus consumption | `docs/parity-corpus.md` (canonical guide: location, schema, refresh); README.md is outside the tests-phase allowlist — fold-in recorded as pending | `human_or_external_evidence` (doc) | Deferred to implementation run |
| PR description records migration notes, `/api/v1` shape findings, parity results | No PR in this phase (tests-only draft, published by Paid); findings recorded here and in run evidence | `human_or_external_evidence` | Deferred |

## `/api/v1` shape findings (from the contract tests)

- Envelopes are snake_case: `printer_profiles[]`, `colors[]` + optional
  `printer_profile`; decoding relies on `convertFromSnakeCase` throughout — the
  generated client must map identical field names.
- `responses` is a map keyed by light-source string (`white|red|green|blue|lps`);
  unknown keys must be ignored, absent keys mean *unmeasured* (not zero).
- `rgb` is optional in a color DTO; consumers fall back to `hex` parsing.
- Error mapping is status-based: 401 → `unauthorized` (re-auth flow), other
  non-2xx → `badStatus(code)`, undecodable 2xx body → `malformedResponse`.
- Auth is a trimmed `Bearer <token>` header, omitted entirely for
  blank/whitespace tokens. `Accept: application/json` on every request.

## Parity findings (ties, exclusions, weight handling)

- **Ties**: the reference resolves ties by earliest candidate in input order
  (`best_match/4` strict `<`). The corpus carries a three-way tie case
  (identical vectors and an equal-error mirror); bit-exact equality of the tied
  scores was verified, so ordering — not score re-comparison — decides.
- **Exclusions**: a candidate missing a measurement for any weight>0 condition
  is excluded, never scored against an implied zero. Both directions are
  pinned: the nearest-but-unmeasured candidate must lose to a farther complete
  one, and all-excluded leaves the cell unmatched with infinite error.
- **Weights**: zero-weight channels neither require measurements nor
  contribute; scaling one channel's weight can flip the winner (pinned by a
  companion case pair under the same candidates). Scores are compared with
  1e-12 absolute tolerance to absorb cross-VM float formatting.

## Runnability

- Gate command: `cd ColorComposerCore && swift test` (macOS host, or any host
  with a Swift toolchain; on Linux `bin/lint` builds the portable subset that
  excludes `PaletteAPIClient`/`BrightnessGridSampler`).
- This container has **no Swift toolchain**, so the suite was not executed
  here. Corpus expectations were instead validated by an independent
  re-implementation of the selection policy (selections, exclusions, and
  scores all consistent; see parity findings above). Execute the suite on a
  Swift host before merging the implementation.
