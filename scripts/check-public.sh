#!/usr/bin/env bash
# Fails if anything meant for the public could identify the owner's devices,
# computer or workplace: the beta site's files, the release zip (file names,
# the bytes of every file in it including the app itself, and the signing
# certificate) and, with --repo, the public repo's commits (authors must use
# the GitHub no-reply address).
#
#   scripts/check-public.sh [--zip FILE] [--repo DIR] [PATH…]
#     defaults: beta-site/ and .build/dist/Wingman-<version>.zip if it exists
#
# The denylist comes from this Mac (home folder, computer and host names,
# audio and Bluetooth device names) plus a private list — one term per line,
# never committed: workplace, clients, colleagues, projects — in
# ~/.config/wingman/denylist.txt (or the file in $WINGMAN_DENYLIST).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="" REPO="" PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip) ZIP="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
[[ ${#PATHS[@]} -eq 0 ]] && PATHS=(beta-site)
[[ -z "$ZIP" && -f ".build/dist/Wingman-$VERSION.zip" ]] && ZIP=".build/dist/Wingman-$VERSION.zip"
PRIVATE="${WINGMAN_DENYLIST:-$HOME/.config/wingman/denylist.txt}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DENY="$WORK/deny.txt"
{
  echo "$HOME"
  scutil --get ComputerName 2>/dev/null || true
  scutil --get LocalHostName 2>/dev/null || true
  hostname -s
  # Device names, except the built-in ones every Mac of a model shares.
  system_profiler SPAudioDataType SPBluetoothDataType 2>/dev/null \
    | sed -nE 's/^ {8}( {2})?([^ ].*):$/\2/p' \
    | grep -vxE '(MacBook (Pro|Air)|iMac|Mac mini|Mac Studio|Mac Pro|Studio Display)( Microphone| Speakers)?|Microsoft Teams Audio' \
    || true
  if [[ -f "$PRIVATE" ]]; then grep -vE '^[[:space:]]*(#|$)' "$PRIVATE" || true; fi
} | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | sed -e p -e "s/’/'/g" | awk 'length >= 3' | sort -u > "$DENY"

HITS=0
problem() { echo "✗ $*"; HITS=$((HITS + 1)); }

# Third-party licence notices and placeholders are the only addresses allowed.
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(com|org|net|io|dev|me|mx|ai|app|co|edu|gov|info|us|uk|de|es)'
ALLOWED='@users\.noreply\.github\.com$|@example\.(com|org|net)$|^noreply@anthropic\.com$|^ibireme@gmail\.com$|^orsonpeters@gmail\.com$'
# Third-party authors credited in licence notices, whose names can contain a term
# from the lists above; they're removed before matching (exact phrases only).
CREDITS=("Andy Matuschak")

# Bytes, not text: also finds names inside binaries (UTF-8 apostrophes included).
scan() {  # label, file
  local term credit left
  while IFS= read -r term; do
    [[ -z "$term" ]] && continue
    # Matches inside a known third-party credit don't count.
    left=$(LC_ALL=C grep -a -i -w -F -o -- "$term" "$2" | wc -l)
    for credit in "${CREDITS[@]}"; do
      if LC_ALL=C grep -q -i -w -F -- "$term" <<<"$credit"; then
        left=$(( left - $(LC_ALL=C grep -a -i -F -o -- "$credit" "$2" | wc -l) ))
      fi
    done
    if (( left > 0 )); then problem "$1 contains \"$term\""; fi
  done < <(LC_ALL=C grep -a -i -w -F -o -f "$DENY" "$2" | sort -uf || true)
  while IFS= read -r term; do
    [[ -n "$term" ]] && problem "$1 contains the address $term"
  done < <(LC_ALL=C grep -a -o -E "$EMAIL" "$2" | sort -u | grep -viE "$ALLOWED" || true)
}

scanned=()
for path in "${PATHS[@]}"; do
  # A path that isn't there must fail, not pass as "nothing found".
  if [[ ! -e "$path" ]]; then
    problem "$path doesn't exist, so it wasn't checked"
    continue
  fi
  files=0
  while IFS= read -r -d '' file; do
    scan "${file#./}" "$file"
    files=$((files + 1))
  done < <(find "$path" -type f -not -path "*/.git/*" -print0)
  (( files > 0 )) || problem "$path has no files to check"
  scanned+=("$path ($files files)")
done

if [[ -n "$ZIP" ]]; then
  zipinfo -1 "$ZIP" > "$WORK/names.txt"
  scan "$(basename "$ZIP") (file names)" "$WORK/names.txt"
  ditto -x -k "$ZIP" "$WORK/zip"
  while IFS= read -r -d '' file; do
    scan "$(basename "$ZIP"):${file#"$WORK/zip/"}" "$file"
  done < <(find "$WORK/zip" -type f -print0)
  # Extended attributes travel in a zip as AppleDouble files. (Unzipping here adds
  # macOS's own com.apple.provenance, so the extracted copy can't tell.)
  ! grep -qE '(^|/)(__MACOSX/|\._)' "$WORK/names.txt" || problem "$(basename "$ZIP") carries extended attributes"
  APP=$(find "$WORK/zip" -maxdepth 1 -name "*.app" | head -1)
  if codesign -d --extract-certificates="$WORK/cert" "$APP" 2>/dev/null && [[ -f "$WORK/cert0" ]]; then
    openssl x509 -inform DER -in "$WORK/cert0" -noout -subject > "$WORK/subject.txt"
    echo "  certificate: $(cat "$WORK/subject.txt")"
    scan "the signing certificate" "$WORK/subject.txt"
  else
    problem "$(basename "$ZIP"): the app isn't signed with a certificate"
  fi
  scanned+=("$(basename "$ZIP")")
fi

if [[ -n "$REPO" ]]; then
  while IFS= read -r who; do
    [[ "$who" == *"@users.noreply.github.com>" ]] || problem "$REPO: a commit by $who (use the no-reply address)"
  done < <(git -C "$REPO" log --all --format='%an <%ae>%n%cn <%ce>' | sort -u)
  git -C "$REPO" log --all --format='%B' > "$WORK/messages.txt"
  scan "$REPO (commit messages)" "$WORK/messages.txt"
  scanned+=("$REPO commits")
fi

[[ -f "$PRIVATE" ]] || echo "  note: no private list at $PRIVATE — add your workplace, clients, colleagues and projects there"
echo "  checked ${scanned[*]} against $(wc -l < "$DENY" | tr -d ' ') terms"
if (( HITS > 0 )); then
  echo "✗ $HITS problem(s) found (above) — fix them before publishing" >&2
  exit 1
fi
echo "✓ nothing identifying found"
