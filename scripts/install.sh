#!/bin/zsh
# Builds Meadow (Release) and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Meadow.xcodeproj -scheme Meadow -configuration Release \
  -derivedDataPath build/DerivedData build -quiet
APP=build/DerivedData/Build/Products/Release/Meadow.app
pkill -x Meadow 2>/dev/null || true
rm -rf /Applications/Meadow.app
ditto "$APP" /Applications/Meadow.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Forget the Debug build so Finder and Quick Look use the installed copy.
$LSREG -u "$PWD/build/DerivedData/Build/Products/Debug/Meadow.app" 2>/dev/null || true
$LSREG -f /Applications/Meadow.app
qlmanage -r >/dev/null 2>&1 || true
echo "Installed /Applications/Meadow.app"
