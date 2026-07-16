#!/bin/zsh
# Build DeskPulse.app - clipboard history, text snippets, file converter.
set -e
cd "$(dirname "$0")"

APP="DeskPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# app icon (regenerate with: swift scripts/make_icon.swift && iconutil -c icns AppIcon.iconset)
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DeskPulse</string>
    <key>CFBundleIdentifier</key><string>local.deskpulse.app</string>
    <key>CFBundleName</key><string>DeskPulse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

swiftc -O -parse-as-library DeskPulseApp/*.swift -o "$APP/Contents/MacOS/DeskPulse"
codesign --force --sign - "$APP"
echo "built: $APP"
echo "run:   open '$PWD/$APP'"
