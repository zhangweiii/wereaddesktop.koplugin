#!/bin/sh

[ -f ./libotautils5 ] && source ./libotautils5

otautils_update_progressbar

logmsg "I" "uninstall" "" "uninstalling WeRead booklet"
rm -f "/opt/amazon/ebook/booklet/WeReadBooklet.jar"

otautils_update_progressbar

logmsg "I" "uninstall" "" "deregistering WeRead booklet"
sqlite3 "/var/local/appreg.db" < "appreg.uninstall.sql" || return 1

otautils_update_progressbar

logmsg "I" "uninstall" "" "removing WeRead home entry and KUAL fallback"
rm -f "/mnt/us/documents/微信读书.weread"
rm -f "/mnt/us/extensions/weread/menu.json"
rmdir "/mnt/us/extensions/weread" 2>/dev/null || true

otautils_update_progressbar

logmsg "I" "uninstall" "" "done"
otautils_update_progressbar

return 0
