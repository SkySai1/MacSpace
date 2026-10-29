#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    echo "Использование: $0 [debug|release]" >&2
    exit 2
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
"$PROJECT_ROOT/scripts/swift-local.sh" build -c "$CONFIGURATION"
BIN_PATH="$("$PROJECT_ROOT/scripts/swift-local.sh" build -c "$CONFIGURATION" --show-bin-path)"
APP_PATH="$PROJECT_ROOT/.build/MacSpace.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/MacSpace" "$APP_PATH/Contents/MacOS/MacSpace.next"
mv -f "$APP_PATH/Contents/MacOS/MacSpace.next" "$APP_PATH/Contents/MacOS/MacSpace"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$PROJECT_ROOT/.build/AppIcon.iconset"
iconutil -c icns "$PROJECT_ROOT/.build/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "Готово: $APP_PATH"
