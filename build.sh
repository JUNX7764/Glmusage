#!/bin/bash
# 编译并打包 GlmUsage 菜单栏小工具
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/GlmUsage.app"

# 图标：缺失时用脚本生成（macOS 13+ 自带 swift / iconutil / sips）
if [ ! -f "$DIR/AppIcon.icns" ]; then
    echo "== 生成图标 =="
    (cd "$DIR" && swift scripts/icon_gen.swift)
fi

echo "== 编译 Swift 源码 =="
swiftc -O -o "$DIR/GlmUsage-bin" "$DIR/GlmUsage.swift"

echo "== 打包 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mv "$DIR/GlmUsage-bin" "$APP/Contents/MacOS/GlmUsage"
chmod +x "$APP/Contents/MacOS/GlmUsage"

echo "== ad-hoc 签名 =="
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "== 完成: $APP =="
