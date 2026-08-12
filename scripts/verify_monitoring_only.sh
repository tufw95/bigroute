#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -e Sources/BigrouteCore/NineRouterAutomation.swift ]]; then
  echo "Automatic routing source must not be shipped in monitoring-only Bigroute." >&2
  exit 1
fi

# Account state changes are allowed only through the explicit, user-confirmed
# quota endpoint client. Background automation and dashboard management stay banned.
if rg -n -S \
  'NineRouterAutomation|isAutomaticAccountRoutingEnabled|/api/auth/login|/api/providers(/|")|httpMethod[[:space:]]*=[[:space:]]*"(PUT|PATCH|DELETE)"' \
  Sources; then
  echo "Source contains retired automation or a direct dashboard mutation path." >&2
  exit 1
fi

unexpected_post_lines="$(
  rg -n -S 'httpMethod[[:space:]]*=[[:space:]]*"POST"' Sources \
    | rg -v '^Sources/BigrouteCore/ManualAccountRouting\.swift:' \
    || true
)"
if [[ -n "$unexpected_post_lines" ]]; then
  printf '%s\n' "$unexpected_post_lines"
  echo "POST requests are allowed only in ManualAccountRouting.swift." >&2
  exit 1
fi

echo "No background routing or direct dashboard mutation paths found."
