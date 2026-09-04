#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED_DATA_PATH="${CLIO_DERIVED_DATA_PATH:-${REPOSITORY_ROOT}/.build/DerivedData}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "${REPOSITORY_ROOT}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: XcodeGen 2.46.0 or newer is required" >&2
    exit 1
fi

xcodegen generate

xcodebuild \
    -project Clio.xcodeproj \
    -scheme Clio \
    -configuration Debug \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    test

xcodebuild \
    -project Clio.xcodeproj \
    -scheme Clio \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

