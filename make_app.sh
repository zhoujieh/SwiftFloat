#!/bin/bash
set -e

APP_NAME="SwiftFloat"
BUILD_DIR="./.build/release"
SRCROOT="."

# 创建 .app 目录结构
APP_DIR="/Applications/${APP_NAME}.app"
rm -rf "$APP_DIR"

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# 复制二进制
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/"

# 写入 Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.swiftfloat.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 写入 entitlements（允许辅助访问）
cat > "${APP_DIR}/Contents/Resources/${APP_NAME}.entitlements" << ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENT

echo "✅ ${APP_NAME}.app 已生成到 /Applications/"
echo "   可以用 Finder 打开 Applications 找到它，或 Spotlight 搜索 SwiftFloat"
echo ""
echo "⚠️  首次运行需要在 系统设置 → 隐私与安全性 → 辅助功能"
echo "   把 SwiftFloat.app 添加到列表并开启权限"
