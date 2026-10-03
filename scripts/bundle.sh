#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product CCDesk
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/CCDesk"
APP="build/CCDesk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CCDesk"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SWIFTTERM_BUNDLE="$BIN_DIR/SwiftTerm_SwiftTerm.bundle"
if [ -e "$SWIFTTERM_BUNDLE" ]; then
    cp -R "$SWIFTTERM_BUNDLE" "$APP/Contents/Resources/"
fi
# 本地化文案所在的 SwiftPM 资源包（代码在 Contents/Resources 里查找），以及 Info.plist 的本地化（权限说明）。
for B in CCDesk_CCDesk CCDesk_CCDeskCore; do
    cp -R "$BIN_DIR/$B.bundle" "$APP/Contents/Resources/"
done
cp -R scripts/Localization/*.lproj "$APP/Contents/Resources/"
# 内置 tmux（会话跨 App 重启保持）：本地开发默认不内置（用 Homebrew 的 tmux，编译更快），
# CCDESK_BUNDLE_TMUX=1 时与 DMG 一样内置从源码编译的通用 tmux（结果缓存在 build/tmux/）。
if [ "${CCDESK_BUNDLE_TMUX:-0}" = "1" ]; then
    TMUX_BIN="$(./scripts/build-tmux.sh | tail -n 1)"
    mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdPartyNotices"
    cp "$TMUX_BIN" "$APP/Contents/Helpers/tmux"
    cp "$(dirname "$TMUX_BIN")/LICENSES.txt" "$APP/Contents/Resources/ThirdPartyNotices/tmux.txt"
fi
cp NOTICE "$APP/Contents/Resources/NOTICE"
# 用固定的签名身份签名（默认取钥匙串里第一个 Apple Development 证书，可用 CCDESK_SIGN_IDENTITY 指定）：
# 临时签名（-）每次编译都像一个新 App，麦克风等系统授权会被重置。找不到证书时退回临时签名。
IDENTITY="${CCDESK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -e "$APP/Contents/Helpers/tmux" ]; then
    codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Helpers/tmux"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
# 刷新 LaunchServices 记录，让 Dock / 通知中心拿到最新图标。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "$APP"
