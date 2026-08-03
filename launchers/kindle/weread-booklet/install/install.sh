#!/bin/sh

[ -f ./libotautils5 ] && source ./libotautils5

fail_install() {
    logmsg "E" "install" "" "$1"
    return 1
}

otautils_update_progressbar

[ -x "/mnt/us/koreader/koreader.sh" ] \
    || fail_install "missing /mnt/us/koreader/koreader.sh" \
    || return 1
[ -f "/mnt/us/koreader/plugins/wereaddesktop.koplugin/main.lua" ] \
    || fail_install "missing wereaddesktop.koplugin" \
    || return 1

logmsg "I" "install" "" "installing WeRead booklet"
cp -f "WeReadBooklet.jar" "/opt/amazon/ebook/booklet/WeReadBooklet.jar" \
    || return 1

otautils_update_progressbar

logmsg "I" "install" "" "registering WeRead booklet"
sqlite3 "/var/local/appreg.db" < "appreg.install.sql" || return 1

otautils_update_progressbar

# Enable WhisperTouch on Voyage, matching upstream KOL behavior.
if has_fbink ; then
    eval "$(${FBINK_BIN} -e)"
    if [ "${deviceName:-}" = "Voyage" ] ; then
        logmsg "I" "install" "" "enabling whispertouch"
        sqlite3 "/var/local/appreg.db" < "whispertouch.install.sql" \
            || return 1
    fi
fi

otautils_update_progressbar

logmsg "I" "install" "" "creating WeRead home entry"
touch "/mnt/us/documents/微信读书.weread" || return 1

logmsg "I" "install" "" "installing KUAL fallback"
mkdir -p "/mnt/us/extensions/weread" || return 1
cp -f "extensions/weread/menu.json" "/mnt/us/extensions/weread/menu.json" \
    || return 1

otautils_update_progressbar

logmsg "I" "install" "" "done"
otautils_update_progressbar

return 0
