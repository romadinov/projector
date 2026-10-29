#!/bin/bash
# Builds a Developer ID signed, notarized Projector.app and zips it: scripts/release-mac.sh [version]
# Needs the "Developer ID Application" certificate and a notarytool keychain profile (NOTARY_PROFILE, default tasker-notary).
# With a version, also publishes the zip as a GitHub release (tag v<version>).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"
PROFILE="${NOTARY_PROFILE:-tasker-notary}"
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Projector.xcodeproj -scheme Projector-macOS -configuration Release -archivePath "$OUT/Projector.xcarchive" \
  -allowProvisioningUpdates ${VERSION:+MARKETING_VERSION=$VERSION} archive | grep -E "error:|ARCHIVE" || true
cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>SZVSSCJQFN</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/Projector.xcarchive" -exportPath "$OUT" -exportOptionsPlist "$OUT/export.plist" \
  -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
APP="$OUT/Projector.app"
ZIP="$OUT/Projector-macOS${VERSION:+-$VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
spctl -a -vv "$APP"
echo "Built $ZIP"
if [ -n "$VERSION" ]; then
  ASSETS=("$ZIP")
  [ -f demo/Projector_demo.mp4 ] && ASSETS+=(demo/Projector_demo.mp4)
  gh release create "v$VERSION" "${ASSETS[@]}" --title "Projector $VERSION" --notes-file - <<EOF
Projector for Mac, signed with Developer ID and notarized by Apple. Unzip and move **Projector.app** to Applications. Requires macOS 27.

- WBS with phases, tasks and milestones; FS/SS/FF/SF links with lag
- Critical path (forward and backward CPM passes, total slack)
- "Starts after" dates and "Finish by" deadlines on tasks and phases; late tasks get negative slack and are flagged
- Resources, a spreadsheet-style resource plan (days / weeks / months) and resource levelling
- Quick Plan: jot a plan as text, preview the finish date and critical path, or let Claude flesh it out

**Projector_demo.mp4** is a 2½-minute narrated walkthrough on iPad.

iPhone and iPad builds can't be distributed as files: build them from source with Xcode (see the README).
EOF
fi
