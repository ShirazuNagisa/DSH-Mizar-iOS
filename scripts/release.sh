#!/usr/bin/env bash
#
# Build a TestFlight-ready build, and put the package where the release folder
# expects it.
#
# Usage:
#   scripts/release.sh archive   build the .xcarchive, upload nothing
#   scripts/release.sh export    make the .ipa, upload nothing
#   scripts/release.sh upload    archive, export and upload to App Store Connect
#   scripts/release.sh open      open the archive in Organizer, ready to upload
#   scripts/release.sh bump      show the current version and build number
#
# Output: ${MIZAR_RELEASE_DIR:-../release/iOS}/DSH-Mizar-<version>.ipa
#         the intermediate .xcarchive and the raw export stay under .devcache/
#
# Signing needs a paid Apple Developer account with an "Apple Distribution"
# certificate in the login keychain. If the certificate is missing, run
# `scripts/release.sh archive` under Xcode's own account handling first, or add
# the certificate through Xcode's Settings > Accounts.
#
# The first upload for a bundle id also needs an app record to exist in App
# Store Connect. Xcode cannot create one; see docs/testflight.md.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${MIZAR_TEAM_ID:-5Q2A46685M}"
SCHEME="DSH-Mizar"
PROJECT="$ROOT/DSH-Mizar.xcodeproj"
EXPORT_OPTIONS="$ROOT/ExportOptions.plist"

# Where the finished package goes. The release folder sits beside the three
# repositories, which is why this is not inside the repository itself.
OUT_DIR="${MIZAR_RELEASE_DIR:-$ROOT/../release/iOS}"

# Intermediates stay hidden: nobody opens a .xcarchive by hand here, and the
# package that matters is the .ipa in the release folder.
CACHE="$ROOT/.devcache"
ARCHIVE="$CACHE/DSH-Mizar.xcarchive"
EXPORT_DIR="$CACHE/export"

die() { printf 'release: %s\n' "$1" >&2; exit 1; }

mkdir -p "$CACHE" "$OUT_DIR"

# Localised rejection messages are useless in a build log; force English so a
# failure can be grepped and understood the same way on any machine.
export LC_ALL=en_US.UTF-8

version() {
  /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' \
    "$ARCHIVE/Info.plist" 2>/dev/null \
    || grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed 's/.*= //; s/;.*//'
}

archive() {
  echo "release: archiving $SCHEME for the App Store"
  # A stale archive from an earlier run would make a failed build look like a
  # success: the check below would find a directory and report its old version.
  rm -rf "$ARCHIVE"
  local log="$CACHE/archive.log"
  if ! xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$CACHE/DerivedData" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic >"$log" 2>&1; then
    grep -E "error:|ARCHIVE FAILED" "$log" | tail -20 || true
    die "archive failed — see $log"
  fi
  grep -E "warning: .*(provision|sign|entitlement)|ARCHIVE (SUCCEEDED|FAILED)" "$log" || true
  test -d "$ARCHIVE" || die 'archive failed'
  echo "release: $ARCHIVE"
  echo "release: version $(version)"
}

export_ipa() {
  local destination="$1"
  # A copy, not the file itself: rewriting the committed plist would leave the
  # working tree dirty after every export, and the destination is a per-run
  # choice rather than a project setting.
  local options="$CACHE/ExportOptions.$destination.plist"
  cp "$EXPORT_OPTIONS" "$options"
  /usr/libexec/PlistBuddy -c "Set :destination $destination" "$options"
  echo "release: exporting ($destination)"
  rm -rf "$EXPORT_DIR"
  # The exit status matters, and a pipe to grep hides it: an upload that failed
  # to authenticate used to be reported as "uploaded to App Store Connect"
  # because grep found the word "error" in a line that was printed anyway.
  local log="$CACHE/export.$destination.log"
  if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$options" \
    -allowProvisioningUpdates >"$log" 2>&1; then
    grep -E "error:|EXPORT FAILED|Failed to" "$log" | tail -10 || true
    die "export ($destination) failed — see $log"
  fi
  grep -E "error:|Upload succeeded|Exported|EXPORT (SUCCEEDED|FAILED)" "$log" || true
  # An upload destination never produces a local .ipa: the package goes straight
  # to App Store Connect from xcodebuild. Failing here used to report a successful
  # upload as "export produced no .ipa", which is the wrong conclusion to draw
  # from a log whose last line is Upload succeeded.
  if [ "$destination" = "upload" ]; then
    echo "release: uploaded to App Store Connect — the build appears in TestFlight after processing"
    return 0
  fi
  test -f "$EXPORT_DIR/DSH-Mizar.ipa" || die 'export produced no .ipa'
  # Named by version, because a folder of identical `DSH-Mizar.ipa` files is a
  # folder nobody can tell apart.
  local named="$OUT_DIR/DSH-Mizar-$(version).ipa"
  mv "$EXPORT_DIR/DSH-Mizar.ipa" "$named"
  echo "release: $named"
  shasum -a 256 "$named" | sed 's/^/release: sha256 /'
}

case "${1:-archive}" in
  archive) archive ;;
  export)  archive; export_ipa export ;;
  upload)  archive; export_ipa upload ;;
  open)
    test -d "$ARCHIVE" || die "nothing to open yet — run 'scripts/release.sh archive'"
    open "$ARCHIVE"
    echo "release: opened $ARCHIVE in Organizer — Distribute App > TestFlight & App Store"
    ;;
  bump) version ;;
  *) die 'usage: scripts/release.sh archive|export|upload|open|bump' ;;
esac
