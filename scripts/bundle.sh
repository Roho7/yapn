#!/bin/sh
# Release-builds the Yapn target into build/Yapn.app and signs it. Signs with the identity
# from scripts/make-signing-identity.sh when it exists, so permission grants survive rebuilds.
# Otherwise signs ad-hoc, and Microphone and Accessibility must be granted again after every build.
set -eu
cd "$(dirname "$0")/.."

BUNDLE_ID=dev.roho.yapn
VERSION=0.2.0
APP=build/Yapn.app
KEYCHAIN="${YAPN_KEYCHAIN:-$HOME/Library/Keychains/yapn-signing.keychain-db}"
PASSWORD_FILE="${YAPN_KEYCHAIN_PASSWORD_FILE:-$HOME/Library/Application Support/Yapn/signing-keychain-password}"

# Until the Xcode license is accepted, only the Command Line Tools toolchain runs.
if ! swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --product Yapn
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Yapn" "$APP/Contents/MacOS/Yapn"

mkdir -p "$APP/Contents/Resources"
for menu_icon in Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/MenuIcon.pdf; do
  [ -f "$menu_icon" ] && cp "$menu_icon" "$APP/Contents/Resources/"
done

ICON_SOURCE=Resources/AppIcon.png
ICON_PLIST=""
if [ -f "$ICON_SOURCE" ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET" "$APP/Contents/Resources"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Yapn</string>
  <key>CFBundleDisplayName</key><string>Yapn</string>
  <key>CFBundleExecutable</key><string>Yapn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_PLIST
  <key>NSMicrophoneUsageDescription</key><string>Yapn listens while you hold Right Option and turns your speech into text at the cursor.</string>
</dict>
</plist>
EOF

if [ -f "$KEYCHAIN" ] && [ -f "$PASSWORD_FILE" ]; then
  security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
  IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/Yapn Local Signing/ { print $2; exit }')
  # codesign only finds identities in keychains on the search list, so the identity keychain
  # joins it for the signing call and the original list is put back on any exit.
  ORIGINAL=$(security list-keychains -d user)
  trap 'eval "security list-keychains -d user -s $ORIGINAL"' EXIT
  eval "security list-keychains -d user -s $ORIGINAL \"\$KEYCHAIN\""
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "warning: signed ad-hoc. Run scripts/make-signing-identity.sh once so permission grants survive rebuilds." >&2
fi

codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n "s/^#* *designated => /designated requirement: /p"
echo "built $APP"
