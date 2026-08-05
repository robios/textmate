#!/bin/bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
APP_NAME="TextMate"
# Machine-local overrides (untracked); can set CS_IDENTITY and NOTARY_PROFILE.
CONF="$(cd "$(dirname "$0")" && pwd)/package.conf"
[ -f "$CONF" ] && source "$CONF"
# With several Developer ID certs in the keychain the bare prefix is
# ambiguous and codesign refuses it — set the full string in package.conf.
IDENTITY="${CS_IDENTITY:-Developer ID Application}"
# One-time setup: xcrun notarytool store-credentials notarytool \
#   --apple-id <apple-id> --team-id <team-id>   (prompts for app-specific password)
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"

GIT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -z "$GIT_TAG" ]; then
  echo "ERROR: HEAD is not tagged. Run make package [patch|minor] to prepare a release tag."
  exit 1
fi
VERSION="${GIT_TAG#v}"

BUILD_DIR="build-release"
APP_PATH="$BUILD_DIR/Applications/TextMate/TextMate.app"

# ── Build ────────────────────────────────────────────────────────────
echo "==> Building release (v$VERSION)"
make release CS_IDENTITY="$IDENTITY"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: $APP_PATH not found after build"
  exit 1
fi

# ── Verify signature ────────────────────────────────────────────────
echo "==> Verifying code signature"
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature OK"

# ── Notarize ─────────────────────────────────────────────────────────
echo "==> Creating zip for notarization"
NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-$VERSION-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization (this may take a few minutes)"
NOTARY_OUTPUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait 2>&1) || true
echo "$NOTARY_OUTPUT"

NOTARY_ID=$(echo "$NOTARY_OUTPUT" | grep "  id:" | head -1 | awk '{print $2}')

if ! echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo ""
  echo "Notarization failed. Fetching log..."
  if [ -n "$NOTARY_ID" ]; then
    xcrun notarytool log "$NOTARY_ID" \
      --keychain-profile "$NOTARY_PROFILE" 2>&1 || true
  fi
  exit 1
fi

rm -f "$NOTARIZE_ZIP"

# ── Staple ───────────────────────────────────────────────────────────
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

# ── Package as .tar.gz ───────────────────────────────────────────────
TGZ_PATH="$BUILD_DIR/$APP_NAME-$VERSION.tar.gz"
echo "==> Creating $TGZ_PATH"
tar -czf "$TGZ_PATH" -C "$(dirname "$APP_PATH")" "$APP_NAME.app"

TGZ_SHA=$(shasum -a 256 "$TGZ_PATH" | awk '{print $1}')

# ── GitHub Release ───────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found"
  echo "       $TGZ_PATH was created but the release was not published."
  exit 1
fi

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')
REMOTE="${UPSTREAM%%/*}"

echo "==> Pushing branch and tag"
git push "$REMOTE" HEAD
git push "$REMOTE" "$GIT_TAG"

echo "==> Creating GitHub release and uploading"
gh release create "$GIT_TAG" "$TGZ_PATH" \
  --title "$APP_NAME $VERSION" \
  --generate-notes

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo "Done! Signed & notarized: $TGZ_PATH"
echo "  Version: $VERSION"
echo "  SHA256:  $TGZ_SHA"
