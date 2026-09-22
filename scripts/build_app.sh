#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="BoMD"
PROJECT_BUILD_DIR="$ROOT_DIR/build"
PROJECT_APP_DIR="$PROJECT_BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="${BOMD_SIGN_IDENTITY:--}"

# Local builds do not require the maintainer's developer certificate.
# A requested identity must exist; never silently fall back to ad-hoc signing.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq -- "$SIGN_IDENTITY"; then
    print -u2 "Signing identity unavailable: $SIGN_IDENTITY"
    print -u2 "Install the certificate and its private key, or omit BOMD_SIGN_IDENTITY for a local ad-hoc build."
    exit 1
  fi
fi

# Use a unique staging directory so separate checkouts cannot overwrite each other.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bomd-build.XXXXXX")"
trap '/bin/rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/BoMDApp/Info.plist" "$CONTENTS_DIR/Info.plist"
npm run build:web >/dev/null
for resource_name in \
  AppIcon-20260717.icns \
  AppIcon.icns \
  renderer-bundle.js \
  renderer.css \
  renderer.html; do
  cp "$ROOT_DIR/BoMDApp/Resources/$resource_name" "$RESOURCES_DIR/$resource_name"
done
mkdir -p "$RESOURCES_DIR/vendor/katex" "$RESOURCES_DIR/vendor/highlight"
cp "$ROOT_DIR/node_modules/katex/dist/katex.min.css" "$RESOURCES_DIR/vendor/katex/katex.min.css"
cp -R "$ROOT_DIR/node_modules/katex/dist/fonts" "$RESOURCES_DIR/vendor/katex/fonts"
cp "$ROOT_DIR/node_modules/highlight.js/styles/tokyo-night-dark.min.css" "$RESOURCES_DIR/vendor/highlight/tokyo-night-dark.min.css"
cp "$ROOT_DIR/node_modules/highlight.js/styles/github.min.css" "$RESOURCES_DIR/vendor/highlight/github.min.css"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"

xcrun swiftc \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -framework WebKit \
  "$ROOT_DIR"/BoMDApp/Sources/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

# Remove copy-time filesystem metadata from this newly assembled bundle.
xattr -cr "$APP_DIR" 2>/dev/null || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

if [[ -L "$PROJECT_BUILD_DIR" || -L "$PROJECT_APP_DIR" ]]; then
  print -u2 "Refusing to replace a symlink at the build output path."
  exit 1
fi
/bin/mkdir -p "$PROJECT_BUILD_DIR"
/bin/rm -rf "$PROJECT_APP_DIR"
/usr/bin/ditto "$APP_DIR" "$PROJECT_APP_DIR"
echo "$PROJECT_APP_DIR"
