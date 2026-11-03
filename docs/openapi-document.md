# The published OpenAPI document

The `color_matching` backend publishes an OpenAPI 3 document for its whole
`/api/v1` API. This app consumes it: the palette API client is generated from
that document (swift-openapi-generator) instead of hand-written request
plumbing, so the wire contract lives in exactly one place — the server's.

## Where the document lives

| | Path |
| --- | --- |
| Upstream (source of truth) | `GET /api/v1/openapi.json` on a running `color_matching` server; generated from `ColorMatchingWeb.ApiSpec` |
| Committed copy (this repo) | `ColorComposerCore/openapi.json` |

The committed copy is what the generated client is produced from, so it is
vendored rather than fetched at build time.

## Refreshing the document

```bash
curl -sSL http://localhost:4000/api/v1/openapi.json -o ColorComposerCore/openapi.json
```

Upstream keeps the document honest with `oasdiff` in CI: a breaking change to
the published API fails the server's build, so an update here is normally the
result of an intentional server-side change.

## What the contract test pins

`ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift`
asserts that the vendored document still describes what the app needs:

- `GET /api/v1/printer_profiles` exists;
- `GET /api/v1/colors` exists and declares the **required** query parameter
  `printer_profile_id`;
- the `PrinterProfilesResponse` schema requires `printer_profiles`, and the
  `PrinterProfile` schema requires `id`, `printer_make_model`, `paper_type`
  and `ink_type`;
- the `ColorsResponse` schema requires `printer_profile` and `colors`, and a
  color requires `id`, `name`, `hex`, `palette_id`, `sort_order` and
  `responses` (with `rgb` and `palette_name` optional);
- the document declares the `bearerAuth` security scheme (HTTP bearer), which
  is the token the client sends.

The client's own behavior against that contract is pinned in
`PaletteAPIClientTests`: the endpoints it calls, the bearer token it sends,
the error mapping the UI reacts to (401 → re-authenticate, other non-2xx →
status code, unreadable body → malformed response) and the decoded envelope.

## Notes on the current API shape

- `GET /api/v1/colors?printer_profile_id=N` returns *palette* colors (with
  `palette_id`, `palette_name` and `sort_order`). The server also publishes
  `GET /api/v1/printer_profiles/{printer_profile_id}/colors`, which returns
  profile-scoped colors without palette metadata; the app keeps using the
  palette route it has always used.
- `responses` is an open map keyed by light source. A light source with no
  measurement is **absent** from the map, which is what lets the client
  distinguish "never measured" from "measured as zero brightness" — the
  solver excludes such colors instead of scoring them against zero.
- Errors use the `{"errors": {"detail": "..."}}` envelope.
