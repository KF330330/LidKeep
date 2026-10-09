#!/bin/bash
# Artifact validation; no install, launchctl, or power-setting mutations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for script in "$ROOT"/scripts/*.sh "$ROOT"/packaging/scripts/*; do
  /bin/bash -n "$script"
done
for plist in "$ROOT"/packaging/*.plist; do
  /usr/bin/plutil -lint "$plist"
done
if [ -e "$ROOT/dist/LidKeep.pkg" ]; then
  CHECK=$(/usr/bin/mktemp -d /private/tmp/lidkeep-check.XXXXXX)
  trap '/bin/rm -rf "$CHECK"' EXIT
  /usr/sbin/pkgutil --expand-full "$ROOT/dist/LidKeep.pkg" "$CHECK/expanded"
  PAYLOAD="$CHECK/expanded/Payload"
  IDENTITY="$PAYLOAD/Library/Application Support/LidKeep/identity.json"
  CLIENT_REQUIREMENT=$(/usr/bin/plutil -extract clientRequirement raw "$IDENTITY")
  SERVICE_REQUIREMENT=$(/usr/bin/plutil -extract serviceRequirement raw "$IDENTITY")
  ICON_NAME=$(/usr/bin/plutil -extract CFBundleIconFile raw "$PAYLOAD/Applications/LidKeep.app/Contents/Info.plist")
  [ "$ICON_NAME" = AppIcon.icns ]
  [ -s "$PAYLOAD/Applications/LidKeep.app/Contents/Resources/AppIcon.icns" ]
  [ -s "$PAYLOAD/Applications/LidKeep.app/Contents/Resources/StatusIcon.pdf" ]
  /usr/bin/iconutil --convert iconset --output "$CHECK/AppIcon.iconset" "$PAYLOAD/Applications/LidKeep.app/Contents/Resources/AppIcon.icns"
  for name in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png; do
    [ -s "$CHECK/AppIcon.iconset/$name" ]
  done
  /usr/bin/codesign --verify --strict --test-requirement "=$CLIENT_REQUIREMENT" "$PAYLOAD/Applications/LidKeep.app"
  /usr/bin/codesign --verify --strict --test-requirement "=$SERVICE_REQUIREMENT" "$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service"
  /usr/bin/ditto -x -k "$ROOT/dist/LidKeep.app.zip" "$CHECK/archive"
  /usr/bin/codesign --verify --strict --test-requirement "=$CLIENT_REQUIREMENT" "$CHECK/archive/LidKeep.app"
  for binary in "$PAYLOAD/Applications/LidKeep.app" "$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service"; do
    # Explicit empty entitlements are unnecessary; signed release executables carry none.
    ENTITLEMENTS=$(/usr/bin/codesign -d --entitlements - "$binary" 2>/dev/null)
    if [ -n "$ENTITLEMENTS" ]; then
      /bin/echo '产物含有意外 entitlement，停止验收。' >&2
      exit 1
    fi
    /usr/bin/codesign -d --verbose=4 "$binary" 2>&1 | /usr/bin/awk '/flags=.*runtime/ {found=1} END {exit !found}'
  done
  # The receipt must install all payload entries as root:wheel.
  /usr/bin/lsbom -p ug "$CHECK/expanded/Bom" | /usr/bin/awk '$1 != 0 || $2 != 0 {bad=1} END {exit bad}'
  [ -x "$PAYLOAD/Library/Application Support/LidKeep/uninstall.sh" ]
  for label in daemon watchdog; do
    /usr/bin/plutil -lint "$PAYLOAD/Library/LaunchDaemons/local.rl.lidkeep.$label.plist"
  done
  # Rehearse the installer's local finalization in a user-owned temporary fixture.
  # Static signature verification alone does not prove macOS will execute a file.
  (
    . "$CHECK/expanded/Scripts/management-common.sh"
    APP="$PAYLOAD/Applications/LidKeep.app"
    HELPER="$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service"
    check_root_item() {
      local mode
      [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = "$EUID" ] || fail '不安全的测试路径。'
      mode=$(/usr/bin/stat -f %OLp "$1")
      (( (8#$mode & 022) == 0 )) || fail '测试路径允许其他用户写入。'
    }
    materialize_local_executable "$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service"
    materialize_local_executable "$PAYLOAD/Applications/LidKeep.app/Contents/MacOS/LidKeep"
    /usr/bin/codesign --verify --strict --test-requirement "=$SERVICE_REQUIREMENT" "$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service"
    /usr/bin/codesign --verify --strict --test-requirement "=$CLIENT_REQUIREMENT" "$PAYLOAD/Applications/LidKeep.app"
    "$PAYLOAD/Library/PrivilegedHelperTools/local.rl.lidkeep.service" --diagnose
    "$PAYLOAD/Applications/LidKeep.app/Contents/MacOS/LidKeep" --self-check
  )
  /bin/echo '安装包身份匹配、签名、root:wheel 归属与后台清单检查通过。'
fi
/bin/echo '脚本语法、plist 与现有产物检查完成；未改变系统设置。'
