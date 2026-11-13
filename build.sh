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

# macOS 26 SDK enables the native popover glass appearance; runtime still supports macOS 13+.
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if ! [[ "$SDK_MAJOR" =~ ^[0-9]+$ ]] || [ "$SDK_MAJOR" -lt 26 ]; then
    echo "错误: 需要 macOS 26+ SDK 编译" >&2
    exit 1
fi

echo "== 编译 Swift 源码 =="
# 必须显式指定部署目标：本机 CLT 默认 target 是 macosx28.0（比当前系统 macOS 27 新），
# 缺省编译出的二进制 minos=28.0 会被 LaunchServices 拒绝（"不能与此版本 macOS 配合使用"）。
# GlmUsage.swift 保留唯一 top-level 入口；新增文件只能声明类型，不能增加第二个 main。
# 多文件编译下只有名为 main.swift 的文件允许 top-level 代码，因此把 GlmUsage.swift
# 以符号链接为 main.swift 放进临时编译目录，根目录与 Sources/ 的其余 Swift 文件按真实路径参与编译。
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/glm-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ln -s "$DIR/GlmUsage.swift" "$STAGE/main.swift"
sources=("$STAGE/main.swift")
while IFS= read -r source; do
    sources+=("$source")
done < <(find "$DIR" -maxdepth 1 -name '*.swift' ! -name 'GlmUsage.swift' -print | sort)
while IFS= read -r source; do
    sources+=("$source")
done < <(find "$DIR/Sources" -maxdepth 1 -name '*.swift' -print | sort)
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/GlmUsage-bin" "${sources[@]}"

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
