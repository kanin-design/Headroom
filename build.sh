#!/bin/zsh
# Builds Headroom.app in ./build: compiles the Swift code, copies the shaders (macOS compiles them at launch), then
# signs the bundle.
# Signing with a stable identity keeps Full Disk Access across rebuilds. It falls back to an ad-hoc signature.
set -e
cd "${0:A:h}"
LOG=$(mktemp)
if ! swift build -c release > "$LOG" 2>&1; then
  grep -E 'error' "$LOG"
  rm -f "$LOG"
  echo "build failed"
  exit 1
fi
rm -f "$LOG"
APP=build/Headroom.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# A new file, not an overwrite: writing into a signed binary that is running makes macOS kill that copy.
rm -f $APP/Contents/MacOS/Headroom
cp .build/release/Headroom $APP/Contents/MacOS/Headroom
cp Resources/Info.plist $APP/Contents/Info.plist
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp Sources/Headroom/Render/Shaders.metal $APP/Contents/Resources/Shaders.metal
ID=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
# A locked keychain can refuse the real identity. The app still runs ad-hoc, but will ask for access again.
codesign --force --sign "${ID:--}" $APP 2>/dev/null || { echo "couldn't sign with \"$ID\": using an ad-hoc signature"; codesign --force --sign - $APP; }
# The Dock and Finder go by the app's date, so without this they keep showing an older icon.
touch $APP
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $APP || true
echo "built $APP"
