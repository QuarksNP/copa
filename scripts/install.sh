#!/bin/zsh
# Builds Copa in Release mode and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

# Build outside the project: folders synced with iCloud (like Desktop or Documents) add hidden
# file attributes that make code signing fail. ".noindex" keeps Launchpad from listing a second Copa.
BUILD_DIR="$HOME/Library/Caches/Copa/DerivedData.noindex"
BUILT_APP="$BUILD_DIR/Build/Products/Release/Copa.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Building a Mac app needs the full Xcode app; the Command Line Tools alone aren't enough.
# If Xcode is installed but not selected (xcode-select points at the Command Line Tools), use it anyway.
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(print -l /Applications/Xcode*.app(N) | sort | tail -1)
  if [[ -n "$XCODE_APP" ]]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    echo "› Using $XCODE_APP"
  else
    echo "✗ Copa needs Xcode to build (the Command Line Tools alone aren't enough)."
    echo "  1. Install Xcode (free) from the Mac App Store: https://apps.apple.com/app/xcode/id497799835"
    echo "  2. Open Xcode once and let it finish installing its components."
    echo "  3. Run ./scripts/install.sh again."
    exit 1
  fi
fi

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ Xcode isn't fully set up yet. Open Xcode once and accept the license, or run:"
  echo "  sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"
  exit 1
fi

# Strip those hidden attributes from the source files too (harmless if there are none).
xattr -cr Copa 2>/dev/null || true

# Always start fresh so leftovers from an earlier (failed) build can't get in the way.
rm -rf "$BUILD_DIR" build/DerivedData build/DerivedData.noindex

echo "› Building Copa…"
xcodebuild -project Copa.xcodeproj -scheme Copa -configuration Release \
  -derivedDataPath "$BUILD_DIR" build -quiet

echo "› Installing to /Applications…"
pkill -x Copa 2>/dev/null || true
rm -rf /Applications/Copa.app
cp -R "$BUILT_APP" /Applications/

# Remove the temporary build so only the copy in /Applications exists.
"$LSREGISTER" -u "$BUILT_APP" 2>/dev/null || true
rm -rf "$BUILD_DIR/Build/Products"
"$LSREGISTER" -f /Applications/Copa.app

echo "› Launching Copa"
open /Applications/Copa.app
echo "✓ Done. Hover the notch to open Copa."
