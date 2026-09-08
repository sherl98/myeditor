#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
MODE="${1:---check}"
if [[ "$MODE" == "--write" ]]; then
    xcrun swift-format format -i -r --configuration .swift-format Package.swift Sources Tests/CoreChecks script/MakeIcon.swift
elif [[ "$MODE" == "--check" ]]; then
    xcrun swift-format lint --strict -r --configuration .swift-format Package.swift Sources Tests/CoreChecks script/MakeIcon.swift
else
    echo "Usage: $0 [--check|--write]" >&2
    exit 2
fi
./EditorWeb/node_modules/.bin/prettier "$MODE" 'EditorWeb/src/**/*.{js,jsx,css}' 'EditorWeb/test/*.js' 'EditorWeb/scripts/*.mjs' 'EditorWeb/*.js' 'script/**/*.mjs' 'Tests/BuildScripts/*.mjs' 'Fixtures/*.mjs' '*.json' EditorWeb/package.json
