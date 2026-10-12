#!/bin/bash
# Native macOS installer. Public mode requires Developer ID and notarization.
set -euo pipefail
APP_PATH="${BRUMA_APP_PATH:-/Applications/Bruma.app}"
OUT_DIR="${BRUMA_RELEASE_DIR:-$HOME/Downloads/Bruma-Release}"
MODE="${BRUMA_RELEASE_MODE:-local}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
if [[ "$MODE" != local && "$MODE" != public ]]; then
    echo 'BRUMA_RELEASE_MODE must be local or public' >&2; exit 1
fi
if [[ "$MODE" == public ]]; then
    : "${BRUMA_APPLICATION_IDENTITY:?Developer ID Application identity required}"
    : "${BRUMA_INSTALLER_IDENTITY:?Developer ID Installer identity required}"
    : "${BRUMA_NOTARY_PROFILE:?notarytool keychain profile required}"
fi
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bruma-release.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/root/Applications" "$TMP_DIR/scripts" "$TMP_DIR/resources" "$OUT_DIR"
/usr/bin/ditto "$APP_PATH" "$TMP_DIR/root/Applications/Bruma.app"
STAGED_APP="$TMP_DIR/root/Applications/Bruma.app"
if [[ "$MODE" == public ]]; then
    cat > "$TMP_DIR/extension.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
    /usr/bin/codesign --force --options runtime --timestamp --sign "$BRUMA_APPLICATION_IDENTITY" "$STAGED_APP/Contents/Frameworks/AUv3FilterFramework.framework"
    /usr/bin/codesign --force --options runtime --timestamp --entitlements "$TMP_DIR/extension.entitlements" --sign "$BRUMA_APPLICATION_IDENTITY" "$STAGED_APP/Contents/PlugIns/AUv3FilterExtension.appex"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$BRUMA_APPLICATION_IDENTITY" "$STAGED_APP"
fi
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
cat > "$TMP_DIR/scripts/postinstall" <<'POST'
#!/bin/bash
# Register with the active user's LaunchServices and Audio Unit registry.
# When no GUI user is logged in, opening Bruma later completes registration.
APP=/Applications/Bruma.app
USER_UID=$(/usr/bin/stat -f %u /dev/console)
if [[ "$USER_UID" -ge 500 ]]; then
    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "#$USER_UID" /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "#$USER_UID" /usr/bin/pluginkit -a "$APP/Contents/PlugIns/AUv3FilterExtension.appex" || true
fi
exit 0
POST
chmod 755 "$TMP_DIR/scripts/postinstall"
/usr/bin/pkgbuild --analyze --root "$TMP_DIR/root" "$TMP_DIR/components.plist"
INDEX=0
while /usr/libexec/PlistBuddy -c "Print :$INDEX:RootRelativeBundlePath" "$TMP_DIR/components.plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Set :$INDEX:BundleIsRelocatable false" "$TMP_DIR/components.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$INDEX:BundleIsRelocatable bool false" "$TMP_DIR/components.plist"
    /usr/libexec/PlistBuddy -c "Set :$INDEX:BundleIsVersionChecked false" "$TMP_DIR/components.plist"
    INDEX=$((INDEX + 1))
done
/usr/bin/pkgbuild --root "$TMP_DIR/root" --component-plist "$TMP_DIR/components.plist" --scripts "$TMP_DIR/scripts" --identifier com.leotsuka.Bruma.installer --version "$VERSION" --install-location / "$TMP_DIR/Bruma-component.pkg"
cat > "$TMP_DIR/resources/welcome.html" <<'HTML'
<html><meta charset="utf-8"><body><h1>Bruma</h1><p>Suite de efectos Audio Unit para GarageBand. Incluye EQ, overdrive, compresor, chorus, delay y reverb híbrida con Reverse Gate.</p><p>Compatible con macOS 12 o posterior, Intel y Apple Silicon.</p><p>Guarda tu proyecto y cierra GarageBand antes de actualizar Bruma.</p></body></html>
HTML
cat > "$TMP_DIR/resources/conclusion.html" <<'HTML'
<html><meta charset="utf-8"><body><h1>Bruma instalada</h1><p>Abre Bruma desde Aplicaciones una vez. Después abre GarageBand y busca Bruma en Audio Units, fabricante Ltsk.</p><p>Si GarageBand estaba abierto durante la instalación, ciérralo y vuelve a abrirlo para cargar la versión nueva.</p></body></html>
HTML
cat > "$TMP_DIR/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>Bruma $VERSION</title>
<welcome file="welcome.html"/>
<conclusion file="conclusion.html"/>
<options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
<choices-outline><line choice="default"/></choices-outline>
<choice id="default" visible="false" title="Bruma"><pkg-ref id="com.leotsuka.Bruma.installer"/></choice>
<pkg-ref id="com.leotsuka.Bruma.installer" version="$VERSION" onConclusion="none">Bruma-component.pkg</pkg-ref>
</installer-gui-script>
XML
PKG="$OUT_DIR/Bruma-$VERSION-macOS.pkg"
if [[ "$MODE" == public ]]; then
    /usr/bin/productbuild --distribution "$TMP_DIR/distribution.xml" --resources "$TMP_DIR/resources" --package-path "$TMP_DIR" --sign "$BRUMA_INSTALLER_IDENTITY" "$PKG"
    /usr/bin/xcrun notarytool submit "$PKG" --keychain-profile "$BRUMA_NOTARY_PROFILE" --wait --output-format json > "$TMP_DIR/notarization.json"
    STATUS=$(/usr/bin/plutil -extract status raw -o - "$TMP_DIR/notarization.json")
    if [[ "$STATUS" != Accepted ]]; then
        cat "$TMP_DIR/notarization.json" >&2
        echo "Notarization was not accepted; do not publish this package." >&2
        exit 1
    fi
    /usr/bin/xcrun stapler staple "$PKG"
    /usr/bin/xcrun stapler validate "$PKG"
    /usr/sbin/spctl --assess --type install --verbose "$PKG"
else
    /usr/bin/productbuild --distribution "$TMP_DIR/distribution.xml" --resources "$TMP_DIR/resources" --package-path "$TMP_DIR" "$PKG"
fi
(cd "$OUT_DIR" && /usr/bin/shasum -a 256 "$(basename "$PKG")" > SHA256SUMS.txt)
printf 'Installer: %s\nMode: %s\n' "$PKG" "$MODE"
