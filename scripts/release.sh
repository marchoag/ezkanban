#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, staple, and package EZKanban as a DMG.
# Adapted from Blinken's scripts/release.sh; same pipeline, same guard rails.
#
# Usage:  ./scripts/release.sh                     # full pipeline (needs a notary profile)
#         ./scripts/release.sh --skip-notarize     # local smoke test, NOT distributable
#         ./scripts/release.sh --package-only <EZKanban.app>
#             # Xcode ▸ Product ▸ Archive ▸ Distribute App ▸ Direct Distribution already
#             # signs + notarizes + staples using your Xcode account (no app-specific
#             # password needed). Hand the exported app to this mode to verify and package it.
#
# Output: build/EZKanban.dmg
#
# The artifact name is deliberately unversioned. The site links GitHub's permalink
#     https://github.com/marchoag/ezkanban/releases/latest/download/EZKanban.dmg
# which resolves by asset filename, so "EZKanban-1.0.0.dmg" would 404 every link.

set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_NOTARIZE=0
PACKAGE_ONLY=0
APP_IN=""
case "${1:-}" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --package-only)  PACKAGE_ONLY=1; APP_IN="${2:-}" ;;
    "") ;;
    *) printf 'usage: %s [--skip-notarize | --package-only path/to/EZKanban.app]\n' "$0" >&2; exit 2 ;;
esac

# The Axiomic, LLC team that owns the Developer ID cert. Not a secret (it's readable
# from any shipped build with codesign -dvvv), and project.yml already carries it.
TEAM_ID="${EZKANBAN_TEAM_ID:-$(grep 'DEVELOPMENT_TEAM:' project.yml | awk '{print $2}')}"
# Stored once with: xcrun notarytool store-credentials axiomic-notarize --apple-id <id> --team-id <team>
NOTARY_PROFILE="${EZKANBAN_NOTARY_PROFILE:-axiomic-notarize}"
readonly BUILD_DIR="build"
readonly APP="${BUILD_DIR}/EZKanban.app"
readonly DMG="${BUILD_DIR}/EZKanban.dmg"
readonly ARCHIVE="${BUILD_DIR}/EZKanban.xcarchive"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

die()  { printf '\n❌ %s\n' "$1" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$1"; }

# ── Preflight ────────────────────────────────────────────────────────────────

step "Preflight"
command -v xcodegen   >/dev/null || die "xcodegen not installed:  brew install xcodegen"
command -v dmgbuild   >/dev/null || printf '   note    : dmgbuild not found (pipx install dmgbuild); the DMG will have no window layout\n'
[[ -n "${TEAM_ID}" ]] || die "No team ID: set DEVELOPMENT_TEAM in project.yml or export EZKANBAN_TEAM_ID."

if [[ ${SKIP_NOTARIZE} -eq 0 && ${PACKAGE_ONLY} -eq 0 ]]; then
    xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
        || die "Notary profile '${NOTARY_PROFILE}' not found in the keychain.
   Store it once (interactive; needs an app-specific password from account.apple.com):
        xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <your-apple-id> --team-id ${TEAM_ID}
   Or let Xcode notarize: Product ▸ Archive ▸ Distribute App ▸ Direct Distribution, then
        ./scripts/release.sh --package-only <exported EZKanban.app>"
fi

VERSION=$(grep 'MARKETING_VERSION:' project.yml | sed -E 's/.*"(.+)".*/\1/')
printf '   version : %s   team : %s\n' "${VERSION}" "${TEAM_ID}"

if [[ ${PACKAGE_ONLY} -eq 1 ]]; then
    # ── Package-only: trust Xcode's output, but verify the two things that matter ──
    [[ -d "${APP_IN}" ]] || die "Pass the app Xcode exported:  ./scripts/release.sh --package-only ~/Desktop/EZKanban.app"
    step "Validating ${APP_IN}"
    SIG=$(codesign -dvvv "${APP_IN}" 2>&1 || true)
    grep -q "Authority=Developer ID Application" <<<"${SIG}" \
        || die "Not signed with Developer ID (use Direct Distribution, not Debugging)."
    xcrun stapler validate "${APP_IN}" >/dev/null 2>&1 \
        || die "No notarization ticket stapled; wait for Organizer to finish notarizing, then export."
    rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}"
    cp -R "${APP_IN}" "${APP}"
