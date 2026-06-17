#!/usr/bin/env bash
#
# Build, sign (Developer ID), notarize, staple, DMG, and Sparkle-appcast Murmur
# for direct distribution. Murmur can't ship on the Mac App Store — it is
# intentionally NOT sandboxed (it needs Accessibility + synthetic key events) —
# so Developer ID + notarization + Sparkle is the production path.
#
# Output (in dist/):
#   Murmur-<version>.dmg   signed, notarized, stapled — the download
#   appcast.xml            EdDSA-signed Sparkle feed pointing at that DMG
#
# Prerequisites (one-time):
#   1. "Developer ID Application" certificate in your login keychain.
#        security find-identity -v -p codesigning | grep "Developer ID"
#   2. Notarization credentials, via ONE of:
#        a) App Store Connect API key (preferred):
#             ASC_ISSUER_ID, ASC_KEY_ID, ASC_KEY_PATH (the AuthKey_*.p8)
#        b) A saved notarytool keychain profile:  NOTARY_PROFILE
#        c) Apple ID + app-specific password:     APPLE_ID, APPLE_APP_PASSWORD
#      The script auto-sources ./notary.env (gitignored) if present, so you can
#      keep these out of your shell. If ASC_KEY_PATH is unset but a single
#      AuthKey_*.p8 sits in the repo root, it's used and ASC_KEY_ID inferred.
#   3. Sparkle's EdDSA signing key in your keychain (`generate_keys`, once).
#
# Usage:
#   scripts/release.sh                 # build + notarize + dmg + appcast -> dist/
#   scripts/release.sh --no-notarize   # build & sign only (smoke test, no appcast)
#   scripts/release.sh --publish       # also create the GitHub release + upload
#
set -euo pipefail

cd "$(dirname "$0")/.."

REPO_SLUG="marcelfernandes1/murmur"
SCHEME="Murmur"
PROJECT="Murmur.xcodeproj"
TEAM_ID="W2F7R5V23Q"                      # paid Developer Program team (Developer ID)
DEV_ID_CERT="Developer ID Application"    # matched by name in the keychain

notarize=1
publish=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) notarize=0 ;;
    --publish) publish=1 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown arg '$arg'" >&2; exit 1 ;;
  esac
done

# Convenience: keep notarization creds in a gitignored file.
[[ -f notary.env ]] && { echo "Sourcing notary.env"; source notary.env; }

# Default the API key to the one in the repo root if not otherwise configured.
if [[ -z "${ASC_KEY_PATH:-}" && -z "${NOTARY_PROFILE:-}" && -z "${APPLE_ID:-}" ]]; then
  p8=$(ls AuthKey_*.p8 2>/dev/null | head -1 || true)
  if [[ -n "$p8" ]]; then
    ASC_KEY_PATH="$PWD/$p8"
    : "${ASC_KEY_ID:=$(basename "$p8" .p8 | sed 's/^AuthKey_//')}"
    echo "Using API key $p8 (key id $ASC_KEY_ID)"
  fi
fi

# --- Preflight -------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -q "$DEV_ID_CERT"; then
  echo "error: no '$DEV_ID_CERT' certificate in your keychain." >&2
  exit 1
fi
command -v create-dmg >/dev/null || { echo "error: create-dmg not found (brew install create-dmg)" >&2; exit 1; }
command -v xcodegen   >/dev/null && xcodegen generate >/dev/null

VERSION="$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
TAG="v$VERSION"
echo "Releasing Murmur $VERSION (build $BUILD)"

BUILD_DIR="$PWD/build"
DIST_DIR="$PWD/dist"
ARCHIVE="$BUILD_DIR/Murmur.xcarchive"
APP="$BUILD_DIR/export/Murmur.app"
DMG="$DIST_DIR/Murmur-$VERSION.dmg"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR" "$DIST_DIR"

# --- Archive (Release, Developer ID) --------------------------------------
echo "==> Archiving…"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEV_ID_CERT" \
  DEVELOPMENT_TEAM="$TEAM_ID" PROVISIONING_PROFILE_SPECIFIER="" \
  -quiet

