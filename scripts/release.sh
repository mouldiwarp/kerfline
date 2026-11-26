#!/bin/zsh
# Makes a release of SwarfGRBL in dist/: the app (universal), SwarfGRBL.zip (what Sparkle downloads),
# SwarfGRBL.dmg (what people download from the website) and appcast.xml (what Sparkle checks).
# .github/workflows/release.yml runs it when a tag vX.Y is pushed; it works on a Mac too.
#
#   scripts/release.sh 2.1
#
# Each step that needs a secret is skipped without it, and dist/release.env says what was done:
#   Developer ID signing   a "Developer ID Application" certificate in the keychain (build-app.sh)
#   notarization           NOTARY_KEY_PATH (an App Store Connect API key, .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   appcast                SPARKLE_ED_PRIVATE_KEY (from Sparkle's generate_keys -x)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
VERSION="${1:?usage: scripts/release.sh VERSION}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
DIST="$REPO/dist"
APP="$DIST/SwarfGRBL.app"
SPARKLE_BIN="$REPO/swift/.build/artifacts/sparkle/Sparkle/bin"
DOWNLOAD="https://github.com/Swarf-Suite/SwarfGRBL/releases/download/$TAG"
# The public half of the Sparkle key (not a secret): every update must be signed with its private half.
export SG_SPARKLE_PUBLIC_KEY="${SG_SPARKLE_PUBLIC_KEY:-$(cat scripts/sparkle-public-key.txt)}"

rm -rf "$DIST"
mkdir -p "$DIST"
SG_RELEASE=1 SG_VERSION="$VERSION" scripts/build-app.sh "$DIST"

SIGNED=0
# The signer is only listed at -dvv. Capture it first: grep -q under pipefail can fail on SIGPIPE.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F= '!f && /^Authority=Developer ID Application/ { print $2; f = 1 }')
[[ -n "$IDENTITY" ]] && SIGNED=1
NOTARIZED=0
notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
}
if [[ "$SIGNED" == 1 && -n "${NOTARY_KEY_PATH:-}" ]]; then
  echo "Notarizing the app…"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  notarize "$DIST/notarize.zip"
  rm "$DIST/notarize.zip"
  xcrun stapler staple "$APP"
  NOTARIZED=1
else
  echo "Not notarizing (needs a Developer ID signature and NOTARY_KEY_PATH)"
fi

# What Sparkle downloads: the (stapled) app, zipped.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/SwarfGRBL.zip"

# What people download: a disk image with the app and a link to Applications.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/SwarfGRBL.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "SwarfGRBL $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DIST/SwarfGRBL.dmg"
rm -rf "$STAGE"
if [[ "$SIGNED" == 1 ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DIST/SwarfGRBL.dmg"
  if [[ "$NOTARIZED" == 1 ]]; then
    echo "Notarizing the disk image…"
    notarize "$DIST/SwarfGRBL.dmg"
    xcrun stapler staple "$DIST/SwarfGRBL.dmg"
  fi
fi

APPCAST=0
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  SIG=$(print -rn -- "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$DIST/SwarfGRBL.zip")
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SwarfGRBL</title>
    <item>
      <title>SwarfGRBL $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/Swarf-Suite/SwarfGRBL/releases/tag/$TAG</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/Swarf-Suite/SwarfGRBL/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="${SG_DOWNLOAD_URL:-$DOWNLOAD}/SwarfGRBL.zip" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
  APPCAST=1
else
  echo "No appcast (needs SPARKLE_ED_PRIVATE_KEY)"
fi

printf 'VERSION=%s\nSIGNED=%s\nNOTARIZED=%s\nAPPCAST=%s\n' "$VERSION" "$SIGNED" "$NOTARIZED" "$APPCAST" > "$DIST/release.env"
echo "== dist/: $(cd "$DIST" && ls | tr '\n' ' ')"
cat "$DIST/release.env"
