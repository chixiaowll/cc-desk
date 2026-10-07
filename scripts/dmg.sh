#!/bin/sh
# 打包可分发的 DMG：通用二进制（Apple 芯片 + Intel）、ad-hoc 签名、带「应用程序」快捷方式。
# 内置从源码编译的通用 tmux（Contents/Helpers/tmux），让内嵌会话在 App 重启后继续运行（设计 §14）。
# 未经 Apple 公证：在其他电脑首次打开需右键「打开」，或在「系统设置 → 隐私与安全性」中点「仍要打开」（窗口背景上有提示）。
# 窗口布局由 Finder 写入 .DS_Store：打包时会短暂弹出 DMG 窗口，第一次运行需允许终端控制「访达」。
set -eu
cd "$(dirname "$0")/.."
LOCAL=0
[ "${1:-}" = "--local" ] && LOCAL=1
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
# 本地化文案所在的 SwiftPM 资源包（与架构无关），以及 Info.plist 的本地化（权限说明）。
for B in CCDesk_CCDesk CCDesk_CCDeskCore; do
    cp -R "$BIN_DIR/$B.bundle" "$APP/Contents/Resources/"
done
cp -R scripts/Localization/*.lproj "$APP/Contents/Resources/"
# 内置 tmux 与第三方许可证；先签 helper 再签整个 App。
TMUX_BIN="$(./scripts/build-tmux.sh | tail -n 1)"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdPartyNotices"
cp "$TMUX_BIN" "$APP/Contents/Helpers/tmux"
cp "$(dirname "$TMUX_BIN")/LICENSES.txt" "$APP/Contents/Resources/ThirdPartyNotices/tmux.txt"
cp NOTICE "$APP/Contents/Resources/NOTICE"
lipo "$APP/Contents/Helpers/tmux" -verify_arch arm64 x86_64
# 签名：默认临时签名（公开发布用，开发证书的名字里带邮箱，不放进公开的包）。
# 加 --local（或设 CCDESK_SIGN_IDENTITY）时用和 bundle.sh 相同的开发证书：本机上安装版与开发版是同一个 App，
# 「文稿」文件夹等系统授权不会因为签名不同而反复弹窗。
IDENTITY="${CCDESK_SIGN_IDENTITY:--}"
if [ "$LOCAL" = 1 ] && [ -z "${CCDESK_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
    IDENTITY="${IDENTITY:--}"
fi
echo "signing with: $IDENTITY" >&2
codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/tmux"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGE/Applications"
# 窗口背景（箭头 + 安装提示）：1x / 2x 合成一个 TIFF，Retina 屏上也清晰。
mkdir -p "$STAGE/.background"
BG_TMP="$(mktemp -d)"
swift scripts/dmg-background.swift "$BG_TMP/bg.png" 1
swift scripts/dmg-background.swift "$BG_TMP/bg@2x.png" 2
tiffutil -cathidpicheck "$BG_TMP/bg.png" "$BG_TMP/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
rm -rf "$BG_TMP"

OUT="build/CCDesk-$VERSION.dmg"
RW="build/CCDesk-rw.dmg"
rm -f "$OUT" "$RW"
# 先做可写镜像，挂载后让 Finder 摆好窗口（大小、背景、图标位置，写进 .DS_Store），再压缩成只读。
hdiutil create -volname "CC Desk" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
# 已经挂着同名卷（如之前的 DMG）时新卷会叫「CC Desk 1」：按实际挂载点的名字操作。
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEVICE="$(printf '%s\n' "$ATTACH" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT="$(printf '%s\n' "$ATTACH" | awk -F '\t' '/Apple_HFS/ {print $NF; exit}')"
VOLNAME="$(basename "$MOUNT")"
osascript - "$VOLNAME" <<'APPLESCRIPT'
on run argv
tell application "Finder"
    tell disk (item 1 of argv)
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "CC Desk.app" of container window to {170, 180}
        set position of item "Applications" of container window to {470, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
end run
APPLESCRIPT
sync
hdiutil detach "$DEVICE" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
echo "$OUT"
