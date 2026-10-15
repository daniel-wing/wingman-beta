#!/usr/bin/env bash
# Sends a Developer ID–signed Wingman.app to Apple's notary service, waits for
# the verdict, staples the ticket to the app (so it opens without a network
# check), and checks macOS's own assessment. Only the app's code goes to Apple;
# nothing is published.
#
#   DEVELOPER_ID=1 RELEASE=1 DEST=/tmp/x ./install.sh
#   scripts/notarize.sh /tmp/x/Wingman.app
#
# Needs the notary login saved once in the keychain (the owner does this):
#   xcrun notarytool store-credentials wingman-notary --apple-id … --team-id …
# PROFILE=… picks another saved login.
set -euo pipefail
APP="${1:?usage: scripts/notarize.sh path/to/Wingman.app}"
PROFILE="${PROFILE:-wingman-notary}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

codesign --verify --deep --strict "$APP"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
if ! grep -q "^Authority=Developer ID Application:" <<<"$SIGNATURE"; then
  echo "error: not signed with a Developer ID certificate (DEVELOPER_ID=1 ./install.sh)" >&2
  exit 1
fi
if ! grep -q "flags=.*runtime" <<<"$SIGNATURE"; then
  echo "error: the hardened runtime is off; notarization would refuse it" >&2
  exit 1
fi

WORK=$(mktemp -d -t wingman-notary)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/$(basename "$APP" .app).zip"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo "==> Sending to Apple's notary service (usually a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/result.json" || true
STATUS=$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || echo unknown)
ID=$(plutil -extract id raw -o - "$WORK/result.json" 2>/dev/null || echo "")
echo "    $STATUS${ID:+ ($ID)}"
if [[ "$STATUS" != "Accepted" ]]; then
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
  echo "error: Apple didn't accept it" >&2
  exit 1
fi

echo "==> Stapling the ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# What Gatekeeper says when someone opens it.
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/    /'
