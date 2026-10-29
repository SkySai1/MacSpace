#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
cd "$PROJECT_ROOT"
COMMAND="${1:-test}"
if [[ "$#" -gt 0 ]]; then shift; fi
exec swift "$COMMAND" --disable-sandbox \
    --cache-path "$PROJECT_ROOT/.build/cache" \
    --config-path "$PROJECT_ROOT/.build/config" \
    --security-path "$PROJECT_ROOT/.build/security" "$@"
