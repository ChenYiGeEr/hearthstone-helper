#!/bin/bash
# 构建 → 打包 → 嵌入 HearthMirror.framework → rpath → 签名(调试权限) → 重启
set -e
cd "$(dirname "$0")/.."

swift build -c release
APP="$HOME/Applications/HearthstoneHelper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/out/Products/Release/HearthstoneHelper "$APP/Contents/MacOS/HearthstoneHelper"
cp -R vendor/HearthMirror.xcframework/macos-arm64_x86_64/HearthMirror.framework "$APP/Contents/Frameworks/"

# dyld 需要 rpath 才能找到 @rpath/HearthMirror.framework
otool -l "$APP/Contents/MacOS/HearthstoneHelper" | grep -q "@executable_path/../Frameworks" || \
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/HearthstoneHelper"

# 先签 framework，再签 app（带调试权限：task_for_pid 必需）
codesign --force --sign - "$APP/Contents/Frameworks/HearthMirror.framework"
codesign --force --sign - --entitlements scripts/debugger.entitlements "$APP"

pkill -f "HearthstoneHelper.app/Contents/MacOS/HearthstoneHelper" 2>/dev/null || true
sleep 1
open "$APP"
echo "部署完成：$APP"
