# FastPort (openbench-app) — agent guide

The iPad/macOS viewer + macOS menu-bar host for the flux streaming engine.
The iPad app is distributed via **TestFlight / App Store** under bundle id
`com.joshiee.fastport`, Apple Team ID `6T4Q524WV2`.

## Project layout gotcha (read first)

There are **two** XcodeGen-generated Xcode projects in this repo:

- `FastPort.xcodeproj` — the shipping app. **Use this for TestFlight.**
  Schemes: `FastPort` (the iOS app), `FastPort Host`, `FastPort Viewer`.
- `OpenBench.xcodeproj` — a parallel project kept in sync.

Source lives in `Shared/`, `iOS/`, `macOS/`, `Host/`. Both `.pbxproj` files
are hand-maintained: **when you add a new source file, you must register it
in BOTH `FastPort.xcodeproj/project.pbxproj` AND
`OpenBench.xcodeproj/project.pbxproj`** (PBXBuildFile, PBXFileReference, the
group children, and every Sources build phase), or the build breaks.

## Build + push a TestFlight build (exact steps)

Run everything from the repo root (`/Users/joshuachua/Documents/GitHub/openbench-app`).

### Prerequisites
- Xcode signed in to the Apple Developer account that owns Team `6T4Q524WV2`
  (Xcode ▸ Settings ▸ Accounts). The upload reuses that session for auth — no
  API key/password is passed on the command line.
- `-allowProvisioningUpdates` lets Xcode manage signing automatically.

### Step 1 — Create the export options plist
It is not committed (lives in `/tmp`). Recreate it if missing:

```bash
cat > /tmp/exportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>6T4Q524WV2</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
</dict>
</plist>
PLIST
```

`manageAppVersionAndBuildNumber = true` makes App Store Connect **auto-increment
the build number** on each upload — you do NOT need to bump it manually.

### Step 2 — (optional) verify it compiles
Faster failure than waiting for a full archive:

```bash
xcodebuild -project FastPort.xcodeproj -scheme FastPort \
  -destination 'generic/platform=iOS' -configuration Release build \
  -allowProvisioningUpdates 2>&1 | tail -3
```
Look for `** BUILD SUCCEEDED **`.

### Step 3 — Archive

```bash
xcodebuild -project FastPort.xcodeproj -scheme FastPort \
  -destination 'generic/platform=iOS' -configuration Release archive \
  -archivePath /tmp/FastPort.xcarchive -allowProvisioningUpdates 2>&1 | tail -3
```
Look for `** ARCHIVE SUCCEEDED **`.

### Step 4 — Export + upload to TestFlight

```bash
xcodebuild -exportArchive -archivePath /tmp/FastPort.xcarchive \
  -exportOptionsPlist /tmp/exportOptions.plist -allowProvisioningUpdates 2>&1 | tail -4
```
Success prints `Upload succeeded.`, `Uploaded FastPort`, and
`** EXPORT SUCCEEDED **`. The build then takes a few minutes to finish
processing in App Store Connect before it appears in TestFlight.

## Gotchas
- **Don't pipe a build/error count through `grep -c` in an `&&` chain** —
  `grep -c` exits non-zero when the count is 0, which silently aborts the
  rest of the command (e.g. a follow-up restart never runs).
- Only the **iOS app** ships here. The privileged Mac-side behavior
  (input injection, pasteboard, space switching) lives in the separate
  `flux` repo's host binary, which is distributed notarized/direct, NOT via
  the App Store, and is gated behind macOS Accessibility permission.
- Never use private Apple APIs (e.g. SkyLight `SLS*`) in shipped code — App
  Store rejection and runtime instability.
