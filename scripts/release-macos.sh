#!/bin/sh
# Developer ID sign (Hardened Runtime) + notarize + staple the native app bundle (US-016, NFR-011, TC-020).
# Usage: ./scripts/release-macos.sh [path/to/App.app]   (build first: ./bundle-app.sh)
# Env:   DEVELOPER_ID    e.g. "Developer ID Application: Name (TEAMID)"  (unset => dry-run)
#        NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials); unset => skip notarization
#        DRY_RUN=1       force dry-run (print commands only)
# Dry-run never calls codesign/notarytool/stapler and never contacts Apple.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:-"$root/.build/NativeApp/Mac Remote Workspace.app"}
ent="$root/scripts/MacRemoteWorkspace.entitlements"
zip="${app%.app}.notarize.zip"

dry=0
[ "${DRY_RUN:-}" = 1 ] && dry=1
[ -z "${DEVELOPER_ID:-}" ] && dry=1
[ "$dry" = 1 ] && echo "==> DRY-RUN: DEVELOPER_ID unset or DRY_RUN=1; nothing is signed or submitted."

run() { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }
id=${DEVELOPER_ID:-"<DEVELOPER_ID>"}

[ -d "$app" ] || { echo "error: app bundle not found: $app" >&2; exit 1; }
[ -f "$ent" ] || { echo "error: entitlements missing: $ent" >&2; exit 1; }

sign() { run codesign --force --timestamp --options runtime --entitlements "$ent" -s "$id" "$1"; }

# Inside-out order; never --deep for the release signature.
echo "==> Signing nested code"
find "$app/Contents/Frameworks" "$app/Contents/Resources" -type f \( -name '*.dylib' -o -name '*.so' \) 2>/dev/null |
  while IFS= read -r f; do sign "$f"; done
find "$app/Contents/Frameworks" -maxdepth 1 -name '*.framework' 2>/dev/null |
  while IFS= read -r f; do sign "$f"; done
if [ -e "$app/Contents/MacOS/RdpSessionHelper" ]; then
  sign "$app/Contents/MacOS/RdpSessionHelper"
else
  echo "note: RdpSessionHelper not present in bundle; skipped"
fi
sign "$app/Contents/MacOS/MacRemoteWorkspace"
echo "==> Signing bundle"
sign "$app"

echo "==> Verifying signature"
run codesign --verify --deep --strict --verbose=2 "$app"
run codesign -d --entitlements - --verbose=2 "$app"

if [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "==> NOTARY_PROFILE unset: skipping notarization/staple (TC-020 evidence NOT produced)."
  exit 0
fi

echo "==> Notarizing"
run ditto -c -k --keepParent "$app" "$zip"
run xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
run xcrun stapler staple "$app"
run xcrun stapler validate "$app"
run spctl --assess --type execute --verbose=4 "$app"
echo "==> Done. Still required: clean-Mac Finder launch with Gatekeeper enabled (TC-020)."
