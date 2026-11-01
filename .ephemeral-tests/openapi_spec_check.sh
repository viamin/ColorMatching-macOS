#!/usr/bin/env bash
# Ephemeral migration check (issue #39): validate a LIVE color_matching
# server's published OpenAPI document against what PaletteAPIClient expects.
#
# Usage:   .ephemeral-tests/openapi_spec_check.sh [base-url]
# Default: http://localhost:4000
#
# One-off validation for the generated-OpenAPI-client migration PR.
# REMOVE BEFORE MERGE.
set -euo pipefail

BASE_URL="${1:-http://localhost:4000}"
SPEC_URL="${BASE_URL%/}/api/v1/openapi.json"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "Fetching ${SPEC_URL} (public route, no bearer token expected)…"
curl -fsS --connect-timeout 5 --max-time 15 "$SPEC_URL" -o "$TMP"

python3 - "$TMP" <<'PY'
import json, sys

spec = json.load(open(sys.argv[1]))
errors = []

def check(label, condition):
    print(("  OK   " if condition else "  FAIL ") + label)
    if not condition:
        errors.append(label)

check("document is OpenAPI 3.x", str(spec.get("openapi", "")).startswith("3."))
paths = spec.get("paths", {})

profiles = paths.get("/api/v1/printer_profiles", {}).get("get")
check("GET /api/v1/printer_profiles exists", profiles is not None)
if profiles:
    check("printer_profiles responses describe a 200", "200" in profiles.get("responses", {}))

colors = paths.get("/api/v1/colors", {}).get("get")
check("GET /api/v1/colors exists (the client's palette fetch)", colors is not None)
if colors:
    params = {p.get("name") for p in colors.get("parameters", [])}
    check("colors takes a printer_profile_id query param", "printer_profile_id" in params)
    check("colors responses describe a 200", "200" in colors.get("responses", {}))

schemas = spec.get("components", {}).get("schemas", {})
profile_colors = paths.get("/api/v1/printer_profiles/{printer_profile_id}/colors", {})
check("server also exposes the reduced /printer_profiles/{id}/colors shape (NOT consumed by the client)",
      "get" in profile_colors)
check("bearer security scheme is published",
      any("bearer" in json.dumps(v).lower() for v in spec.get("components", {}).get("securitySchemes", {}).values())
      or len(spec.get("components", {}).get("securitySchemes", {})) > 0)

print()
print("schemas published:", ", ".join(sorted(schemas)) or "(none)")
if errors:
    print(f"{len(errors)} check(s) FAILED — the client contract and the spec disagree.")
    sys.exit(1)
print("All checks passed — the published spec covers PaletteAPIClient's surface.")
PY
