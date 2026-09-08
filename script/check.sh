#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
./script/format.sh --check
./script/swiftpm.sh build --product MyEditor
./script/swiftpm.sh run NovelReaderChecks
node --test EditorWeb/test/*.test.js Tests/BuildScripts/*.test.mjs
(cd EditorWeb && npm run build)
node script/check_docs.mjs
