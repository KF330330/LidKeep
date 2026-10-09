#!/bin/bash
# Only sourced by trusted Installer scripts or the root-owned installed uninstaller.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
APP=/Applications/LidKeep.app
HELPER=/Library/PrivilegedHelperTools/local.rl.lidkeep.service
SUPPORT='/Library/Application Support/LidKeep'
STATE=/var/db/local.rl.lidkeep
DAEMON=/Library/LaunchDaemons/local.rl.lidkeep.daemon.plist
WATCHDOG=/Library/LaunchDaemons/local.rl.lidkeep.watchdog.plist

fail() { /bin/echo "LidKeep: $*" >&2; exit 1; }
require_root() { [ "$EUID" -eq 0 ] || fail '需要通过 macOS 安装器授权或 sudo 运行。'; }
check_root_item() {
  local item="$1" mode
  [ ! -L "$item" ] || fail "拒绝符号链接：$item"
  [ -e "$item" ] || fail "路径不存在：$item"
  [ "$(/usr/bin/stat -f %u "$item")" = 0 ] || fail "路径必须由 root 拥有：$item"
  mode=$(/usr/bin/stat -f %OLp "$item")
  (( (8#$mode & 022) == 0 )) || fail "路径不能由其他用户写入：$item"
}
check_layout() {
  local item
  for item in /Library '/Library/Application Support' /Library/LaunchDaemons /var/db; do
    check_root_item "$item"
  done
  # macOS ships /Applications as root:admin 775; it is never a root executable source.
  [ -d /Applications ] && [ ! -L /Applications ] && [ "$(/usr/bin/stat -f %u /Applications)" = 0 ] || fail '/Applications 路径无效。'
  local applications_mode
  applications_mode=$(/usr/bin/stat -f %OLp /Applications)
  (( (8#$applications_mode & 002) == 0 )) || fail '/Applications 不能允许所有用户写入。'
  # Existing payload paths must be trustworthy before root reads or executes them.
  for item in /Library/PrivilegedHelperTools "$APP" "$HELPER" "$SUPPORT" "$STATE" "$DAEMON" "$WATCHDOG"; do
    if [ -e "$item" ] || [ -L "$item" ]; then check_root_item "$item"; fi
  done
}
enter_maintenance() {
  [ -d "$STATE" ] || /bin/mkdir -m 700 "$STATE"
  if [ -e "$STATE/maintenance" ] || [ -L "$STATE/maintenance" ]; then
    check_root_item "$STATE/maintenance"
    [ -f "$STATE/maintenance" ] || fail 'maintenance 必须是普通文件。'
  fi
  (umask 077; : > "$STATE/maintenance")
}
require_normal_sleep() {
  local value
  value=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" {value=$2; count++} END {if (count != 1) exit 1; print value}') || fail '无法读取 SleepDisabled。'
  [ "$value" = 0 ] || fail '检测到其他来源的 SleepDisabled=1；保留原设置并中止。请先停用原有禁用休眠工具。'
}
# Callers must enter maintenance first. Keep the verified signed bytes unchanged,
# but create the final executable locally instead of executing a pkg-extracted inode.
materialize_local_executable() (
  local target="$1" directory fresh='' item verification
  verification="$target"
  case "$target" in
    "$HELPER") check_root_item "${HELPER%/*}" ;;
    "$APP/Contents/MacOS/LidKeep")
      verification="$APP"
      for item in "$APP" "$APP/Contents" "$APP/Contents/MacOS"; do
        check_root_item "$item"
        [ -d "$item" ] || fail "程序父路径必须是目录：$item"
      done ;;
    *) fail '拒绝处理非 LidKeep 的可执行文件。' ;;
  esac
  directory="${target%/*}"
  [ -d "$directory" ] || fail '程序父路径必须是目录。'
  check_root_item "$target"
  [ -f "$target" ] && [ "$(/usr/bin/stat -f %l "$target")" = 1 ] || fail '可执行文件必须是无硬链接的普通文件。'
  /usr/bin/codesign --verify --strict "$verification" || fail '原程序签名无效。'
  trap 'if [ -n "$fresh" ]; then /bin/rm -f "$fresh"; fi' EXIT
  fresh=$(/usr/bin/mktemp "$directory/.lidkeep-local.XXXXXX") || fail '无法准备本机可执行文件。'
  /usr/bin/install -m 755 "$target" "$fresh" || fail '无法复制本机可执行文件。'
  /usr/bin/cmp -s "$target" "$fresh" || fail '本机副本字节不一致。'
  # App signatures require the original bundle path; cmp proves the temporary
  # Mach-O is identical, then the complete bundle is verified after replacement.
  if [ "$target" = "$HELPER" ]; then
    /usr/bin/codesign --verify --strict "$fresh" || fail '本机副本签名无效。'
  fi
  check_root_item "$fresh"
  if [ "$target" = "$HELPER" ]; then
    "$fresh" --diagnose >/dev/null || fail '本机后台启动自检失败，原文件未替换。'
  fi
  /bin/mv -f "$fresh" "$target" || fail '无法原子替换本机可执行文件。'
  fresh=''
  /usr/bin/codesign --verify --strict "$verification" || fail '本机最终程序签名无效。'
)
restore_owned_state() {
  enter_maintenance
  if [ -e "$HELPER" ]; then
    materialize_local_executable "$HELPER" || fail '后台程序本机最终化失败，已保留维护状态。'
    "$HELPER" --restore || fail '恢复本程序接管前的休眠设置失败，已保留文件以便恢复。'
  else
    require_normal_sleep
  fi
}
stop_services() {
  local label
  for label in local.rl.lidkeep.daemon local.rl.lidkeep.watchdog; do
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
      /bin/launchctl bootout "system/$label" || fail "停止 $label 失败。"
    fi
  done
}
