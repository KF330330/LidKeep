#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$EUID" -eq 0 ] || { /bin/echo '请使用 sudo 运行已安装的卸载器。' >&2; exit 1; }
# Validate every non-system component before sourcing code as root.
for item in /Library '/Library/Application Support' '/Library/Application Support/LidKeep' '/Library/Application Support/LidKeep/management-common.sh'; do
  [ ! -L "$item" ] && [ -e "$item" ] && [ "$(/usr/bin/stat -f %u "$item")" = 0 ] || exit 1
  mode=$(/usr/bin/stat -f %OLp "$item")
  (( (8#$mode & 022) == 0 )) || exit 1
done
. '/Library/Application Support/LidKeep/management-common.sh'
check_layout
enter_maintenance
restore_owned_state
stop_services
restore_owned_state
# Remove only LidKeep-owned paths, after both verified restorations succeeded.
/bin/rm -f "$DAEMON" "$WATCHDOG" "$HELPER"
/bin/rm -rf "$APP" "$SUPPORT" "$STATE"
/usr/sbin/pkgutil --forget local.rl.lidkeep >/dev/null 2>&1 || true
/bin/echo 'LidKeep 已卸载，休眠设置已恢复。其他 caffeinate 服务未修改。'
