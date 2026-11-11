#!/bin/bash
# 编译并打包 GlmUsage 菜单栏小工具
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/GlmUsage.app"

# 版本注入：tag 即版本（git describe），无 tag 退化短 hash，未提交改动追加 -dirty。
# 打包时写进产物 Info.plist 自定义键（CUBuildVersion），app 运行时读 Bundle——不能生成第二个 .swift：
# 多文件编译下只有 main.swift 允许 top-level 代码，GlmUsage.swift 的命令行入口依赖 top-level
VERSION_DESCRIBE="$(git -C "$DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
COMMIT="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "== 版本 ${VERSION_DESCRIBE}（commit ${COMMIT}）=="

# 图标：缺失时用脚本生成（macOS 13+ 自带 swift / iconutil / sips）
if [ ! -f "$DIR/AppIcon.icns" ]; then
    echo "== 生成图标 =="
    (cd "$DIR" && swift scripts/icon_gen.swift)
fi

echo "== 编译 Swift 源码 =="
# 必须显式指定部署目标：本机 CLT 默认 target 是 macosx28.0（比当前系统 macOS 27 新），
# 缺省编译出的二进制 minos=28.0 会被 LaunchServices 拒绝（"不能与此版本 macOS 配合使用"）。
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/GlmUsage-bin" "$DIR/GlmUsage.swift"

echo "== 打包 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mv "$DIR/GlmUsage-bin" "$APP/Contents/MacOS/GlmUsage"
chmod +x "$APP/Contents/MacOS/GlmUsage"

# 产物版本号取 describe 的数字前缀（v1.0.0 / v1.0.0-3-gx → 1.0.0）；无 tag 时 0.0.0
PLIST_VERSION="0.0.0"
case "$VERSION_DESCRIBE" in
    v[0-9]*)
        PLIST_VERSION="${VERSION_DESCRIBE#v}"
        PLIST_VERSION="${PLIST_VERSION%%-*}"
        ;;
esac
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PLIST_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PLIST_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CUBuildVersion string ${VERSION_DESCRIBE}" "$APP/Contents/Info.plist"

# 就地更新脚本随包内置：app 菜单点击更新时由后台作业运行（从 GitHub Releases 下载
# 发布包替换，不依赖 clone 目录），见 GlmUsage.swift onUpdateApp
cp "$DIR/scripts/update.sh" "$APP/Contents/Resources/update.sh"
chmod +x "$APP/Contents/Resources/update.sh"

echo "== 签名 =="
# 优先用本机稳定身份 local-codesign（自签代码签名证书，密钥在 login keychain）：
# 钥匙串 ACL 按签名身份判定，证书不变则 app 更新后已授权条目继续可用；
# ad-hoc 签名的 DR 绑定单次构建 cdhash，每次编译都会使钥匙串授权失效（2026-11-11 实测）。
# 证书缺失（新机器/CI）时回退 ad-hoc，构建永不因此失败。
if security find-identity -v -p codesigning 2>/dev/null | grep -q 'local-codesign'; then
  codesign --force --deep --sign "local-codesign" "$APP"
else
  echo "   (未找到 local-codesign 证书，回退 ad-hoc；更新后需重新授权钥匙串)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "== 完成: ${APP}（版本 ${VERSION_DESCRIBE}）=="
