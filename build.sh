#!/bin/zsh
# Builds Flipdial.app with FFmpeg bundled inside.
#
#   ./build.sh             build into ./build
#   ./build.sh --install   also copy to ~/Applications
#   ./build.sh --release   also create dist/Flipdial-<version>.zip for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Flipdial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Flipdial "$APP/Contents/MacOS/Flipdial"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Sign with a real identity when one exists so the designated requirement stays the same across
# rebuilds; macOS then keeps the Accessibility permission instead of silently dropping it.
# Release zips are ad-hoc signed: a personal development certificate would show its owner's email
# to everyone who downloads the app, and only a paid Developer ID avoids Gatekeeper's warning anyway.
if [[ " $* " == *" --release "* ]]; then
  export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
else
  export SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/"/{print $2; exit}')}"
  [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY=-
fi

scripts/bundle-tools.sh "$APP" ffmpeg cwebp
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Flipdial 2>/dev/null || true
      rm -rf ~/Applications/Flipdial.app
      mkdir -p ~/Applications
      cp -R "$APP" ~/Applications/
      echo "Installed to ~/Applications/Flipdial.app" ;;
    --release)
      VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
      mkdir -p dist
      rm -f "dist/Flipdial-$VERSION.zip"
      ditto -c -k --keepParent "$APP" "dist/Flipdial-$VERSION.zip"
      echo "Created dist/Flipdial-$VERSION.zip" ;;
  esac
done
