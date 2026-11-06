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
# Its names are only for debugging, and they're over half the file.
strip -x $APP/Contents/MacOS/Headroom
cp Resources/Info.plist $APP/Contents/Info.plist
# One higher with every build, so About Headroom can tell you which one is running.
BUILD=$(( $(cat .build-number 2>/dev/null || echo 0) + 1 ))
echo $BUILD > .build-number
plutil -replace CFBundleVersion -string "$BUILD" $APP/Contents/Info.plist
cp Resources/Assets.car Resources/AppIcon.icns Resources/logo.png $APP/Contents/Resources/
cp Sources/Headroom/Render/Shaders.metal $APP/Contents/Resources/Shaders.metal
# The Headroom certificate signs every version the same way, so macOS keeps its permissions from one to the next and the
# updater can tell a real update. It's made for this, so nobody needs to trust it. Without it, a development certificate.
ID=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '$2 == "Headroom" {print $2; exit}')
[[ -z "$ID" ]] && ID=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
# A locked keychain can refuse the real identity. The app still runs ad-hoc, but will ask for access again.
codesign --force --sign "${ID:--}" $APP 2>/dev/null || { echo "couldn't sign with \"$ID\": using an ad-hoc signature"; codesign --force --sign - $APP; }
# The Dock and Finder go by the app's date, so without this they keep showing an older icon.
touch $APP
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $APP || true
echo "built $APP"
