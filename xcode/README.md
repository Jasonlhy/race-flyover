Race Flyover — Xcode project generator

This folder contains an XcodeGen spec to create a RaceFlyoverPreview Xcode macOS App project that wraps the existing Swift sources and preview entrypoint.

Prerequisites:
- xcodegen (install with: brew install xcodegen)
- Xcode 15 or later (recommended)

How to generate the project:

1. From the repository root run:
   ./xcode/generate_xcodeproj.sh

2. Open RaceFlyoverPreview.xcodeproj in Xcode.

Notes:
- The generated project references the repo's Sources/ and Resources/ files in-place (it does not copy them).
- After generating, open the scheme and set the "Run" scheme arguments to pass any desired preview options (see Sources/Preview/main.swift for CLI options).
- The project target links AppKit, MapKit, CoreLocation, Metal, QuartzCore and ScreenSaver frameworks.

If you prefer I can generate the full .xcodeproj for you (requires larger commit).