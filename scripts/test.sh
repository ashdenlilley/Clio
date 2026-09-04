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

set --
HAS_UI_TESTS=0
[[ ! -d "${REPOSITORY_ROOT}/ClioUITests" ]] || HAS_UI_TESTS=1
if [[ -n "${CLIO_TEST_RESULT_PATH:-}" ]]; then
    [[ ! -e "${CLIO_TEST_RESULT_PATH}" && ! -L "${CLIO_TEST_RESULT_PATH}" ]] \
        || clio_die "refusing to overwrite test results: ${CLIO_TEST_RESULT_PATH}"
    UNIT_RESULT_PATH="${CLIO_TEST_RESULT_PATH}"
    if [[ "${HAS_UI_TESTS}" == "1" ]]; then
        UNIT_RESULT_PATH="${CLIO_TEST_RESULT_PATH}.unit.xcresult"
        UI_RESULT_PATH="${CLIO_TEST_RESULT_PATH}.ui.xcresult"
        NATIVE_RESULT_PATH="${CLIO_TEST_RESULT_PATH}.native.xcresult"
        for result_path in "${UNIT_RESULT_PATH}" "${UI_RESULT_PATH}" "${NATIVE_RESULT_PATH}"; do
            [[ ! -e "${result_path}" && ! -L "${result_path}" ]] \
                || clio_die "refusing to overwrite test results: ${result_path}"
        done
    fi
    set -- -resultBundlePath "${UNIT_RESULT_PATH}"
fi

# The real SIGKILL recovery subprocess runs under the unsigned unit host.
# UI automation and the real display-link test require an ad-hoc-signed runner;
# run them separately from the unsigned suite and serially
# so the two hosts cannot steal focus or terminate each other's application.
xcodebuild \
    -project Clio.xcodeproj \
    -scheme Clio \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}/UnitTests" \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    -only-testing:ClioTests \
    "$@" \
    CODE_SIGNING_ALLOWED=NO \
    test

if [[ "${HAS_UI_TESTS}" == "1" ]]; then
    # Fail clearly instead of waiting for XCTest's opaque activation timeout.
    CONSOLE_STATE="$(/usr/sbin/ioreg -n Root -d1)"
    if [[ "${CONSOLE_STATE}" == *'"CGSSessionScreenIsLocked"=Yes'* ]]; then
        clio_die "native UI tests require an unlocked macOS desktop; unlock this Mac and rerun the gate"
    fi
    set --
    if [[ -n "${CLIO_TEST_RESULT_PATH:-}" ]]; then
        set -- -resultBundlePath "${UI_RESULT_PATH}"
    fi
    xcodebuild \
        -project Clio.xcodeproj \
        -scheme Clio \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_PATH}/UITests" \
        -onlyUsePackageVersionsFromResolvedFile \
        -disableAutomaticPackageResolution \
        -only-testing:ClioUITests \
        "$@" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_IDENTITY=- \
        test

    # Keep the native unit-host lifecycle and diagnostics separate from UI
    # automation, while reusing the same signed build products.
    set --
    if [[ -n "${CLIO_TEST_RESULT_PATH:-}" ]]; then
        set -- -resultBundlePath "${NATIVE_RESULT_PATH}"
    fi
    TEST_RUNNER_CLIO_RUN_NATIVE_MOTION_TESTS=1 xcodebuild \
        -project Clio.xcodeproj \
        -scheme Clio \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_PATH}/UITests" \
        -onlyUsePackageVersionsFromResolvedFile \
        -disableAutomaticPackageResolution \
        -only-testing:ClioTests/WindowMotionAdapterTests/testNativeDisplayLinkAdvancesVisibleWindowAndStopsAtRest \
        "$@" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_IDENTITY=- \
        test
    if [[ -n "${CLIO_TEST_RESULT_PATH:-}" ]]; then
        xcrun xcresulttool merge --output-path "${CLIO_TEST_RESULT_PATH}" \
            "${UNIT_RESULT_PATH}" "${UI_RESULT_PATH}" "${NATIVE_RESULT_PATH}"
    fi
fi

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
