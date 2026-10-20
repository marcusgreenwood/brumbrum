#!/bin/sh
# Regenerates docs/icon.svg and rasterises it (via headless Chrome) to the
# opaque 1024×1024 PNG the asset catalog uses.
set -e
cd "$(dirname "$0")/.."
python3 Tools/make_icon.py
TMP="$(mktemp -d)"
printf '<html><body style="margin:0;background:#000">%s</body></html>' "$(cat docs/icon.svg)" > "$TMP/icon.html"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=1 --window-size=1024,1024 --screenshot="$TMP/icon.png" "file://$TMP/icon.html" >/dev/null 2>&1
cp "$TMP/icon.png" Brumbrum/Assets.xcassets/AppIcon.appiconset/AppIcon.png
rm -rf "$TMP"
echo "wrote Brumbrum/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
