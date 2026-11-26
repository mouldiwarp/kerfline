#!/bin/zsh
# Builds the app from this checkout and installs it, so Spotlight finds it. Run it on each Mac (it
# compiles for the local CPU); a build from git runs it again to update itself.
#
#   scripts/build-app.sh                 install in ~/Applications
#   scripts/build-app.sh /Applications   install somewhere else
#
# Release builds (scripts/release.sh sets these): SG_RELEASE=1 makes a universal "SwarfGRBL" that
# updates from GitHub Releases with Sparkle, SG_VERSION=2.1 its version.
#
# Signing: with a "Developer ID Application" certificate in the keychain (or SG_SIGN_IDENTITY
# naming one) the app is signed with it (hardened runtime, timestamp), so macOS keeps its Documents,
# Local Network and USB permissions across updates. Without one it's signed ad hoc, and macOS may
# ask again after each update.
#
# Needs Xcode (or its Command Line Tools) for Swift 6.2; a universal build needs Xcode. It never
# adds a login item: open the app yourself. The new copy is only installed if the build succeeds,
# so a failed update leaves the old one.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
RELEASE="${SG_RELEASE:-0}"
DEST="${1:-$HOME/Applications}"

if [[ "$RELEASE" == 1 ]]; then
  NAME="SwarfGRBL"
  SHOWN="$NAME"
  BUNDLE_ID="io.github.swarf-suite.swarfgrbl"
  ARCHS=(--arch arm64 --arch x86_64)
else
  # Builds from git are the same app as a release (name, bundle id, settings), updated from the
  # checkout instead of GitHub Releases.
  NAME="${SG_APP_NAME:-SwarfGRBL}"
  # What the menu bar, Dock, app switcher and Finder show, if it isn't the file name.
  SHOWN="${SG_SHOWN_NAME:-$NAME}"
  BUNDLE_ID="${SG_BUNDLE_ID:-io.github.swarf-suite.swarfgrbl}"
  ARCHS=()
fi
# Sparkle checks every update against this key; the private half is the SPARKLE_ED_PRIVATE_KEY secret.
SPARKLE_PUBLIC_KEY="${SG_SPARKLE_PUBLIC_KEY:-}"
FEED_URL="${SG_FEED_URL:-https://github.com/Swarf-Suite/SwarfGRBL/releases/latest/download/appcast.xml}"

COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
COMMIT_TIME=$(git log -1 --format=%ct 2>/dev/null || echo "")
# The version: SG_VERSION, else the latest tag ("v2.0" → "2.0").
VERSION="${SG_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo 2.0)}"
VERSION="${VERSION#v}"

IDENTITY="${SG_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi

echo "Compiling $NAME $VERSION (release${ARCHS:+, universal})…"
swift build --package-path swift -c release --product SwarfGRBL "${ARCHS[@]}"
BIN="$(swift build --package-path swift -c release "${ARCHS[@]}" --show-bin-path)"

STAGE="$REPO/swift/.build/app"
APP="$STAGE/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/SwarfGRBL" "$APP/Contents/MacOS/SwarfGRBL"
cp swift/App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ "$SHOWN" != "$NAME" ]]; then
  # Dock and Finder show the file name unless the bundle has a localized display name, which they
  # use only while the file name still matches CFBundleDisplayName (so that stays the file name).
  mkdir -p "$APP/Contents/Resources/en.lproj"
  printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n' "$SHOWN" "$SHOWN" \
    > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
fi

# Sparkle (linked by every build). The app isn't sandboxed, so its XPC services aren't needed.
SPARKLE="$BIN/Sparkle.framework"
[[ -d "$SPARKLE" ]] || SPARKLE="$REPO/swift/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
if ! otool -l "$APP/Contents/MacOS/SwarfGRBL" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SwarfGRBL"
fi

if [[ "$RELEASE" == 1 ]]; then
  # No SGRepoPath: a release updates from GitHub Releases, not a checkout.
  EXTRA="  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>14400</integer>"
  [[ -n "$SPARKLE_PUBLIC_KEY" ]] || { echo "SG_SPARKLE_PUBLIC_KEY is needed for a release build" >&2; exit 1; }
else
  EXTRA="  <key>SGRepoPath</key><string>$REPO</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$SHOWN</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>LSHasLocalizedDisplayName</key><$([[ "$SHOWN" != "$NAME" ]] && echo true || echo false)/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SwarfGRBL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>${SG_BUILD_NUMBER:-${COMMIT_TIME:-0}}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with or endorsed by FoxAlien.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>$SHOWN links the design Mac and the machine Mac, and receives files from SwarfPath and Fretboard.</string>
  <key>NSBonjourServices</key><array><string>_swarfgrbl._tcp</string><string>_swarfgrbl-try._tcp</string></array>
  <key>SGCommit</key><string>$COMMIT</string>
  <key>SGCommitTime</key><string>$COMMIT_TIME</string>
$EXTRA
</dict>
</plist>
PLIST

# Sign inside out: Sparkle's helpers, Sparkle, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with $IDENTITY"
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
  echo "No Developer ID certificate: signing ad hoc"
  SIGN=(codesign --force --sign -)
fi
sign() { local out; out=$("${SIGN[@]}" "$1" 2>&1) || { echo "$out" >&2; return 1; } }
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --strict --deep "$APP"

# Swap the new copy in. A running copy keeps running (its files stay open) until it relaunches.
mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app.new"
ditto "$APP" "$DEST/$NAME.app.new"
rm -rf "$DEST/$NAME.app"
mv "$DEST/$NAME.app.new" "$DEST/$NAME.app"
# The app's old names. Their copy goes in the Trash, and the old name becomes a link to this one, so
# a copy that's still running relaunches into SwarfGRBL after updating itself (the new app removes
# the link when it starts).
if [[ "$RELEASE" != 1 && "$NAME" == SwarfGRBL ]]; then
  for OLD in "GCode Controller 2.0" "KerfLine"; do
    if [[ -d "$DEST/$OLD.app" && ! -L "$DEST/$OLD.app" ]]; then
      mkdir -p "$HOME/.Trash"
      mv "$DEST/$OLD.app" "$HOME/.Trash/$OLD $(date +%Y%m%d-%H%M%S).app"
      ln -s "$NAME.app" "$DEST/$OLD.app"
      echo "Moved $OLD.app to the Trash (SwarfGRBL replaces it)"
    fi
  done
fi
if [[ "$RELEASE" == 1 ]]; then
  echo "Built $DEST/$NAME.app ($VERSION, ${COMMIT:0:7})"
else
  mdimport "$DEST/$NAME.app" 2>/dev/null || true
  echo "Installed $DEST/$NAME.app (${COMMIT:0:7}). Open it from Spotlight: ⌘Space, then type \"SwarfGRBL\"."
fi
