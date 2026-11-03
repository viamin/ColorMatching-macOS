# OpenAPI document and generated client

The app talks to the `color_matching` server over its versioned `/api/v1`
API. The server publishes an OpenAPI 3 description of that API at
`GET /api/v1/openapi.json` (issue
[viamin/color_matching#110](https://github.com/viamin/color_matching/issues/110),
landed in PR
[#113](https://github.com/viamin/color_matching/pull/113)), and this app
generates its typed client from that description instead of hand-writing the
wire format.

## Where the document lives

| Where | Path |
| --- | --- |
| Upstream (source of truth) | `GET /api/v1/openapi.json` on a running `color_matching` server |
| Committed copy in this repo | `openapi.json` under `ColorComposerCore/` (the package the client is generated into) |

Exactly one OpenAPI document is committed in the package;
`OpenAPIContractTests` fails if none is found or if more than one is, because
the generated client must have a single, unambiguous source.

## How to refresh it

```bash
# 1. Fetch the document the running server publishes.
curl -fsS http://localhost:4000/api/v1/openapi.json \
  -o ColorComposerCore/openapi.json

# 2. Regenerate the typed client from it, with the generator configuration
#    and the `generate-openapi` script the package ships for that purpose.
swift package --scratch-path .build generate-openapi
```

The server's own CI keeps the published document honest (`oasdiff` fails the
build on a breaking change), so refreshing the copy is enough — no local
edits to the document.

## Endpoints the app uses

The app consumes exactly two endpoints, and the generated client exposes no
more than these:

| Endpoint | Query | Response |
| --- | --- | --- |
| `GET /api/v1/printer_profiles` | – | `{ "printer_profiles": [ { "id", "printer_make_model", "paper_type", "ink_type" } ] }` |
| `GET /api/v1/colors` | `printer_profile_id` (required) | `{ "printer_profile": { … }, "colors": [ { "id", "name", "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses" } ] }` |

`responses` maps a light source (`white`, `red`, `green`, `blue`, `lps`) to
its measurement (`brightness`, `source`, `raw_value`, `raw_unit`,
`apparent_brightness`, `measured_at`, `test_run_id`). A light source absent
from the map is **missing**, never measured as zero — the solver excludes such
a candidate when that channel carries weight.

## Shape notes found while adopting the document

- `printer_profile` is **required** in the documented `/api/v1/colors`
  response; the app treats a missing profile as "no profile metadata" and
  falls back to the cached profile, so the generated client keeps that
  tolerance rather than failing the whole fetch.
- The documented color entry requires `id`, `name`, `hex`, `palette_id` and
  `sort_order`, but the app's own decoder keeps them optional: the
  profile-scoped route (`GET /api/v1/printer_profiles/{id}/colors`) returns
  colors without `id`/`palette_id`, and the disk cache may hold entries from
  older servers.
- `responses` is documented as a free-form object (`additionalProperties:
  true`), so the typed client models it as a dictionary of raw JSON values and
  the app keeps its own per-light-source decoding — including dropping
  unknown light sources such as `ultraviolet`.
- Errors are documented as `{ "errors": … }` (an object or an array of
  `{ detail, source }` entries). The app maps every non-2xx status to its own
  `PaletteAPIError` cases and surfaces the server's message separately, so the
  generated client's error type must not leak into the UI layer.
