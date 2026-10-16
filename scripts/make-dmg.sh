#!/usr/bin/env bash
# Builds the installer disk image testers download: a window with Wingman, an
# Applications shortcut and an arrow to drag it across. The app inside must
# already be notarized and stapled (scripts/make-release.sh does that); the
# image itself is then signed with the same Developer ID, notarized and
# stapled, and checked the way a browser download is opened.
#
#   scripts/make-dmg.sh path/to/Wingman.app .build/dist/Wingman-0.9.1.dmg
#
# The layout comes from scripts/dmg-settings.py, built by dmgbuild (MIT),
# installed at pinned versions in .build/dmgbuild-venv (not committed).
# Automatic updates keep using the zip.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: scripts/make-dmg.sh path/to/Wingman.app out.dmg}"
DMG="${2:?usage: scripts/make-dmg.sh path/to/Wingman.app out.dmg}"
PROFILE="${PROFILE:-wingman-notary}"

if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "error: $APP isn't notarized and stapled" >&2
  exit 1
fi
VENV=.build/dmgbuild-venv
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3
fi

WORK=$(mktemp -d -t wingman-dmg)
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-dmg-background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

echo "==> Building the disk image…"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" -D icon=Resources/AppIcon.icns \
  -D background="$WORK/background.tiff" "Wingman" "$DMG" >/dev/null

# Signed with exactly the certificate that signed the app inside (by its
# fingerprint: a renewed certificate has the same name).
codesign -d --extract-certificates="$WORK/leaf" "$APP" >/dev/null 2>&1
HASH=$(shasum "$WORK/leaf0" | cut -d' ' -f1 | tr a-f A-F)
if ! security find-identity -v -p codesigning | grep -q "$HASH"; then
  echo "error: the certificate that signed the app isn't in the keychain" >&2
  exit 1
fi
codesign --force --sign "$HASH" --timestamp "$DMG"

echo "==> Notarizing the disk image…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/result.json" || true
STATUS=$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || echo unknown)
echo "    $STATUS"
[[ "$STATUS" == "Accepted" ]] || { echo "error: Apple didn't accept the disk image" >&2; exit 1; }
xcrun stapler staple "$DMG" >/dev/null
xcrun stapler validate "$DMG" >/dev/null

# Opened the way a browser download is: quarantined.
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$DMG"
ASSESSMENT=$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)
xattr -d com.apple.quarantine "$DMG"
echo "$ASSESSMENT" | sed 's/^/    /'
grep -q "source=Notarized Developer ID" <<<"$ASSESSMENT" || { echo "error: Gatekeeper doesn't accept the disk image" >&2; exit 1; }
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "==> $DMG"
