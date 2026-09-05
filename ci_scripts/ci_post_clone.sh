#!/bin/bash
# No secret values are printed. This hook validates inputs; it never publishes.
set +x
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
source "${ROOT}/scripts/release-common.sh"
source "${ROOT}/scripts/cloud-release-preflight.sh"

[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] || clio_die "this hook requires Xcode Cloud"
[[ "${CI_TEAM_ID:-}" == "REDACTED00" ]] || clio_die "unexpected Xcode Cloud team"
clio_require_exact_package_lock "${ROOT}/Clio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
bash "${ROOT}/scripts/test-cloud-release-preflight.sh"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "${ROOT}/scripts/test_cloud_release.py"

if clio_is_release_tag; then
    clio_validate_release_environment
    [[ "$(git -C "${ROOT}" rev-parse HEAD)" == "${CI_COMMIT}" ]] \
        || clio_die "release checkout does not match CI_COMMIT"
    [[ "$(git -C "${ROOT}" rev-parse "refs/tags/${CI_TAG}^{commit}")" == "${CI_COMMIT}" ]] \
        || clio_die "release tag does not resolve to CI_COMMIT"
    echo "Clio release input preflight passed; publication requires independent CI evidence."
else
    echo "Clio CI dependency preflight passed; this is not a release tag."
fi
