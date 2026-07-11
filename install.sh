#!/usr/bin/env bash
# Compiles the engine and gets everything ready. It's idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "·· compiling WallpaperEngine…"
/usr/bin/swiftc -O -whole-module-optimization \
  -framework Cocoa -framework AVFoundation -framework AVKit -framework IOKit \
  -o "$ROOT/app/WallpaperEngine" "$ROOT/app/WallpaperEngine.swift"

echo "·· compiling WallpaperMenu (HUD)…"
/usr/bin/swiftc -O -whole-module-optimization \
  -framework Cocoa -framework AVFoundation -framework QuartzCore -framework ServiceManagement \
  -o "$ROOT/app/WallpaperMenu" "$ROOT/app/MenuApp.swift"

# ── Assemble the .app (created from scratch if it doesn't exist) ───────
# Remove the pre-rename bundle so we don't leave a stale "Wallpaper Sync.app".
rm -rf "$ROOT/Wallpaper Sync.app"
APP_BUNDLE="$ROOT/MotionWall.app"
echo "·· assembling ${APP_BUNDLE}…"
mkdir -p "$APP_BUNDLE/Contents/MacOS" \
         "$APP_BUNDLE/Contents/Resources/app" \
         "$APP_BUNDLE/Contents/Resources/bin"
cp -f "$ROOT/app/WallpaperMenu"            "$APP_BUNDLE/Contents/MacOS/WallpaperMenu"
cp -f "$ROOT/app/WallpaperEngine"          "$APP_BUNDLE/Contents/Resources/app/WallpaperEngine"
cp -f "$ROOT/app/Info.plist"               "$APP_BUNDLE/Contents/Info.plist"
[ -f "$ROOT/app/AppIcon.icns" ] && cp -f "$ROOT/app/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -f "$ROOT/bin/wallpaper"                "$APP_BUNDLE/Contents/Resources/bin/wallpaper"
cp -f "$ROOT/bin/_set_lockscreen_video.py" "$APP_BUNDLE/Contents/Resources/bin/_set_lockscreen_video.py"
[ -f "$ROOT/bin/_mirror_lockscreen.py" ] && cp -f "$ROOT/bin/_mirror_lockscreen.py" "$APP_BUNDLE/Contents/Resources/bin/_mirror_lockscreen.py"
chmod +x "$APP_BUNDLE/Contents/MacOS/WallpaperMenu" \
         "$APP_BUNDLE/Contents/Resources/app/WallpaperEngine" \
         "$APP_BUNDLE/Contents/Resources/bin/wallpaper"
# Ad-hoc signing: needed so macOS lets the app run locally.
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Deploy to /Applications so it shows up in Launchpad/Spotlight and updates in
# place. (It's a menu-bar LSUIElement app, so it never gets a Dock icon.)
# Falls back to ~/Applications if /Applications isn't writable.
if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
if pgrep -x WallpaperMenu >/dev/null; then pkill -x WallpaperMenu 2>/dev/null || true; sleep 0.5; fi
rm -rf "$DEST/MotionWall.app"
cp -R "$APP_BUNDLE" "$DEST/MotionWall.app"
codesign --force --deep --sign - "$DEST/MotionWall.app" 2>/dev/null || true
# Drop the repo-local bundle so only the /Applications copy exists — otherwise
# Spotlight/Launchpad index both and you get two identical app icons.
rm -rf "$APP_BUNDLE"
echo "·· installed to $DEST/MotionWall.app"

chmod +x "$ROOT/bin/wallpaper"

if [ ! -f "$ROOT/config.json" ]; then
  cat > "$ROOT/config.json" <<JSON
{
  "video": "",
  "fill": "fill",
  "pauseOnBattery": false,
  "pauseOnLowPower": false
}
JSON
fi

echo ""
echo "done. To use it from any terminal, add this line to your shell:"
echo "  export PATH=\"$ROOT/bin:\$PATH\""
echo ""
echo "Quick commands:"
echo "  wallpaper set library/sample_4k.mp4   # set the 4K sample"
echo "  wallpaper enable                       # autostart at login"
echo "  wallpaper status"
