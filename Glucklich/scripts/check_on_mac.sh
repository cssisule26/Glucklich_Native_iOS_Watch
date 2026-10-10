#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build_dir="$(mktemp -d)"
trap 'rm -rf "$task_build_dir"' EXIT
xcrun swiftc Shared/ForecastModel.swift Tests/ModelCheck.swift -o "$task_build_dir/model-check"
"$task_build_dir/model-check" "$PWD"
xcodebuild -project Glucklich.xcodeproj -scheme GlucklichWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$task_build_dir/watch" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Glucklich.xcodeproj -scheme Glucklich -destination 'generic/platform=iOS Simulator' -derivedDataPath "$task_build_dir/phone" CODE_SIGNING_ALLOWED=NO build
