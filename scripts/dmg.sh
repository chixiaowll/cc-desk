#!/bin/sh
# 打包可分发的 DMG：通用二进制（Apple 芯片 + Intel）、ad-hoc 签名、带「应用程序」快捷方式。
# 未经 Apple 公证：在其他电脑首次打开需右键「打开」，或在「系统设置 → 隐私与安全性」中点「仍要打开」。
set -eu
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
# 分别编译两种架构再用 lipo 合并（--arch 多架构会走 xcbuild，与 SwiftTerm 的构建插件不兼容）。
for T in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    swift build -c release --product CCDesk --triple "$T"
done
BIN_ARM="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
BIN_X86="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)"
BIN_DIR="$BIN_ARM"
STAGE="build/dmg"
APP="$STAGE/CC Desk.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BIN_ARM/CCDesk" "$BIN_X86/CCDesk" -output "$APP/Contents/MacOS/CCDesk"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -e "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" ]; then
    cp -R "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
fi
codesign --force --deep --sign - "$APP"
ln -s /Applications "$STAGE/应用程序"
cat > "$STAGE/首次打开说明.txt" <<'TXT'
CC Desk 安装说明

1. 把「CC Desk」拖到「应用程序」。
2. 第一次打开时，macOS 会提示无法验证开发者：
   在「应用程序」里右键 CC Desk →「打开」→ 再点「打开」；
   或到「系统设置 → 隐私与安全性」底部点「仍要打开」。
3. 首次运行时请允许「通知」，以及跳转 Terminal 时的「自动化」权限。

要求：macOS 14 及以上，已安装 Claude Code（命令行中可运行 claude）。
TXT
OUT="build/CCDesk-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "CC Desk" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "$OUT"
