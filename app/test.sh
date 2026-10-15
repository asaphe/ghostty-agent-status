#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-sidebar-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$here/Sources/GhosttySidebar/StatusModel.swift" \
  "$here/Sources/GhosttySidebar/Diagnostics.swift" \
  "$here/Sources/GhosttySidebar/SessionEvidence.swift" \
  "$here/Sources/GhosttySidebar/Placement.swift" \
  "$here/Tests/GhosttySidebarTests/StatusTests.swift" -o "$scratch/status-tests"
"$scratch/status-tests"
swiftc "$here/Sources/GhosttySidebar/StatusModel.swift" \
  "$here/Sources/GhosttySidebar/Diagnostics.swift" \
  "$here/Tests/GhosttySidebarTests/DiagnosticsTests.swift" -o "$scratch/diagnostics-tests"
"$scratch/diagnostics-tests"
swiftc "$here/Sources/GhosttySidebar/PanelBehavior.swift" \
  "$here/Tests/GhosttySidebarTests/PanelTests.swift" -o "$scratch/panel-tests"
"$scratch/panel-tests"
swiftc -D SIDEBAR_TESTS -parse-as-library "$here"/Sources/GhosttySidebar/*.swift \
  "$here/Tests/GhosttySidebarTests/LifecycleTests.swift" -o "$scratch/lifecycle-tests"
"$scratch/lifecycle-tests"
