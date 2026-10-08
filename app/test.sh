#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-sidebar-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$here/Sources/GhosttySidebar/StatusModel.swift" \
  "$here/Sources/GhosttySidebar/SessionEvidence.swift" \
  "$here/Sources/GhosttySidebar/Placement.swift" \
  "$here/Tests/GhosttySidebarTests/StatusTests.swift" -o "$scratch/status-tests"
"$scratch/status-tests"
