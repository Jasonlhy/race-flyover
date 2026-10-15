# Fixing the Xcode Project for Run & Debug

Date: 2026-10-16
Goal: make `RaceFlyoverPreview.xcodeproj` build, run, and debug in Xcode, matching what `build.sh` produces for the preview app.

## Background

The repo normally builds with `build.sh`, which compiles the screensaver bundle and the preview app using raw `swiftc`/`lipo` calls and assembles the bundles by hand. An XcodeGen spec (`xcode/project.yml`) and a generated `RaceFlyoverPreview.xcodeproj` exist so the same code can be developed inside Xcode, but the project was broken in three ways.

## What was broken

### 1. Corrupt shared scheme — `RaceFlyoverPreview.xcodeproj/xcshareddata/xcschemes/RaceFlyoverPreview.xcscheme`

The Build action's `<BuildableReference>` was HTML-escaped text instead of a real XML element:

```xml
buildableReference =
   "&lt;BuildableReference
      BuildableIdentifier = &quot;primary&quot;
      ...
```

As a result Xcode reported **"Scheme RaceFlyoverPreview is not currently configured for the build action"** and refused to build at all. (The escaped text was invisible in Xcode's scheme editor; it only showed up by reading the raw file.)

### 2. Corrupt project file — `RaceFlyoverPreview.xcodeproj/project.pbxproj`

The object graph had scrambled build-file-to-file mappings and doubled path resolution:

- `StylizedView.swift` and `Theme.swift` were members of the **Copy Bundle Resources** phase (wrong phase for source files), producing "cannot be processed by a Copy Bundle Resources build phase" warnings.
- `Info-Preview.plist` was a member of the **Sources** phase.
- The `Courses` folder and `Info-Preview.plist` references resolved to nonexistent `Resources/Resources/...` paths, because both the parent group (`path = Resources`) and the file references (`path = "Resources/..."`) carried the folder prefix.
- `thumbnail.png` / `thumbnail@2x.png` had **no** build-file membership at all, so they were never copied into the app.
- Comments in the file did not match what the IDs actually pointed at, which made the file misleading to inspect.

Net effect: `xcodebuild` failed with "Build input file cannot be found: .../Resources/Resources/Info-Preview.plist" and similar errors.

### 3. Stale generator spec — `xcode/project.yml`

`INFOPLIST_FILE` still pointed at `Resources/Info.plist` — the **screensaver's** plist (`CFBundlePackageType = BNDL`, executable `RaceFlyover`, principal class `RaceFlyoverView`). The preview app needs `Resources/Info-Preview.plist` (`APPL`, executable `RaceFlyoverPreview`, principal class `NSApplication`). Any future `xcodegen` regeneration would have re-introduced a broken app target. (`xcodegen` is not installed on this machine; the fix was verified by editing the generated project directly.)

## What was changed

1. **Scheme** — rewrote `RaceFlyoverPreview.xcscheme` with a proper `<BuildableReference>` element in the Build action (same target UUID `9A7C6F94F2F54E3AB29F47FA`), enabled the standard build flags, and kept the existing run arguments (`--course berlin --style satellite --progress 0.3`).

2. **Project file** — regenerated `project.pbxproj` cleanly:
   - Groups mirror the filesystem: `Sources/RaceFlyover`, `Sources/Preview`, `Resources`, `Frameworks`.
   - File references use plain file names resolved through their parent groups (no more doubled paths).
   - **Sources** phase: the 18 Swift files (`Sources/RaceFlyover/*.swift` + `Sources/Preview/main.swift`).
   - **Frameworks** phase: AppKit, MapKit, CoreLocation, QuartzCore, Metal, ScreenSaver.
   - **Resources** phase: `Courses` (blue folder reference → copied to `Contents/Resources/Courses`), `thumbnail.png`, `thumbnail@2x.png`. `Info-Preview.plist` is intentionally *not* in this phase — it is processed via `INFOPLIST_FILE`.
   - Preserved build settings: `INFOPLIST_FILE = Resources/Info-Preview.plist`, `PRODUCT_BUNDLE_IDENTIFIER = com.raceflyover.preview`, `MACOSX_DEPLOYMENT_TARGET = 14.0`, `SWIFT_VERSION = 5.0`, `GENERATE_INFOPLIST_FILE = NO`. Dropped `ASSETCATALOG_COMPILER_APPICON_NAME` (there is no asset catalog in the repo).

3. **Generator spec** — `xcode/project.yml` now sets `INFOPLIST_FILE: Resources/Info-Preview.plist` so regeneration stays consistent with the checked-in project.

## Result (verified)

All checks were run against the fixed project:

| Check | Command | Result |
| --- | --- | --- |
| Debug build | `xcodebuild -project RaceFlyoverPreview.xcodeproj -scheme RaceFlyoverPreview -configuration Debug build` | `BUILD SUCCEEDED`, no project warnings |
| Release build | same with `-configuration Release` | `BUILD SUCCEEDED` |
| Bundle layout | inspect `RaceFlyoverPreview.app` | `Contents/MacOS/RaceFlyoverPreview`, processed `Info.plist` (`APPL`, correct executable/identifier), all 20 course JSONs at `Contents/Resources/Courses`, thumbnails — matching the layout `build.sh` produces and what `Settings.swift` loads |
| Course loading | run binary with `--list` | all 14 marathon courses listed, exit 0 |
| Live run | `open` the app with the scheme's arguments | app launched and stayed running |
| Signing | (observed in build log) | ad-hoc "Sign to Run Locally" — no Apple Developer account or team required |

## How to use it

1. Open `RaceFlyoverPreview.xcodeproj` in Xcode.
2. Set breakpoints anywhere under `Sources/`.
3. Press **⌘R** to build, run, and debug.

The scheme passes `--course berlin --style satellite --progress 0.3` as run arguments; edit them under **Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments**, or remove them to use saved settings. All preview options are documented at the top of `Sources/Preview/main.swift` (e.g. `--list`, `--snapshot`, `--style`, `--camera`, `--lap`).

## Caveat

Re-running `xcode/generate_xcodeproj.sh` (requires `brew install xcodegen`) regenerates the project **without** the scheme's custom run arguments — re-add them in **Edit Scheme** afterward.
