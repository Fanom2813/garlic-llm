#!/bin/sh
# Builds Garlic.app (menu bar app) with the tokenizers inside, signs it ad hoc, installs it to ~/Applications.
#   ./make_app.sh            tokenizers from ../models/tokenizers (downloaded by ../tools/fetch_tokenizers.sh)
set -e
cd "$(dirname "$0")"
MODELS=${MODELS:-../models/tokenizers}
[ -d "$MODELS" ] || ../tools/fetch_tokenizers.sh
swift build -c release --product Garlic
APP=build/Garlic.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/models"
cp .build/release/Garlic "$APP/Contents/MacOS/Garlic"
for m in "$MODELS"/*/; do
  n=$(basename "$m")
  [ -L "${m%/}" ] && continue          # (aliases such as maple-fast: the app strips "-fast" itself)
  [ -f "$m/tokenizer.json" ] || continue
  mkdir -p "$APP/Contents/Resources/models/$n"
  cp "$m"/tokenizer.json "$m"/tokenizer_config.json "$APP/Contents/Resources/models/$n/"
  [ -f "$m/chat_template.jinja" ] && cp "$m/chat_template.jinja" "$APP/Contents/Resources/models/$n/"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Garlic</string>
  <key>CFBundleDisplayName</key><string>Garlic</string>
  <key>CFBundleIdentifier</key><string>local.garlic.mac</string>
  <key>CFBundleExecutable</key><string>Garlic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Garlic Server for PS4: local inference for coding agents</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Garlic.app"
cp -R "$APP" "$HOME/Applications/Garlic.app"
echo "installed $HOME/Applications/Garlic.app"
du -sh "$HOME/Applications/Garlic.app"
