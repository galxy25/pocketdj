# PocketDJ native apps — build & test reference

The `apple/` directory is a **fully native SwiftUI** PocketDJ client — one
multiplatform target that runs on **iPhone, iPad, and Mac** — talking to the same
CloudFront/S3/Tailscale backends as the web PWA. This is the deep reference; the
**apple-build** and **apple-test** skills are the quick how-tos.

## Toolchain

| Need | How |
|------|-----|
| Full Xcode (not CLT) | `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| Project generator | `brew install xcodegen` |
| Generate the `.xcodeproj` | `cd apple && xcodegen generate` |

The project is generated from **`project.yml`**. Add/rename Swift files on disk,
then regenerate — don't add files through Xcode's UI (they vanish on the next
generate). The generated `PocketDJ.xcodeproj` is committed so the project opens
without a generate step; `build*/` and Xcode user state are gitignored.

## Project layout

```
apple/
  project.yml                 # XcodeGen spec (one app target + 2 test bundles)
  PocketDJ/
    PocketDJApp.swift          Support/   Models/   Services/
    State/   Browse/   Views/   Settings/   Resources/   Assets.xcassets
  Tests/
    Unit/  (PocketDJTests — pure logic, fixture-backed)
    UI/    (PocketDJUITests — XCUITest, app.el helper)
  scripts/test-macos.sh        # ad-hoc-signed macOS test run
  docs/build-and-test.md       # this file
```

Targets: `PocketDJ` (app), `PocketDJTests` (unit, hosted in the app),
`PocketDJUITests` (UI). The `PocketDJ` scheme runs both test bundles.

## Building

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apple && xcodegen generate

# iOS Simulator (no signing required)
xcodebuild -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build

# macOS (ad-hoc sign so it launches)
xcodebuild -project PocketDJ.xcodeproj -scheme PocketDJ -destination 'platform=macOS' \
  -derivedDataPath build-mac CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - build-mac/Build/Products/Debug/PocketDJ.app
open build-mac/Build/Products/Debug/PocketDJ.app
```

## Testing

```bash
# iPhone / iPad — full unit + UI suite (give each device its own derivedDataPath)
xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO
xcodebuild test ... -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath build-ipad CODE_SIGNING_ALLOWED=NO

# macOS — ad-hoc signed (Gatekeeper blocks the unsigned XCUITest runner)
bash scripts/test-macos.sh
```

> ⚠️ Never run two `xcodebuild` commands against the **same** `-derivedDataPath`
> at once — the second clobbers `TEST_HOST` ("Could not find test host"). Use a
> separate dir per concurrent run (`build`, `build-ipad`, `build-mactest`, …).

### Testability design

- **Data layer behind a protocol** (`CatalogLoading`). The pure engines
  (`FilterEngine`, `SortEngine`, `Genre`, `Camelot`, formatting,
  `SettingsStore`, `AppModel.merge`) have no network/data dependency and are
  unit-tested against an in-memory fixture (`Tests/Unit/Fixtures.swift`).
- **Launch seams** (env vars) make the UI deterministic + offline:
  - `PDJ_USE_FIXTURE=1` → bundled `fixture-index.json` + isolated, auto-cleared
    UserDefaults (settings *and* browse prefs reset each launch).
  - `PDJ_START_SECTION=<Browser|Settings|…>` → land on a section.
  - `PDJ_OPEN_FIRST_ALBUM=1` → deep-link into an album's track table.
- **`app.el("id")`** (Tests/UI/XCUIHelpers.swift) matches a control by identifier
  *or* label across element types, so toolbar buttons + the segmented picker
  resolve on macOS (where they're `.toolbars`/`.radioButtons`, not `.buttons`).

## Signing (the saga, so nobody re-derives it)

`project.yml`: **automatic** signing, team **EC27UF79GL** (Levi Schoen). That is
correct for **Xcode.app** builds, on-device runs, and App Store archives.

CLI gotchas and the workarounds in use:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `requires a development team / profile` | automatic signing + no team/cert | first build once in **Xcode.app** (My Mac) to mint the cert |
| `errSecInternalComponent` on CodeSign | CLI codesign can't reach the key headlessly | sim: `CODE_SIGNING_ALLOWED=NO`; macOS: ad-hoc `codesign --sign -` / `scripts/test-macos.sh` |
| `"PocketDJUITests-Runner is damaged"` | unsigned runner blocked by Gatekeeper | ad-hoc sign it (the script does) |

To use the real cert from the CLI (`-allowProvisioningUpdates` instead of
ad-hoc): Keychain Access ▸ **Apple Development** private key ▸ Get Info ▸ Access
Control ▸ **Allow all applications**.

## Visual proof

`xcrun simctl io <UDID> screenshot out.png` works with no extra permissions.
`screencapture` (for the Mac window) needs Screen Recording granted to the
terminal/host — otherwise it errors `could not create image from display`.
