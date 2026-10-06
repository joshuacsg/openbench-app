#!/usr/bin/env bash
# Build a notarized, direct-download DMG of FastPort Host (flux-host embedded).
#
# Usage: ./Scripts/build-host-dmg.sh [--skip-notarize]
#
# The Host can't ship via TestFlight / the Mac App Store (no sandbox, input
# injection, private CGVirtualDisplay), so it goes out Developer ID-signed and
# notarized instead. Steps: cargo-build flux-host → archive the Host app →
# embed flux-host in Contents/MacOS → sign both (hardened runtime) → DMG →
# notarize + staple. Output: build/host-dmg/FastPort-Host-<version>.dmg
#
# One-time setup:
#   1. Developer ID Application certificate (Account Holder only):
#      Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application
#   2. Notary credentials in the keychain (app-specific password from
#      account.apple.com):
#      xcrun notarytool store-credentials fastport-notary \
#        --apple-id <you@example.com> --team-id 6T4Q524WV2
#
# Env overrides:
#   FLUX_ROOT       flux repo (default: sibling ../flux, else ~/Documents/GitHub/flux)
#   SIGN_IDENTITY   codesign identity (default: first "Developer ID Application")
#   NOTARY_PROFILE  notarytool keychain profile (default: fastport-notary)
#
# --skip-notarize   Build + sign + DMG only (e.g. testing with an
#                   Apple Development identity, which can't be notarized).

set -euo pipefail

# --- args -------------------------------------------------------------------
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $arg (try --skip-notarize or --help)" >&2
      exit 2
      ;;
  esac
done

# --- paths ------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${FLUX_ROOT:-}" ]]; then
  # Sibling checkout, else the dev path HostManager also searches.
  FLUX_ROOT="$REPO_ROOT/../flux"
  [[ -d "$FLUX_ROOT" ]] || FLUX_ROOT="$HOME/Documents/GitHub/flux"
fi
FLUX_ROOT="$(cd "$FLUX_ROOT" && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-fastport-notary}"
OUT_DIR="$REPO_ROOT/build/host-dmg"
ARCHIVE="$OUT_DIR/FastPort-Host.xcarchive"
STAGE="$OUT_DIR/stage"
APP_NAME="FastPort Host.app"
APP="$STAGE/$APP_NAME"
FLUX_BIN="$FLUX_ROOT/target/release/flux-host"
# Keep in lockstep with rebuild-flux-host.sh so TCC sees one identity.
FLUX_IDENTIFIER="com.joshiee.fastport.fluxhost"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ no \"Developer ID Application\" identity in the keychain." >&2
  echo "  Create one (see --help), or set SIGN_IDENTITY to test with another." >&2
  exit 1
fi
if [[ "$NOTARIZE" == 1 && "$SIGN_IDENTITY" != *"Developer ID Application"* ]]; then
  echo "✗ only Developer ID builds can be notarized; got \"$SIGN_IDENTITY\"." >&2
  echo "  Pass --skip-notarize to build a local test DMG." >&2
  exit 1
fi

echo "flux repo:   $FLUX_ROOT"
echo "identity:    $SIGN_IDENTITY"
echo "output:      $OUT_DIR"

rm -rf "$OUT_DIR"
mkdir -p "$STAGE"

# --- flux-host --------------------------------------------------------------
echo "→ cargo build --release -p flux-host..."
cargo build --release -p flux-host --manifest-path "$FLUX_ROOT/Cargo.toml"
[[ -x "$FLUX_BIN" ]] || { echo "✗ flux-host not found at $FLUX_BIN" >&2; exit 1; }

# --- archive the Host app ---------------------------------------------------
# Hardened runtime is mandatory for notarization. The archive's own signature
# is replaced below, so its identity doesn't matter.
echo "→ archiving FastPort Host..."
xcodebuild -project "$REPO_ROOT/FastPort.xcodeproj" -scheme "FastPort Host" \
  -configuration Release -destination 'generic/platform=macOS' \
  archive -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  ENABLE_HARDENED_RUNTIME=YES -quiet

ditto "$ARCHIVE/Products/Applications/$APP_NAME" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/FastPort-Host-$VERSION.dmg"

# --- embed + sign (inside-out: helper first, then the app) ------------------
echo "→ embedding flux-host in Contents/MacOS..."
ditto "$FLUX_BIN" "$APP/Contents/MacOS/flux-host"

echo "→ signing..."
codesign --force --timestamp --options runtime \
  --identifier "$FLUX_IDENTIFIER" --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/flux-host"
codesign --force --timestamp --options runtime \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# --- DMG --------------------------------------------------------------------
echo "→ building $DMG..."
ln -s /Applications "$STAGE/Applications"
# APFS, not HFS+: on macOS 26 `hdiutil create -fs HFS+ -srcfolder` writes a
# truncated image ("chunk 1 data starts beyond end of data fork") whenever the
# folder holds the app bundle AND an absolute symlink like Applications — it
# still exits 0. APFS images mount on macOS 10.13+; the Host needs 14.
hdiutil create -volname "FastPort Host" -srcfolder "$STAGE" \
  -fs APFS -format UDZO -ov "$DMG" -quiet
# hdiutil can report success on a corrupt image; never ship one unchecked.
hdiutil verify "$DMG" -quiet || { echo "✗ $DMG failed hdiutil verify" >&2; exit 1; }
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# --- notarize + staple ------------------------------------------------------
if [[ "$NOTARIZE" == 1 ]]; then
  echo "→ notarizing (profile: $NOTARY_PROFILE) — usually a few minutes..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "⚠ skipped notarization — Gatekeeper will block this DMG on other Macs"
fi

echo
echo "✓ $DMG"
