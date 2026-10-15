#!/usr/bin/env bash
# Builds Wingman, wraps it in an .app bundle, signs it locally, and
# installs it.
#
#   ./install.sh                     # installs to /Applications
#   DEST=~/Applications ./install.sh
#   APP_STORE=1 ./install.sh         # build without features the Mac App Store
#                                    # doesn't allow (following Teams/Zoom mute)
#   RELEASE=1 ./install.sh           # leave out the diagnostic command-line tools
#                                    # (they run with Wingman's permissions)
#   DEVELOPER_ID=1 ./install.sh      # sign with the Apple Developer ID certificate
#                                    # (hardened runtime, secure timestamp) so it
#                                    # can be notarized: scripts/notarize.sh
set -euo pipefail

APP="Wingman"
EXEC="Wingman"
DEST="${DEST:-/Applications}"
cd "$(dirname "$0")"

echo "==> Building…"
FLAGS=(-c release --disable-keychain)
# The App Store variant has no Sparkle code; dead_strip_dylibs drops the unused link too.
[[ -n "${APP_STORE:-}" ]] && FLAGS+=(-Xswiftc -DAPP_STORE -Xlinker -dead_strip_dylibs) && echo "    (App Store variant)"
[[ -n "${APP_STORE:-}${RELEASE:-}" ]] && FLAGS+=(-Xswiftc -DNO_DIAGNOSTICS) && echo "    (without diagnostic tools)"
# Releases build exactly the dependency versions in Package.resolved.
[[ -n "${RELEASE:-}" ]] && FLAGS+=(--only-use-versions-from-resolved-file)
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

BUNDLE=".build/$APP.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/$EXEC" "$BUNDLE/Contents/MacOS/$EXEC"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
# SwiftPM resource bundles from dependencies (tokenizers, configs, …).
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$BUNDLE/Contents/Resources/" \;
# Only releases update themselves: a build from source keeps your changes instead of
# being replaced by the next official version.
[[ -z "${RELEASE:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ''" "$BUNDLE/Contents/Info.plist"
# Sparkle (automatic updates) in Contents/Frameworks; not in the App Store variant.
if [[ -z "${APP_STORE:-}" ]]; then
  mkdir -p "$BUNDLE/Contents/Frameworks"
  ditto "$BIN/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$EXEC"
fi

# Sign with the certificate named exactly "Wingman" (by its fingerprint, so a
# similarly named one can't be picked), else an Apple developer identity, else
# ad hoc with a bundle-ID requirement. macOS ties Wingman's permissions to the
# signature, so builds signed with the same certificate keep them; builds for
# other people must use the Wingman certificate (scripts/make-release.sh checks).
# SIGN_IDENTITY picks another certificate (a contributor's own, see CONTRIBUTING).
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=$(awk '$3 == "\"Wingman\"" { print $2; exit }' <<<"$IDENTITIES")
NAME="Wingman"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SIGN_IDENTITY"
  NAME="$SIGN_IDENTITY"
fi
if [[ -z "$IDENTITY" ]]; then
  NAME=$(grep -oE '"(Developer ID Application|Apple Development)[^"]*"' <<<"$IDENTITIES" | head -1 | tr -d '"' || true)
  IDENTITY="$NAME"
fi
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  # The valid "Developer ID Application" certificate that lasts longest, by its
  # fingerprint: a renewed certificate has the same name as the one it replaces.
  IDENTITY=""
  LATEST=0
  while read -r hash; do
    end=$(security find-certificate -a -Z -c "Developer ID Application" -p 2>/dev/null \
      | awk -v h="$hash" '/^SHA-1 hash:/ { keep = ($3 == h) } keep' \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$end" ]] && continue
    secs=$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || echo 0)
    if (( secs > LATEST )); then LATEST=$secs; IDENTITY=$hash; fi
  done < <(awk '/"Developer ID Application/ { print $2 }' <<<"$IDENTITIES")
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no valid Developer ID Application certificate in the keychain" >&2
    exit 1
  fi
  NAME="Developer ID (${IDENTITY:0:8}…, until $(date -j -f %s "$LATEST" +%Y-%m-%d))"
fi
echo "==> Signing (${NAME:-ad hoc})…"
# Sparkle's helpers inside out, as its documentation asks (--deep alone can miss
# the Autoupdate tool), with the same identity as the app.
FW="$BUNDLE/Contents/Frameworks/Sparkle.framework"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  # Notarization needs the hardened runtime and Apple's timestamp on every piece
  # of code; Sparkle's helpers keep their own entitlements.
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
  if [[ -d "$FW" ]]; then
    for item in "$FW"/Versions/B/XPCServices/*.xpc "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do
      [[ -e "$item" ]] && "${SIGN[@]}" --preserve-metadata=entitlements "$item"
    done
    "${SIGN[@]}" "$FW"
  fi
  "${SIGN[@]}" --entitlements Wingman.entitlements "$BUNDLE"
elif [[ -d "$FW" ]]; then
  for item in "$FW"/Versions/B/XPCServices/*.xpc "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
    [[ -e "$item" ]] && codesign --force --sign "${IDENTITY:--}" --timestamp=none "$item"
  done
fi
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  :  # signed above
elif [[ -n "${IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$IDENTITY" --timestamp=none "$BUNDLE"
else
  # Ad hoc signatures are identified by their exact contents, so macOS treats
  # every rebuild as a new app and forgets its permissions (Microphone, System
  # Audio, Accessibility). Identify it by bundle ID instead so they persist.
  # Fine for local development builds; release builds use a real identity.
  # Trade-off: anything signed ad hoc with this bundle ID would match too, and
  # so inherit Wingman's permissions — acceptable on your own Mac only.
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Info.plist)
  codesign --force --deep --sign - --timestamp=none \
    -r="designated => identifier \"$BUNDLE_ID\"" "$BUNDLE"
fi

echo "==> Installing to $DEST…"
mkdir -p "$DEST"
rm -rf "$DEST/$APP.app"
cp -R "$BUNDLE" "$DEST/$APP.app"
echo "==> Done: $DEST/$APP.app"
