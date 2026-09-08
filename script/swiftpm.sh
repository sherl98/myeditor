#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .cache/clang .cache/modules .cache/swiftpm .cache/config .cache/security
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/modules"
SUBCOMMAND="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
SWIFT_OPTIONS=(--cache-path "$PROJECT_ROOT/.cache/swiftpm" --config-path "$PROJECT_ROOT/.cache/config" --security-path "$PROJECT_ROOT/.cache/security")
# SwiftPM cannot install its nested manifest sandbox inside some managed build hosts.
# Only opt out there; the host's filesystem sandbox remains in effect.
if [[ "${NOVELREADER_NESTED_SANDBOX:-0}" == "1" ]]; then SWIFT_OPTIONS+=(--disable-sandbox); fi
exec /usr/bin/swift "$SUBCOMMAND" "${SWIFT_OPTIONS[@]}" "$@"
