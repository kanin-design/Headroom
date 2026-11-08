#!/bin/zsh
# Makes the release disk image, build/Headroom-<version>-<stage>.dmg: a fresh build signed with the Headroom certificate,
# in the earlier release's disk image layout, with its background, icon places and volume icon. Beside it goes
# build/Headroom-<version>-<stage>.json, the release's version and build number, and both go on the release: as in Sparkle,
# a copy that updates itself compares build numbers, so a release put out again under the same version still reaches it.
# Every release has to be signed with that one certificate. A copy of Headroom only takes an update signed the way it is,
# so a release signed any other way would be turned down by every one of them.
set -e
cd "${0:A:h}"
security find-identity -p codesigning 2>/dev/null | grep -q '"Headroom"' || {
  echo "The certificate called Headroom isn't in the keychain. Every copy of Headroom would turn down a release signed without it."
  exit 1
}
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(/usr/libexec/PlistBuddy -c "Print HeadroomStage" Resources/Info.plist 2>/dev/null || true)
NAME="Headroom-$VERSION${STAGE:+-$STAGE}"
# The layout comes from the newest disk image made before this one, unless one is named.
TEMPLATE=${1:-$(ls -t build/Headroom-*.dmg 2>/dev/null | grep -v "/$NAME.dmg" | head -1)}
[[ -f "$TEMPLATE" ]] || { echo "No earlier disk image to take the layout from: name one, or put the last release's in build/"; exit 1; }

./build.sh
codesign --force --sign Headroom build/Headroom.app
codesign --verify --strict build/Headroom.app
codesign -d -r- build/Headroom.app 2>&1 | grep -q 'certificate leaf' || { echo "build/Headroom.app isn't signed with the certificate"; exit 1; }

WORK=$(mktemp -d)
hdiutil convert "$TEMPLATE" -format UDRW -o "$WORK/layout.dmg" -quiet
hdiutil resize -size 80m "$WORK/layout.dmg" 2>/dev/null
mkdir "$WORK/disk"
hdiutil attach -nobrowse -noautoopen -mountpoint "$WORK/disk" "$WORK/layout.dmg" -quiet
rm -rf "$WORK/disk/Headroom.app"
ditto build/Headroom.app "$WORK/disk/Headroom.app"
hdiutil detach "$WORK/disk" -quiet
hdiutil convert "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "build/$NAME.dmg" -quiet
rm -rf "$WORK"
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/Headroom.app/Contents/Info.plist)
[[ $BUILD == <-> ]] || { echo "The build number isn't a whole number: $BUILD"; exit 1; }
printf '{"version": "%s", "build": %s}\n' "$VERSION" "$BUILD" > "build/$NAME.json"
echo "made build/$NAME.dmg and build/$NAME.json, build $BUILD"
