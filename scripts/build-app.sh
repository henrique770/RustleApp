#!/usr/bin/env bash
# Build the Swift client and wrap it in RustleApp.app so macOS can grant it
# Microphone, Accessibility and Input Monitoring permissions.
# Signs with "RustleApp Local Signing" (scripts/create-signing-cert.sh) when present, so the
# permissions survive rebuilds; falls back to an ad-hoc signature otherwise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/client-macos"
APP="$ROOT/build/RustleApp.app"

swift build -c release --package-path "$CLIENT"
BIN="$(swift build -c release --package-path "$CLIENT" --show-bin-path)/RustleApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RustleApp"
# Figtree + EB Garamond (SIL OFL), registered through ATSApplicationFontsPath.
cp -R "$CLIENT/Resources/Fonts" "$APP/Contents/Resources/Fonts"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.rustleapp.client</string>
  <key>CFBundleName</key><string>RustleApp</string>
  <key>CFBundleDisplayName</key><string>RustleApp</string>
  <key>CFBundleExecutable</key><string>RustleApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSMicrophoneUsageDescription</key><string>RustleApp records your voice while you hold the dictation key.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"RustleApp Local Signing"/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier dev.rustleapp.client "$APP"
  echo "Signed with RustleApp Local Signing ($IDENTITY)"
else
  # Ad-hoc: macOS treats every rebuild as a new app, so permissions must be granted again.
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (run scripts/create-signing-cert.sh for stable permissions)"
fi
echo "Built $APP"
