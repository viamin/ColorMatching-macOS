# OpenAPI generated-client migration notes (issue #39)

Source material for the issue #39 PR description. Status at the time of this
tests-only change: **the generated client is not yet adopted** —
`GeneratedClientAdoptionTests` intentionally fails (red) until the migration
lands, and `PaletteAPIClientContractTests` + `ProfileColorCacheTests` pin the
behavior that must survive it.

## Current `/api/v1` contract consumed by `PaletteAPIClient`

Established by code and pinned by tests (paths, envelopes, auth, status map):

- `GET {base}/api/v1/printer_profiles` → envelope `{"printer_profiles": [PrinterProfile]}`
  - `PrinterProfile`: `id: Int`, `printer_make_model?`, `paper_type?`, `ink_type?` (snake_case)
- `GET {base}/api/v1/colors?printer_profile_id=N` → envelope `{"colors": [Color], "printer_profile": PrinterProfile?}`
  - `Color`: `id`, `name?`, `hex`, `rgb?: {r,g,b}`, `palette_id?`, `palette_name?`, `sort_order?`,
    `responses: {light_source → Response}` with keys from `white|red|green|blue|lps`
  - `Response`: `brightness` (normalized 0–1, the only solver-relevant field), `source?`,
    `apparent_brightness?`, `raw_value?`, `raw_unit?`, `measured_at?`, `test_run_id?`
  - **Missing measurements are absent keys, never zero** (pins the solver's exclusion policy)
  - Unknown light-source keys in `responses` are dropped on domain conversion
- `GET /api/v1/printer_profiles` doubles as the "Test connection" reachability probe (any 2xx passes)
- Auth: optional bearer token, trimmed; absent/blank token → no `Authorization` header
- Status mapping: `401 → .unauthorized` (drives re-auth flow), other non-2xx → `.badStatus(code)`,
  undecodable 2xx body → `.malformedResponse`

No `/api/v1` shape changes were found while pinning these contracts. The
upstream OpenAPI 3 spec (viamin/color_matching#110) was **not yet published** at
the time of this change — the generated client must be built from it once
available (`GET /api/v1/openapi.json`), and the contract tests above are the
regression net proving the swap changed nothing on the wire.

## Migration requirements (behavior that must not change)

1. `PaletteAPIClient`'s public surface used by `ColorCatalog`:
   `fetchPrinterProfiles()`, `fetchColors(printerProfileID:)`, `testConnection()`,
   plus `PaletteAPIError` cases (`.unauthorized` distinct from `.badStatus`).
2. Disk-cache/offline behavior fed by these DTOs — per-server/profile color
   caching, offline-stale badges with fetch date, cached-profile fallback
   (`ProfileColorCache`, covered by `ProfileColorCacheTests`; the cached
   on-disk format is snake_case and must keep decoding).
3. Error-classification semantics above (401 vs 5xx vs malformed).

Wrapping the generated client inside `PaletteAPIClient` (keeping its public API
and error mapping) is the low-risk route; a full type migration is acceptable
only if the pinned contract and cache tests stay green untouched.

## Parity findings (corpus v1, 12/12 scenarios)

- Selections, minimum errors, per-candidate scores (incl. `"excluded"` entries),
  and tie evidence all match the Elixir solver exactly at tolerance `1e-12`.
- Ties: earliest-index-wins confirmed across four tie scenarios (two-way
  symmetric, duplicate vectors, three-way single-channel, mixed palette).
- Exclusions: any positive-weight channel missing on candidate *or* target
  excludes; missing is never zero. Zero-weight channels neither exclude nor
  contribute. Unknown light-source weight keys (`ultraviolet`) are ignored.
- `missing-target-excluded` is scorer-level only (inexpressible via solver
  grids — the app always supplies a grid per active channel).

See `docs/parity-corpus.md` for corpus location, refresh procedure, and the
pinned upstream commit.
