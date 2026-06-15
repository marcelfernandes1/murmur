#!/usr/bin/env bash
#
# Bump Murmur's version. The source of truth is project.yml (XcodeGen);
# this updates it and regenerates the Xcode project so .pbxproj stays in sync.
#
# Usage:
#   scripts/bump-version.sh patch     # 0.2.0 -> 0.2.1
#   scripts/bump-version.sh minor     # 0.2.0 -> 0.3.0
#   scripts/bump-version.sh major     # 0.2.0 -> 1.0.0
#   scripts/bump-version.sh 1.2.3     # set the marketing version explicitly
#
# The build number (CURRENT_PROJECT_VERSION) is always incremented by 1.
#
# After running, review the diff, then commit + tag (see the printed next steps).
set -euo pipefail

cd "$(dirname "$0")/.."
SPEC="project.yml"

bump="${1:-}"
if [[ -z "$bump" ]]; then
  echo "usage: $0 {major|minor|patch|X.Y.Z}" >&2
  exit 1
fi

# Read current values from the spec. Match a quoted value after the key.
read_val() {
  grep -E "^[[:space:]]*$1:" "$SPEC" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}
cur="$(read_val MARKETING_VERSION)"
build="$(read_val CURRENT_PROJECT_VERSION)"

if [[ ! "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: could not parse MARKETING_VERSION ('$cur') from $SPEC" >&2
  exit 1
fi
IFS=. read -r major minor patch <<< "$cur"

case "$bump" in
  major) new="$((major + 1)).0.0" ;;
  minor) new="${major}.$((minor + 1)).0" ;;
  patch) new="${major}.${minor}.$((patch + 1))" ;;
  [0-9]*.[0-9]*.[0-9]*)
    if [[ ! "$bump" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: '$bump' is not a valid X.Y.Z version" >&2
      exit 1
    fi
    new="$bump" ;;
  *)
    echo "usage: $0 {major|minor|patch|X.Y.Z}" >&2
    exit 1 ;;
esac
newbuild=$((build + 1))

# Update the spec in place. [[:space:]] keeps this portable across BSD/GNU sed.
sed -i.bak -E \
  -e "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$new\"/" \
  -e "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 \"$newbuild\"/" \
  "$SPEC"
rm -f "$SPEC.bak"

# Regenerate the Xcode project so .pbxproj matches the spec.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
  echo "Regenerated Murmur.xcodeproj from $SPEC"
else
  echo "warning: xcodegen not found on PATH — run 'xcodegen generate' yourself" >&2
fi

echo "Version: $cur -> $new   (build $build -> $newbuild)"
echo
echo "Next steps:"
echo "  git commit -am \"Bump version to v$new\""
echo "  git tag v$new"
echo "  git push origin HEAD --tags"
