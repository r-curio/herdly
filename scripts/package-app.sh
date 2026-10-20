#!/bin/sh
# Package output/Herdly.app into a distributable zip with a checksum and a build manifest.
#
#   sh scripts/package-app.sh                       # ad-hoc signed, labelled unsigned-dev
#   HERDLY_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" sh scripts/package-app.sh
#   HERDLY_SIGNING_IDENTITY=... HERDLY_NOTARY_PROFILE=herdly-notary sh scripts/package-app.sh
#
# The signing identity and notarytool keychain profile come from the maintainer's environment.
# Without them the artifact is an ad-hoc signed development build and is named as such; the
# script never labels a build as signed or notarized unless that step actually succeeded.
set -eu
cd "$(dirname "$0")/.."

HERDLY_VERSION="${HERDLY_VERSION:-0.1.0}"
HERDLY_BUILD="${HERDLY_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
export HERDLY_VERSION HERDLY_BUILD
identity="${HERDLY_SIGNING_IDENTITY:-}"
notary_profile="${HERDLY_NOTARY_PROFILE:-}"

commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then dirty=true; else dirty=false; fi

app="$PWD/output/Herdly.app"
dist="$PWD/output/dist"
entitlements="$PWD/scripts/Herdly.entitlements"

fail() { printf 'package-app: %s\n' "$*" >&2; exit 1; }

# 1. Build the bundle exactly as the development script does.
sh scripts/build-app.sh

# 2. Verify the bundle layout before signing anything.
plutil -lint "$app/Contents/Info.plist" >/dev/null || fail "Info.plist is not a valid property list"
for f in Contents/MacOS/Herdly Contents/Helpers/HerdlyHook; do
    [ -x "$app/$f" ] || fail "missing executable $f"
done
[ -f "$app/Contents/Resources/AppleEvents.js" ] || fail "missing Contents/Resources/AppleEvents.js"
[ -f "$app/Contents/Resources/Ghostty.js" ] || fail "missing Contents/Resources/Ghostty.js"
[ -f "$app/Contents/Resources/ITerm2.js" ] || fail "missing Contents/Resources/ITerm2.js"
[ -f "$app/Contents/Resources/TerminalApp.js" ] || fail "missing Contents/Resources/TerminalApp.js"
for font in JetBrainsMono-Regular.ttf JetBrainsMono-SemiBold.ttf OFL.txt; do
    [ -f "$app/Contents/Resources/Herdly_HerdlyApp.bundle/Fonts/$font" ] || fail "missing question font resource $font"
done
"$app/Contents/Helpers/HerdlyHook" --self-test || fail "HerdlyHook --self-test failed"

# 3. Sign. The helper is signed first so the app's nested-code seal covers it.
if [ -n "$identity" ]; then
    security find-identity -v -p codesigning | grep -Fq "$identity" || fail "signing identity not found in the keychain: $identity"
    codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/Helpers/HerdlyHook"
    codesign --force --timestamp --options runtime --entitlements "$entitlements" --sign "$identity" "$app"
    # Only a Developer ID identity produces a build other Macs can open; anything else is a
    # development signature and is labelled as such so nobody ships it by mistake.
    case "$identity" in
        "Developer ID Application"*) label=signed; signing="developer-id" ;;
        *) label=dev-signed; signing="development-identity" ;;
    esac
else
    codesign --force --sign - "$app/Contents/Helpers/HerdlyHook"
    codesign --force --sign - "$app"
    label=unsigned-dev
    signing="ad-hoc"
fi
codesign --verify --deep --strict --verbose=2 "$app" || fail "codesign verification failed"

# 4. Notarize only when the maintainer supplied both an identity and a notarytool profile.
notarized=false
if [ -n "$notary_profile" ]; then
    [ -n "$identity" ] || fail "HERDLY_NOTARY_PROFILE requires HERDLY_SIGNING_IDENTITY"
    case "$identity" in
        "Developer ID Application"*) ;;
        *) fail "notarization needs a Developer ID Application identity; got: $identity" ;;
    esac
    mkdir -p "$dist"
    submission="$dist/Herdly-notary-submission.zip"
    rm -f "$submission"
    ditto -c -k --keepParent "$app" "$submission"
    xcrun notarytool submit "$submission" --keychain-profile "$notary_profile" --wait || fail "notarization was not accepted"
    xcrun stapler staple "$app" || fail "stapling failed"
    rm -f "$submission"
    notarized=true
    label=notarized
fi

# 5. Gatekeeper assessment is recorded, not required: an ad-hoc build is expected to be rejected.
if spctl --assess --type execute --verbose=2 "$app" >/dev/null 2>&1; then gatekeeper=accepted; else gatekeeper=rejected; fi

# 6. Zip, checksum, manifest.
mkdir -p "$dist"
name="Herdly-${HERDLY_VERSION}+${HERDLY_BUILD}-${label}"
zip="$dist/$name.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
(cd "$dist" && shasum -a 256 "$name.zip" > "$name.zip.sha256")
checksum=$(cut -d' ' -f1 "$zip.sha256")
app_sha=$(shasum -a 256 "$app/Contents/MacOS/Herdly" | cut -d' ' -f1)
helper_sha=$(shasum -a 256 "$app/Contents/Helpers/HerdlyHook" | cut -d' ' -f1)
swift_version=$(swift --version 2>&1 | head -n 1)
macos_version=$(sw_vers -productVersion)
xcode_version=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || echo unknown)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$dist/$name.manifest.json" <<JSON
{
  "artifact": "$name.zip",
  "sha256": "$checksum",
  "version": "$HERDLY_VERSION",
  "build": "$HERDLY_BUILD",
  "commit": "$commit",
  "dirty_worktree": $dirty,
  "built_at": "$built_at",
  "signing": "$signing",
  "signing_identity": "$(printf '%s' "$identity" | sed 's/"/\\"/g')",
  "notarized": $notarized,
  "gatekeeper_assessment": "$gatekeeper",
  "bundle_identifier": "dev.rcurio.herdly.prototype",
  "minimum_macos": "14.0",
  "host_macos": "$macos_version",
  "xcode": "$xcode_version",
  "swift": "$(printf '%s' "$swift_version" | sed 's/"/\\"/g')",
  "executables": {
    "Contents/MacOS/Herdly": "$app_sha",
    "Contents/Helpers/HerdlyHook": "$helper_sha"
  },
  "helper_self_test": "passed"
}
JSON

printf '\nPackaged %s\n' "$zip"
printf 'SHA-256  %s\n' "$checksum"
printf 'Signing  %s (%s); notarized: %s; Gatekeeper: %s\n' "$signing" "$label" "$notarized" "$gatekeeper"
printf 'Manifest %s\n' "$dist/$name.manifest.json"
