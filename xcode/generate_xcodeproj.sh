#!/bin/bash
set -euo pipefail
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen"
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Generate the Xcode project using the spec
xcodegen generate --spec xcode/project.yml --project Specified
# xcodegen writes RaceFlyoverPreview.xcodeproj by default; if you want it in a specific location, adjust the spec
echo "Generated RaceFlyoverPreview.xcodeproj in $ROOT"
