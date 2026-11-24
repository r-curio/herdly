#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Marketing version and build number; scripts/package-app.sh derives the build number from git.
HERDLY_VERSION="${HERDLY_VERSION:-0.1.0}"
HERDLY_BUILD="${HERDLY_BUILD:-1}"
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/output/Herdly.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Helpers"
cp Sources/HerdlyApp/Resources/AppleEvents.js Sources/HerdlyApp/Resources/Ghostty.js Sources/HerdlyApp/Resources/ITerm2.js Sources/HerdlyApp/Resources/TerminalApp.js "$app_dir/Contents/Resources/"
cp -R "$bin_dir/Herdly_HerdlyApp.bundle" "$app_dir/Contents/Resources/"
cp "$bin_dir/Herdly" "$app_dir/Contents/MacOS/Herdly"
cp "$bin_dir/HerdlyHook" "$app_dir/Contents/Helpers/HerdlyHook"
# The app icon is drawn from the same code as the menu bar mark; no icon binary is kept in the repository.
icon_tool_dir=$(mktemp -d)
trap 'rm -rf "$icon_tool_dir"' EXIT
swiftc -O -parse-as-library -o "$icon_tool_dir/make-app-icon" Sources/HerdlyApp/HerdlyMark.swift scripts/make-app-icon.swift
"$icon_tool_dir/make-app-icon" "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rcurio.herdly.prototype</string>
<key>CFBundleName</key><string>Herdly</string>
<key>CFBundleExecutable</key><string>Herdly</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${HERDLY_VERSION}</string>
<key>CFBundleVersion</key><string>${HERDLY_BUILD}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>Herdly selects the terminal tab for your Codex or Claude session, and types replies you send from the notch, in the terminals you turn on.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
