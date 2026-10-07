#!/usr/bin/env bash
# Builds the beta that testers download: without the diagnostic tools
# (RELEASE=1), signed with the "Wingman" certificate (macOS ties testers'
# permissions to it, so they're kept across updates and no other program can
# inherit them), zipped with ditto so the signature survives, without extended
# attributes. Upload the zip to a GitHub release of the public beta repo.
#
#   scripts/make-release.sh        → .build/dist/Wingman-<version>.zip (+ .sha256)
#                                    and .build/dist/appcast.xml (the update feed)
#
# Automatic updates: the zip is signed with the project's update key, which
# lives in your login keychain (Sparkle's generate_keys made it; keep a backup);
# Info.plist's SUPublicEDKey must be its public half. macOS may ask once to let
# Sparkle's tools use the key. Attach appcast.xml to the GitHub release:
# installed copies read releases/latest/download/appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" Info.plist 2>/dev/null || true)
MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Info.plist 2>/dev/null || echo 26.0)
REPO_URL="https://github.com/daniel-wing/wingman-beta"
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "error: Info.plist has no SUPublicEDKey, so this release couldn't update itself" >&2
  exit 1
fi
STAGE="$PWD/.build/release-stage"
OUT="$PWD/.build/dist"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"

# Built from a clean copy of the last commit in a neutral folder: what ships is
# exactly what's committed, and the paths the compiler records in the app (for
# crash messages, and SwiftPM's lookup of resource bundles) don't contain your
# home folder. The copy's .build stays, so later releases build faster.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit your changes first — the release is built from the last commit" >&2
  exit 1
fi
SRC=/private/tmp/wingman-release
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch -q "$PWD" HEAD
  git -C "$SRC" checkout -q --force --detach FETCH_HEAD
  git -C "$SRC" clean -q -f -d -x -e .build
else
  rm -rf "${SRC:?}"
  git clone -q "$PWD" "$SRC"
  git -C "$SRC" checkout -q --detach "$(git rev-parse HEAD)"
fi
(cd "$SRC" && RELEASE=1 DEST="$STAGE" ./install.sh)
APP="$STAGE/Wingman.app"
codesign --verify --deep --strict "$APP"
# Never ship an ad-hoc build: anything signed ad hoc with Wingman's bundle ID
# would match it and inherit testers' permissions.
SIGNATURE=$(codesign -dvv "$APP" 2>&1; codesign -dr - "$APP" 2>&1)
if ! grep -qx "Authority=Wingman" <<<"$SIGNATURE" || ! grep -q 'certificate leaf = H"' <<<"$SIGNATURE"; then
  echo "error: not signed with the Wingman certificate (see PROGRESS.md); refusing to ship it" >&2
  exit 1
fi
if "$APP/Contents/MacOS/Wingman" whosmic >/dev/null 2>&1; then
  echo "error: the diagnostic tools are still in the build" >&2
  exit 1
fi

ZIP="$OUT/Wingman-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")
echo "==> $ZIP"

# The update feed. The key in the keychain must match the one the app trusts,
# or every installed copy would reject this update.
TOOLS="$SRC/.build/artifacts/sparkle/Sparkle/bin"
if [[ "$("$TOOLS/generate_keys" -p 2>/dev/null)" != "$PUBLIC_KEY" ]]; then
  echo "error: the update key in your keychain isn't the one in Info.plist (SUPublicEDKey)" >&2
  exit 1
fi
SIGNED=$("$TOOLS/sign_update" "$ZIP")
cat > "$OUT/appcast.xml" <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wingman</title>
    <link>$REPO_URL</link>
    <item>
      <title>Wingman $VERSION</title>
      <link>$REPO_URL/releases/tag/v$VERSION</link>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/Wingman-$VERSION.zip" type="application/octet-stream" $SIGNED/>
    </item>
  </channel>
</rss>
FEED
xmllint --noout "$OUT/appcast.xml"
echo "==> $OUT/appcast.xml"
