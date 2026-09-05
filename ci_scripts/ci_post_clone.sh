#!/bin/bash
# No secret values are printed. This hook validates inputs; it never publishes.
set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
source "${ROOT}/scripts/release-common.sh"
source "${ROOT}/scripts/cloud-release-preflight.sh"

[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] || clio_die "this hook requires Xcode Cloud"
# This runtime supplies the App Store Connect team UUID (confirmed by the
# Cloud build and its App Store Connect URL), not the certificate Team ID.
if [[ "${CI_TEAM_ID:-}" != "00000000-0000-0000-0000-000000000000" ]]; then
    # Team identifiers are public metadata, not signing credentials. Never dump
    # the environment: report only a bounded identifier-shaped value.
    CLOUD_TEAM_DIAGNOSTIC="<missing>"
    if [[ -n "${CI_TEAM_ID:-}" ]]; then
        CLOUD_TEAM_DIAGNOSTIC="<unexpected format; value withheld>"
        if [[ "${CI_TEAM_ID}" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
            CLOUD_TEAM_DIAGNOSTIC="${CI_TEAM_ID}"
        fi
    fi
    clio_die "Cloud team mismatch: expected App Store Connect team 00000000-0000-0000-0000-000000000000; CI_TEAM_ID=${CLOUD_TEAM_DIAGNOSTIC}. Do not override Apple's CI_TEAM_ID variable."
fi
clio_require_exact_package_lock "${ROOT}/Clio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
bash "${ROOT}/scripts/test-cloud-release-preflight.sh"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${ROOT}/scripts/test_cloud_release.py"

if clio_is_release_tag; then
    clio_validate_release_environment
    [[ "$(git -C "${ROOT}" rev-parse HEAD)" == "${CI_COMMIT}" ]] \
        || clio_die "release checkout does not match CI_COMMIT"
    [[ "$(git -C "${ROOT}" rev-parse "refs/tags/${CI_TAG}^{commit}")" == "${CI_COMMIT}" ]] \
        || clio_die "release tag does not resolve to CI_COMMIT"
    echo "Clio internal release input preflight passed; Xcode tests are advisory. Archive, signing and artifact verification remain required."
else
    echo "Clio CI dependency preflight passed; this is not a release tag."
fi