# --- Export ----------------------------------------------------------------
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
echo "==> Exporting signed .app…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR/export" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet
[[ -d "$APP" ]] || { echo "error: export produced no Murmur.app" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

# notarytool credential args, shared by the app and DMG submissions.
notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect Issuer ID)}"
  : "${ASC_KEY_ID:?set ASC_KEY_ID}"
  notary_args=(--issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$ASC_KEY_PATH")
elif [[ -n "${APPLE_ID:-}" ]]; then
  : "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}"
  notary_args=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
fi

if [[ "$notarize" -eq 0 ]]; then
  echo "Built & signed (not notarized). Skipping notarization, DMG, and appcast."
  exit 0
fi
[[ ${#notary_args[@]} -gt 0 ]] || { echo "error: no notarization credentials (see header)" >&2; exit 1; }

# --- Notarize + staple the app --------------------------------------------
echo "==> Notarizing app…"
APPZIP="$BUILD_DIR/Murmur-app.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$APPZIP"
xcrun notarytool submit "$APPZIP" "${notary_args[@]}" --wait
xcrun stapler staple "$APP"

# --- DMG -------------------------------------------------------------------
echo "==> Building DMG…"
ASSETS="$BUILD_DIR/dmg-assets"; mkdir -p "$ASSETS"
cp "$APP/Contents/Resources/AppIcon.icns" "$ASSETS/Murmur.icns" 2>/dev/null || true
BG_ARGS=(); [[ -f scripts/dmg-background.png ]] && BG_ARGS=(--background scripts/dmg-background.png)
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; rm -f "$DMG"
create-dmg \
  --volname "Murmur $VERSION" \
  --volicon "$ASSETS/Murmur.icns" \
  "${BG_ARGS[@]}" \
  --window-pos 200 120 --window-size 600 400 --icon-size 128 \
  --icon "Murmur.app" 150 200 --app-drop-link 450 200 \
  --hide-extension "Murmur.app" --no-internet-enable \
  "$DMG" "$STAGE" || [[ -f "$DMG" ]]
rm -rf "$STAGE"

echo "==> Notarizing DMG…"
xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait
xcrun stapler staple "$DMG"

# Publish a second copy under a stable, un-versioned name so the website can link
# to the newest build via releases/latest/download/Murmur.dmg and never go stale.
# It's a byte-copy of the notarized + stapled DMG (the ticket is embedded, so the
# copy is just as valid). Sparkle still updates via the versioned name in the
# appcast — keep this OUT of $APPCAST_SRC so generate_appcast ignores it.
STABLE_DMG="$DIST_DIR/Murmur.dmg"
cp "$DMG" "$STABLE_DMG"

# --- Sparkle appcast -------------------------------------------------------
# generate_appcast signs the DMG with the EdDSA key in the keychain and emits
# appcast.xml whose enclosure points at this version's GitHub release asset.
# It applies ONE url-prefix to every archive it finds and merges into any
# existing appcast — so feed it only THIS version's DMG, in a clean dir, with no
# stale appcast.xml. SUFeedURL resolves to releases/latest, so each release
# advertising just itself is exactly what we want.
echo "==> Generating Sparkle appcast…"
GA=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*artifacts/sparkle/Sparkle/bin/generate_appcast" 2>/dev/null | head -1)
[[ -x "$GA" ]] || { echo "error: generate_appcast not found — build once to resolve Sparkle" >&2; exit 1; }
APPCAST_SRC="$BUILD_DIR/appcast-src"; rm -rf "$APPCAST_SRC"; mkdir -p "$APPCAST_SRC"
cp "$DMG" "$APPCAST_SRC/"
rm -f "$DIST_DIR/appcast.xml"
"$GA" --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/$TAG/" -o "$DIST_DIR/appcast.xml" "$APPCAST_SRC"

echo
echo "Done:"
echo "  $DMG"
echo "  $STABLE_DMG  (stable alias for releases/latest/download/Murmur.dmg)"
echo "  $DIST_DIR/appcast.xml"
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/  /' || true

# --- Publish ---------------------------------------------------------------
if [[ "$publish" -eq 1 ]]; then
  command -v gh >/dev/null || { echo "error: gh CLI required for --publish" >&2; exit 1; }
  echo "==> Publishing GitHub release $TAG…"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$STABLE_DMG" "$DIST_DIR/appcast.xml" --clobber
  else
    gh release create "$TAG" "$DMG" "$STABLE_DMG" "$DIST_DIR/appcast.xml" \
      --target main --title "Murmur $VERSION" --generate-notes
  fi
  echo "Released: https://github.com/$REPO_SLUG/releases/tag/$TAG"
fi
