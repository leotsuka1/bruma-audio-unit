#!/bin/bash
# Remove the Bruma app installed by the macOS release package.
set -euo pipefail

APP_PATH="/Applications/Bruma.app"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/AUv3FilterExtension.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script as an administrator: sudo bash \"$0\"" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Bruma was not found at $APP_PATH. Nothing was removed."
    exit 0
fi

echo "This will remove $APP_PATH. Bruma presets and other user data will be kept."
read -r -p "Continue? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "Uninstall cancelled."; exit 0 ;;
esac

USER_UID=$(/usr/bin/stat -f %u /dev/console)
if [[ "$USER_UID" -ge 500 ]]; then
    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "#$USER_UID" \
        /usr/bin/pluginkit -r "$EXTENSION_PATH" >/dev/null 2>&1 || true
    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "#$USER_UID" \
        "$LSREGISTER" -u "$APP_PATH" >/dev/null 2>&1 || true
fi

/bin/rm -rf "$APP_PATH"
echo "Bruma has been removed. Restart GarageBand to refresh its Audio Units list."