else
    # ── 1. Regenerate + archive ──────────────────────────────────────────────
    step "Generating project from project.yml"
    xcodegen generate

    step "Archiving (Release, universal)"
    rm -rf "${BUILD_DIR}"
    xcodebuild -project EZKanban.xcodeproj -scheme EZKanban -configuration Release \
        archive -archivePath "${ARCHIVE}" \
        DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Automatic \
        -allowProvisioningUpdates -quiet

    # ── 2. Export with Developer ID ──────────────────────────────────────────
    # signingStyle automatic lets Xcode use the cloud-managed Developer ID cert,
    # whose private key never lands in the local keychain.
    step "Exporting signed .app"
    cat > "${BUILD_DIR}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "${ARCHIVE}" -exportPath "${BUILD_DIR}" \
        -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" -allowProvisioningUpdates -quiet

    # ── 3. Verify the signature ──────────────────────────────────────────────
    step "Verifying signature"
    codesign --verify --deep --strict --verbose=2 "${APP}"
    # Captured, not piped: under pipefail, grep -q's early exit SIGPIPEs codesign.
    SIG=$(codesign -dvvv "${APP}" 2>&1 || true)
    grep -q "Authority=Developer ID Application" <<<"${SIG}" \
        || die "Exported app is NOT signed with Developer ID.
   Signed with: $(grep -m1 'Authority=' <<<"${SIG}" || echo '(none)')"

    # ── 4. Notarize + staple the app (not the DMG) ───────────────────────────
    # A ticket stapled to the .app survives the user dragging it to /Applications
    # and deleting the DMG; one stapled only to the DMG does not.
    if [[ ${SKIP_NOTARIZE} -eq 1 ]]; then
        printf '\n⚠️  Skipping notarization; output will NOT be distributable.\n'
    else
        step "Notarizing (a few minutes)"
        ditto -c -k --keepParent "${APP}" "${BUILD_DIR}/notarize.zip"
        xcrun notarytool submit "${BUILD_DIR}/notarize.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
        rm -f "${BUILD_DIR}/notarize.zip"
        step "Stapling"
        xcrun stapler staple "${APP}"
        xcrun stapler validate "${APP}"
    fi
fi

if [[ ${SKIP_NOTARIZE} -eq 0 ]]; then
    step "Gatekeeper check (must say: source=Notarized Developer ID)"
    spctl -a -vvv "${APP}"
fi

# ── 5. Package ───────────────────────────────────────────────────────────────
# dmgbuild writes the window layout (background, icon positions) straight into the
# image, so unlike create-dmg it needs no Finder automation permission. Layout lives
# in scripts/dmg/ (settings.py, background.tiff and its HTML source).
step "Packaging DMG"
if command -v dmgbuild >/dev/null; then
    dmgbuild -s scripts/dmg/settings.py -D app="${APP}" "EZKanban" "${DMG}"
else
    printf '\n⚠️  dmgbuild not installed (pipx install dmgbuild); making a plain DMG.\n'
    STAGE="${BUILD_DIR}/dmg-stage"
    rm -rf "${STAGE}" && mkdir -p "${STAGE}"
    cp -R "${APP}" "${STAGE}/" && ln -s /Applications "${STAGE}/Applications"
    hdiutil create -volname "EZKanban" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
    rm -rf "${STAGE}"
fi

[[ ${SKIP_NOTARIZE} -eq 1 ]] && { printf '\n⚠️  %s is NOT distributable (unnotarized).\n' "${DMG}"; exit 0; }

SHIPPED=$(defaults read "$(pwd)/${APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "${VERSION}")
cat <<EOF

✅ ${DMG}  —  v${SHIPPED} (read from the packaged app)

Next:
  1. gh release create v${SHIPPED} ${DMG} --title "EZKanban ${SHIPPED}" --notes-file CHANGELOG.md
     (the asset must upload as exactly "EZKanban.dmg"; the site's download link resolves by filename)
  2. Deploy labs.axiomic.ai/ezkanban from the axiomic repo
  3. Verify: curl -sIL https://github.com/marchoag/ezkanban/releases/latest/download/EZKanban.dmg | tail -2
EOF
