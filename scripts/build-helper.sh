#!/bin/bash
# 编译 whale-mini 的 Swift 小助手，产出一个自包含的 .app（LSUIElement，无 Dock 图标）。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/../helper/WhaleMini.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cache="$here/../.build/module-cache"
mkdir -p "$cache"
# 默认 SDK 可能和 CLT 的编译器版本对不上（"this SDK is not supported by the compiler"），
# 那就退到本机装着的最新一个带版本号的 SDK 再编一次。
compile() {
  swiftc -O -swift-version 5 -module-cache-path "$cache" ${1:+-sdk "$1"} \
    -o "$app/Contents/MacOS/WhaleMini" "$here/../helper/main.swift" -framework AppKit
}
if ! compile "" 2>/tmp/whale-mini-sdk.log; then
  sdk="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -V | tail -1)"
  echo "default SDK rejected the compiler, retrying with $sdk" >&2
  compile "$sdk"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WhaleMini</string>
  <key>CFBundleIdentifier</key><string>com.zehan.whale-mini</string>
  <key>CFBundleName</key><string>WhaleMini</string>
  <key>CFBundleDisplayName</key><string>鲸鱼娘</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built $app"
