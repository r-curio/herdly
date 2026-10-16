#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Marketing version and build number; scripts/package-app.sh derives the build number from git.
STEER_VERSION="${STEER_VERSION:-0.1.0}"
STEER_BUILD="${STEER_BUILD:-1}"
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/output/Steer.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Helpers"
cp Sources/SteerApp/Resources/AppleEvents.js Sources/SteerApp/Resources/Ghostty.js Sources/SteerApp/Resources/ITerm2.js Sources/SteerApp/Resources/TerminalApp.js "$app_dir/Contents/Resources/"
cp -R "$bin_dir/Steer_SteerApp.bundle" "$app_dir/Contents/Resources/"
cp "$bin_dir/Steer" "$app_dir/Contents/MacOS/Steer"
cp "$bin_dir/SteerHook" "$app_dir/Contents/Helpers/SteerHook"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rcurio.steer.prototype</string>
<key>CFBundleName</key><string>Steer</string>
<key>CFBundleExecutable</key><string>Steer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${STEER_VERSION}</string>
<key>CFBundleVersion</key><string>${STEER_BUILD}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>Steer selects the terminal tab for your Codex or Claude session, and types replies you send from the notch, in the terminals you turn on.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
