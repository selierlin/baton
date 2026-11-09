#!/usr/bin/env bash
# 把 SwiftPM 产物包成最小 .app。
# 用法：./Scripts/make-app.sh [debug|release] [--install]
#   --install：打完再同步到 /Applications/Baton.app（日常运行的那份）
# 版本号取自最近的 git tag（v0.1.1 → 0.1.1），build 取提交总数；
# 两者都能用 BATON_VERSION / BATON_BUILD 覆盖（发版和 CI 用 tag 名）。
# 签名：优先用本机 Apple Development 证书（DR 绑证书，重建后 TCC 授权不失效），
#       找不到才退回 ad-hoc（cdhash 会变，每次都要重新授权）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="debug"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --install|-i) INSTALL=1 ;;
        *) echo "未知参数：$arg（用法：make-app.sh [debug|release] [--install]）"; exit 1 ;;
    esac
done
BUNDLE_ID="com.selier.baton"
# 版本号只有一个来源：git tag。发版时打 tag 即生效，本地随手构建也不会再写回默认值。
# 短版本取最近 tag，build 取提交总数（单调递增，每次构建都不同，界面显示成「0.1.1 (65)」）。
if [ -n "${BATON_VERSION:-}" ]; then
    VERSION="$BATON_VERSION"
else
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    [ -n "$VERSION" ] || { echo "错误：仓库里没有 tag，先 git fetch --tags（或用 BATON_VERSION 指定）"; exit 1; }
fi
if [ -n "${BATON_BUILD:-}" ]; then
    BUILD="$BATON_BUILD"
else
    BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi
APP="$ROOT/dist/Baton.app"
BIN="$ROOT/.build/$CONFIG/BatonApp"
OCR_BIN="$ROOT/.build/$CONFIG/BatonOCR"

swift build -c "$CONFIG"
[ -x "$BIN" ] || { echo "找不到产物 $BIN"; exit 1; }
[ -x "$OCR_BIN" ] || { echo "找不到产物 $OCR_BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Baton"
# OCR 子进程与主进程同目录：SubprocessOCRTransport 按 Contents/MacOS/BatonOCR 找它
cp "$OCR_BIN" "$APP/Contents/MacOS/BatonOCR"
# 工具条图标在内的 BatonCore 资源。Bundle.module 只认 app 根目录，
# 那是非规范位置；放 Contents/Resources 更干净，BarIcon 自己按这个路径找。
RES_BUNDLE="$ROOT/.build/$CONFIG/Baton_BatonCore.bundle"
[ -d "$RES_BUNDLE" ] || { echo "找不到资源包 $RES_BUNDLE"; exit 1; }
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
# App 图标：由 Packaging/make-icon.swift 画好后用 Packaging/make-icns.sh 打包，
# 构建只负责拷进 Resources，不在打包时重画。
ICON="$ROOT/Packaging/AppIcon.icns"
[ -f "$ICON" ] || { echo "找不到 $ICON，先跑 ./Packaging/make-icns.sh"; exit 1; }
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>Baton</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Baton</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDisplayName</key><string>Baton</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>录制屏幕时同步录入麦克风旁白。</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="${BATON_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # 优先用本机 Apple Development 证书：designated requirement 绑证书而不是 cdhash，
    # 重建后 TCC 授权（辅助功能/屏幕录制/输入监控）不会失效。
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "警告：未找到开发证书，退回 ad-hoc 签名 —— 每次重建都要去系统设置重新授权"
fi
# 嵌套的 OCR 子进程必须单独签，否则整包校验会报「未签名代码」
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.ocr" "$APP/Contents/MacOS/BatonOCR" >/dev/null
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >/dev/null
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1 || true

echo "built $APP version=$VERSION ($BUILD) identity=$IDENTITY"

# 可选：同步到 /Applications（日常运行的那一份 + 登录项指向它）。
# 不默认执行——覆盖会动到系统目录，而且 app 正在跑的时候要先退出。
if [ "$INSTALL" = "1" ]; then
    DEST="/Applications/Baton.app"
    echo "同步到 $DEST ..."
    if pgrep -f "$DEST/Contents/MacOS/Baton" >/dev/null 2>&1; then
        echo "  先退出正在运行的副本"
        pkill -f "$DEST/Contents/MacOS/Baton" || true
        sleep 1
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    codesign --verify --deep --strict "$DEST" || { echo "签名校验失败"; exit 1; }
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    echo "已装到 $DEST"
fi
