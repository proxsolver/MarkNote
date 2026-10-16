#!/bin/bash
# MarkNote 빌드 스크립트 — Xcode 없이 Command Line Tools만으로 .app을 만듭니다.
#   ./build.sh          → .build/MarkNote.app 빌드
#   ./build.sh --install→ ~/Applications에 설치하고 바로 실행
set -euo pipefail

APP="MarkNote"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
APP_DIR="$BUILD/$APP.app"

SDK="$(xcrun --show-sdk-path)"

echo "▸(clean)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 오프라인 렌더러(mermaid, highlight.js, KaTeX)를 번들에 함께 담습니다.
if [[ -d "$ROOT/Resources/vendor" ]]; then
  cp -R "$ROOT/Resources/vendor" "$APP_DIR/Contents/Resources/vendor"
  echo "▸ vendor assets: $(du -sh "$APP_DIR/Contents/Resources/vendor" | cut -f1)"
fi

echo "▸ compile (swiftc)"
swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macosx13.0" \
  -suppress-warnings \
  -o "$APP_DIR/Contents/MacOS/$APP" \
  "$ROOT"/Sources/*.swift

echo "▸ codesign (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || codesign --force --sign - "$APP_DIR"

echo "▸ built: $APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  if [[ -d "$HOME/Applications/$APP.app" ]]; then
    pkill -x "$APP" 2>/dev/null || true
    sleep 0.4
    rm -rf "$HOME/Applications/$APP.app"
  fi
  cp -R "$APP_DIR" "$HOME/Applications/$APP.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/$APP.app" 2>/dev/null || true
  echo "▸ installed: ~/Applications/$APP.app"
  if [[ "${2:-}" == "--open" ]]; then
    open "$HOME/Applications/$APP.app"
    echo "▸ launched"
  fi
fi
