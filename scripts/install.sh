#!/bin/zsh
# Builds Copa in Release mode and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

# ".noindex" keeps Spotlight/Launchpad from listing the temporary build as a second Copa.
BUILD_DIR="build/DerivedData.noindex"
BUILT_APP="$BUILD_DIR/Build/Products/Release/Copa.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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
