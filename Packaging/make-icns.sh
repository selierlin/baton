#!/usr/bin/env bash
# 由 Packaging/AppIcon-1024.png 生成 Packaging/AppIcon.icns。
#
# 改了图标形状/配色后：先 `swift Packaging/make-icon.swift`，再跑这个脚本。
# 生成的 .icns 会进仓库，构建时只拷贝，不在 CI 里重画。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Packaging/AppIcon-1024.png"
OUT="$ROOT/Packaging/AppIcon.icns"
ICONSET="$ROOT/Packaging/AppIcon.iconset"

[ -f "$SRC" ] || { echo "缺少 $SRC，先跑 swift Packaging/make-icon.swift"; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "wrote $OUT"
