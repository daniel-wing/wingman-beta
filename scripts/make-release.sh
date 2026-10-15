#!/usr/bin/env bash
# Builds the beta that testers download: without the diagnostic tools
# (RELEASE=1), signed with the maintainer's Apple Developer ID (hardened
# runtime, Apple timestamp) and notarized by Apple, so it opens without
# warnings; macOS ties testers' permissions to that signature. Zipped with
# ditto after the notarization ticket is stapled, without extended
# attributes. Upload the zip to a GitHub release of the public beta repo.
#
# Needs, on the build Mac: the Developer ID Application certificate in the
# login keychain, the notary login saved as "wingman-notary" (see
# scripts/notarize.sh), and the expected Team ID in
# ~/.config/wingman/team-id (kept out of the repo; a build signed by any
# other team is refused).
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
# The tests first: a release is built only from a commit that passes them.
TEST_FLAGS=()
CLT=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* ]]; then
  # Without Xcode, SwiftPM can't find the Testing framework by itself.
  TEST_FLAGS=(-Xswiftc -F -Xswiftc "$CLT" -Xlinker -F -Xlinker "$CLT" -Xlinker -rpath -Xlinker "$CLT"
              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib)
fi
echo "==> Testing…"
if ! (cd "$SRC" && swift test --disable-keychain --only-use-versions-from-resolved-file "${TEST_FLAGS[@]}" > "$STAGE/tests.log" 2>&1); then
  tail -20 "$STAGE/tests.log" >&2
  echo "error: the tests fail; refusing to build a release" >&2
  exit 1
fi
grep -E "Test run with" "$STAGE/tests.log" | tail -1
TEAM_FILE="$HOME/.config/wingman/team-id"
EXPECTED_TEAM=$(tr -d '[:space:]' < "$TEAM_FILE" 2>/dev/null || true)
if [[ -z "$EXPECTED_TEAM" ]]; then
  echo "error: put the Developer ID Team ID in $TEAM_FILE" >&2
  exit 1
fi
(cd "$SRC" && DEVELOPER_ID=1 RELEASE=1 DEST="$STAGE" ./install.sh)
APP="$STAGE/Wingman.app"
codesign --verify --deep --strict "$APP"
# Never ship anything but the expected Developer ID: an ad hoc build would let
# any program signed ad hoc with Wingman's bundle ID inherit testers'
# permissions, and another team's signature isn't ours.
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
if ! grep -q "^Authority=Developer ID Application:" <<<"$SIGNATURE" || ! grep -qx "TeamIdentifier=$EXPECTED_TEAM" <<<"$SIGNATURE" \
   || ! grep -q "flags=.*runtime" <<<"$SIGNATURE"; then
  echo "error: not signed with the expected Developer ID and hardened runtime; refusing to ship it" >&2
  exit 1
fi
# A renewed certificate is needed for releases after this one expires
# (released versions keep working: they carry Apple's timestamp).
END=$(codesign -d --extract-certificates="$STAGE/cert" "$APP" >/dev/null 2>&1 && openssl x509 -inform DER -in "$STAGE/cert0" -noout -enddate | cut -d= -f2)
if [[ -n "$END" ]]; then
  DAYS=$(( ($(date -j -f "%b %e %T %Y %Z" "$END" +%s) - $(date +%s)) / 86400 ))
  (( DAYS < 60 )) && echo "warning: the Developer ID certificate expires in $DAYS days ($END): renew it before the next release" >&2
fi
rm -f "$STAGE"/cert*
if "$APP/Contents/MacOS/Wingman" whosmic >/dev/null 2>&1; then
  echo "error: the diagnostic tools are still in the build" >&2
  exit 1
fi

# Apple's notary service, then the ticket stapled to the app (no network
# check needed when testers open it).
scripts/notarize.sh "$APP"

ZIP="$OUT/Wingman-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
# The exact zip testers get, opened the way a browser download is (quarantined):
# Gatekeeper must accept it as notarized.
CHECK=$(mktemp -d -t wingman-gatekeeper)
ditto -x -k "$ZIP" "$CHECK"
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$CHECK/Wingman.app"
ASSESSMENT=$(spctl --assess --type execute -vv "$CHECK/Wingman.app" 2>&1 || true)
echo "$ASSESSMENT" | sed 's/^/    /'
if ! grep -q "source=Notarized Developer ID" <<<"$ASSESSMENT"; then
  rm -rf "$CHECK"
  echo "error: Gatekeeper doesn't accept the zip as notarized" >&2
  exit 1
fi
rm -rf "$CHECK"
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

# What goes public: the public part of this commit, the zip and the public
# repo's history, checked for identifying details. Nothing ships if it fails.
PUBLIC="$PWD/.build/public-repo"
if [[ ! -d "$PUBLIC/.git" ]]; then
  echo "error: clone the public repo first: git clone https://github.com/daniel-wing/wingman-beta.git .build/public-repo" >&2
  exit 1
fi
scripts/export-public.sh "$PUBLIC" >/dev/null
echo "==> Checking what goes public…"
scripts/check-public.sh --zip "$ZIP" --repo "$PUBLIC" "$PUBLIC" beta-site
