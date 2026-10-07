#!/usr/bin/env bash
# Copies the public part of the last commit into a checkout of the public repo
# (daniel-wing/wingman-beta; default .build/public-repo), ready to check with
# scripts/check-public.sh --repo and commit there. The maintainer's notes
# (LEDGER.md, PROGRESS.md, CLAUDE.md) and this repo's README stay private;
# beta-site/ becomes the public README, release notes and issue forms.
#
#   scripts/export-public.sh [public-repo-checkout]
#
# A change someone contributes there comes back as a patch:
#   git -C .build/public-repo format-patch -1 --stdout | git am
# (beta-site files are at the top there: README.md, RELEASE_NOTES.md, .github/).
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-.build/public-repo}"
[[ -d "$DEST/.git" ]] || { echo "error: $DEST isn't a checkout of the public repo" >&2; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit your changes first — the export is the last commit" >&2
  exit 1
fi

TMP="$(mktemp -d -t wingman-export)"
trap 'rm -rf "$TMP"' EXIT
git archive HEAD | tar -x -C "$TMP"
rm -f "$TMP/LEDGER.md" "$TMP/PROGRESS.md" "$TMP/CLAUDE.md" "$TMP/README.md"
cp -R "$TMP/beta-site/." "$TMP/"
rm -rf "$TMP/beta-site"
rsync -a --delete --exclude .git "$TMP/" "$DEST/"
echo "==> exported $(git rev-parse --short HEAD) to $DEST"
git -C "$DEST" status --short | head -20
