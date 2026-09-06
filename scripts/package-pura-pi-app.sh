#!/usr/bin/env bash
set -euo pipefail

# 这个脚本只生成未签名的开发预览 .app，不代表正式发布包。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_PATH="${OUTPUT_DIR}/PuraPi.app"
BIN_NAME="PuraPi"
BUNDLE_NAME="PuraPi_PuraPi.bundle"

cd "$ROOT_DIR"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

# 二进制文件名改为 PuraPi，macOS 菜单栏/进程展示才不会继续显示内部 target 名。
cp "$BIN_DIR/$BIN_NAME" "$APP_PATH/Contents/MacOS/PuraPi"
chmod +x "$APP_PATH/Contents/MacOS/PuraPi"

# SwiftPM 的 Bundle.module accessor 会在主 App bundle 根目录查找资源 bundle。
cp -R "$BIN_DIR/$BUNDLE_NAME" "$APP_PATH/$BUNDLE_NAME"
cp "$ROOT_DIR/Sources/PuraPi/Resources/PuraPi.icns" "$APP_PATH/Contents/Resources/PuraPi.icns"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>PuraPi</string>
  <key>CFBundleExecutable</key>
  <string>PuraPi</string>
  <key>CFBundleIconFile</key>
  <string>PuraPi.icns</string>
  <key>CFBundleIdentifier</key>
  <string>works.purapi.PuraPi</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PuraPi</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# 清掉构建机扩展属性，避免本地 Finder 打开时被旧隔离标记干扰。
xattr -cr "$APP_PATH" 2>/dev/null || true
printf '已生成未签名开发预览：%s\n' "$APP_PATH"
