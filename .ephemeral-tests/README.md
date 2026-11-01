# Ephemeral tests (remove before merge)

One-off validation used by the issue #39 migration work. These do **not** run
in CI and are deleted before the PR merges.

- `openapi_spec_check.sh [base-url]` — fetches `GET /api/v1/openapi.json` from
  a running `color_matching` server and checks the document still covers
  `PaletteAPIClient`'s surface (`/api/v1/printer_profiles`,
  `/api/v1/colors?printer_profile_id=…`, bearer scheme). Run it during the
  generated-OpenAPI-client migration PR with a local server running.

Permanent coverage lives in `ColorComposerCore/Tests/ColorComposerCoreTests/`
(`PaletteAPIClientContractTests`, `SolverParityCorpusTests`); corpus and
migration notes live in `docs/solver-parity.md` and
`docs/openapi-client-migration.md`.
