#!/usr/bin/env bash
#
# Bump Murmur's version. The source of truth is project.yml (XcodeGen);
# this updates it and regenerates the Xcode project so .pbxproj stays in sync.
#
# Usage:
#   scripts/bump-version.sh patch              # 0.2.0 -> 0.2.1
#   scripts/bump-version.sh minor              # 0.2.0 -> 0.3.0
#   scripts/bump-version.sh major              # 0.2.0 -> 1.0.0
#   scripts/bump-version.sh 1.2.3              # set the marketing version explicitly
#   scripts/bump-version.sh minor --release    # also commit, tag vX.Y.Z, and push
#
# The build number (CURRENT_PROJECT_VERSION) is always incremented by 1.
#
# Without --release the files are left modified for you to review/commit.
# With --release the script commits project.yml + the Xcode project, creates an
# annotated tag vX.Y.Z, and pushes the current branch and the tag to origin.
set -euo pipefail

cd "$(dirname "$0")/.."
SPEC="project.yml"

bump=""
release=0
for arg in "$@"; do
  case "$arg" in
    --release) release=1 ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      echo "error: unknown flag '$arg'" >&2
      exit 1 ;;
    *)
      if [[ -n "$bump" ]]; then
        echo "error: unexpected extra argument '$arg'" >&2
        exit 1
      fi
      bump="$arg" ;;
  esac
done

if [[ -z "$bump" ]]; then
  echo "usage: $0 {major|minor|patch|X.Y.Z} [--release]" >&2
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
    echo "usage: $0 {major|minor|patch|X.Y.Z} [--release]" >&2
    exit 1 ;;
esac
newbuild=$((build + 1))
tag="v$new"

# With --release, fail fast before touching anything if the tag already exists
# or the working tree has unrelated changes that would get swept into the commit.
if [[ "$release" -eq 1 ]]; then
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: --release requires running inside a git work tree" >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "error: tag $tag already exists" >&2
    exit 1
  fi
  dirty="$(git status --porcelain -- ':!project.yml' ':!Murmur.xcodeproj')"
  if [[ -n "$dirty" ]]; then
    echo "error: working tree has changes outside project.yml/Murmur.xcodeproj;" >&2
    echo "       commit or stash them before running with --release:" >&2
    echo "$dirty" >&2
    exit 1
  fi
fi

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

if [[ "$release" -eq 1 ]]; then
  echo
  git add project.yml Murmur.xcodeproj
  git commit -q -m "Bump version to $tag"
  git tag -a "$tag" -m "$tag"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  git push -q origin "$branch"
  git push -q origin "$tag"
  echo "Committed, tagged $tag, and pushed $branch + $tag to origin."
else
  echo
  echo "Next steps:"
  echo "  git commit -am \"Bump version to $tag\""
  echo "  git tag $tag"
  echo "  git push origin HEAD --tags"
  echo "  (or re-run with --release to do all three automatically)"
fi
