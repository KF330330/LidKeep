#!/bin/bash
# Build and package locally; never install or modify live power settings.
set -euo pipefail
umask 022
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$EUID" -ne 0 ] || { /bin/echo '请以普通用户构建，不要 sudo。' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-cache"
[ "$(/usr/bin/uname -m)" = arm64 ] || { /bin/echo '此构建针对 Apple Silicon。' >&2; exit 1; }
/usr/bin/swift build --disable-sandbox -c release --arch arm64 --jobs 2
BIN_DIR=$(/usr/bin/swift build --disable-sandbox -c release --arch arm64 --show-bin-path)
/bin/mkdir -p "$ROOT/dist" "$ROOT/.build"
# File Provider can asynchronously add FinderInfo to bundles in Documents,
# including hidden .build directories. Stage outside synced trees before signing.
STAGE=$(/usr/bin/mktemp -d /private/tmp/lidkeep-package.XXXXXX)
trap '/bin/rm -rf "$STAGE"' EXIT
PAYLOAD="$STAGE/payload"
APP="$PAYLOAD/Applications/LidKeep.app"
SUPPORT="$PAYLOAD/Library/Application Support/LidKeep"
HELPER="$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/docs" "$SUPPORT" "$PAYLOAD/Library/PrivilegedHelperTools" "$PAYLOAD/Library/LaunchDaemons" "$STAGE/installer-scripts"
/usr/bin/install -m 755 "$BIN_DIR/LidKeep" "$APP/Contents/MacOS/LidKeep"
/usr/bin/install -m 644 "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/install -m 644 "$ROOT/README.md" "$APP/Contents/Resources/README.md"
/usr/bin/swift "$ROOT/scripts/generate-icons.swift" "$STAGE/icons"
/usr/bin/install -m 644 "$STAGE/icons/AppIcon.icns" "$STAGE/icons/StatusIcon.pdf" "$APP/Contents/Resources/"
/usr/bin/find "$ROOT/docs" -type f -name '*.md' -print0 > "$STAGE/documents.list"
while IFS= read -r -d '' document; do
  destination="$APP/Contents/Resources/docs/${document#"$ROOT/docs/"}"
  /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
  /usr/bin/install -m 644 "$document" "$destination"
done < "$STAGE/documents.list"
/usr/bin/install -m 755 "$BIN_DIR/lidkeep-service" "$HELPER"
/usr/bin/codesign --force --sign - --options runtime --identifier local.rl.lidkeep.service "$HELPER"
/usr/bin/codesign --force --sign - --options runtime "$APP"
/usr/bin/codesign --verify --strict "$HELPER"
/usr/bin/codesign --verify --strict "$APP"
cdhash() {
  local hash
  hash=$(/usr/bin/codesign -d --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" {print $2}')
  [[ "$hash" =~ ^[0-9a-f]{40}$ ]] || { /bin/echo "无法读取唯一 CDHash：$1" >&2; exit 1; }
  /bin/echo "$hash"
}
APP_HASH=$(cdhash "$APP")
SERVICE_HASH=$(cdhash "$HELPER")
/usr/bin/printf '{"clientRequirement":"cdhash H\\"%s\\"","serviceRequirement":"cdhash H\\"%s\\""}\n' "$APP_HASH" "$SERVICE_HASH" > "$SUPPORT/identity.json"
/usr/bin/install -m 755 "$ROOT/scripts/uninstall.sh" "$SUPPORT/uninstall.sh"
/usr/bin/install -m 644 "$ROOT/packaging/scripts/management-common.sh" "$SUPPORT/management-common.sh"
/usr/bin/install -m 644 "$ROOT/packaging/local.rl.lidkeep.daemon.plist" "$ROOT/packaging/local.rl.lidkeep.watchdog.plist" "$PAYLOAD/Library/LaunchDaemons/"
/usr/bin/install -m 755 "$ROOT/packaging/scripts/preinstall" "$ROOT/packaging/scripts/postinstall" "$STAGE/installer-scripts/"
/usr/bin/install -m 644 "$ROOT/packaging/scripts/management-common.sh" "$STAGE/installer-scripts/management-common.sh"
/bin/chmod -R go-w "$PAYLOAD"
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/packaging/Info.plist")
/usr/bin/pkgbuild --root "$PAYLOAD" --component-plist "$ROOT/packaging/components.plist" \
  --scripts "$STAGE/installer-scripts" --identifier local.rl.lidkeep --version "$VERSION" \
  --install-location / --ownership recommended "$STAGE/LidKeep.pkg"
# Archive the clean signed bundle before exposing artifacts to File Provider.
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$STAGE/LidKeep.app.zip"
# Keep a temporary native bundle available for local UI preview outside sync.
PREVIEW=$(/usr/bin/mktemp -d /private/tmp/lidkeep-preview.XXXXXX)
/bin/mv "$APP" "$PREVIEW/LidKeep.app"
/usr/bin/codesign --verify --strict "$PREVIEW/LidKeep.app"
# Publish only the complete matching archive/package pair. Remove legacy loose output.
if [ -e "$ROOT/dist/LidKeep.app" ]; then /bin/rm -rf "$ROOT/dist/LidKeep.app"; fi
/bin/mv -f "$STAGE/LidKeep.app.zip" "$ROOT/dist/LidKeep.app.zip"
/bin/mv -f "$STAGE/LidKeep.pkg" "$ROOT/dist/LidKeep.pkg"
/usr/bin/printf '%s\n' "$PREVIEW/LidKeep.app" > "$ROOT/dist/preview-path.txt"
/bin/echo "构建完成：$ROOT/dist/LidKeep.pkg"
/bin/echo "签名 App 压缩包：$ROOT/dist/LidKeep.app.zip"
/bin/echo "临时原生预览：$PREVIEW/LidKeep.app"
