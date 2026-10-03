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
# 用固定的签名身份签名（默认取钥匙串里第一个 Apple Development 证书，可用 CCDESK_SIGN_IDENTITY 指定）：
# 临时签名（-）每次编译都像一个新 App，麦克风等系统授权会被重置。找不到证书时退回临时签名。
IDENTITY="${CCDESK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
# 刷新 LaunchServices 记录，让 Dock / 通知中心拿到最新图标。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "$APP"
