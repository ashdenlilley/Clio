#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
DERIVED_DATA_PATH="${CLIO_DERIVED_DATA_PATH:-${REPOSITORY_ROOT}/.build/DerivedData}"
SKIP_RELEASE_BUILD="${CLIO_SKIP_RELEASE_BUILD:-0}"

# shellcheck source=release-common.sh
source "${SCRIPT_DIR}/release-common.sh"

[[ "${SKIP_RELEASE_BUILD}" == "0" || "${SKIP_RELEASE_BUILD}" == "1" ]] \
    || clio_die "CLIO_SKIP_RELEASE_BUILD must be 0 or 1"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "${REPOSITORY_ROOT}"

clio_require_command xcodebuild
clio_require_command xcodegen
[[ "$(xcodegen --version)" == "Version: 2.46.0" ]] \
    || clio_die "tests require XcodeGen 2.46.0"

xcodegen generate
git diff --exit-code -- Clio.xcodeproj project.yml \
    || clio_die "xcodegen changed the checked-in project; commit the generated project first"

PACKAGE_RESOLVED="${REPOSITORY_ROOT}/Clio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
clio_require_exact_package_lock "${PACKAGE_RESOLVED}"

xcodebuild \
    -project Clio.xcodeproj \
    -scheme Clio \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    test

if [[ "${SKIP_RELEASE_BUILD}" != "1" ]]; then
    xcodebuild \
        -project Clio.xcodeproj \
        -scheme Clio \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        -onlyUsePackageVersionsFromResolvedFile \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS="arm64 x86_64" \
        build
fi
