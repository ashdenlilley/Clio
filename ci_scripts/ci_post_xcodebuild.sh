#!/bin/bash
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/scripts/release-common.sh"
source "${ROOT}/scripts/cloud-release-preflight.sh"
[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] || clio_die "requires Xcode Cloud"
[[ "${CI_XCODEBUILD_EXIT_CODE:-1}" == "0" ]] || clio_die "Xcode action failed"
[[ "${CI_XCODEBUILD_ACTION:-}" == "archive" ]] || exit 0
clio_is_release_tag || exit 0
clio_validate_release_environment
exec /usr/bin/python3 "${ROOT}/scripts/cloud-release.py"
