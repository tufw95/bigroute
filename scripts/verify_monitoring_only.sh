#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -e Sources/BigrouteCore/NineRouterAutomation.swift ]]; then
  echo "Automatic routing source must not be shipped in monitoring-only Bigroute." >&2
  exit 1
fi

# Keep the app's provider requests read-only. These checks intentionally cover
# both the old service names and every mutating HTTP verb used by URLSession.
if rg -n -S \
  'NineRouterAutomation|isAutomaticAccountRoutingEnabled|/api/auth/login|/api/providers(/|")|httpMethod[[:space:]]*=[[:space:]]*"(POST|PUT|PATCH|DELETE)"' \
  Sources; then
  echo "Monitoring-only source contains a retired routing or mutating request path." >&2
  exit 1
fi

echo "Monitoring-only source verification passed."
