#!/bin/zsh
# Compiles the app icon, an Icon Composer document, into what the app carries. Needs Xcode.
set -e
HERE=${0:A:h}
PLIST=$(mktemp)
LOG=$(mktemp)
# actool reports its errors among the rest of what it prints, so that's kept and shown if it fails.
if ! xcrun actool "$HERE/AppIcon.icon" --compile "$HERE" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$PLIST" > "$LOG" 2>&1; then
  cat "$LOG"
  rm -f "$PLIST" "$LOG"
  echo "couldn't make the icon"
  exit 1
fi
rm -f "$PLIST" "$LOG"
echo "made Resources/Assets.car and Resources/AppIcon.icns"
