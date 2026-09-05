#!/bin/bash
set +x
set -euo pipefail
# Cloud test-without-building workers may receive only ci_scripts, not the
# source checkout. Decide whether release tooling is needed before sourcing it.
[[ "${CI_XCODE_CLOUD:-}" == "TRUE" ]] || { echo "error: requires Xcode Cloud" >&2; exit 1; }
if [[ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]]; then
    echo "Xcode action failed; release processing will not run." >&2
    exit 1
fi
[[ "${CI_XCODEBUILD_ACTION:-}" == "archive" ]] || exit 0
[[ -n "${CI_TAG:-}" && -z "${CI_PULL_REQUEST_NUMBER:-}" ]] || exit 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/scripts/release-common.sh"
source "${ROOT}/scripts/cloud-release-preflight.sh"
clio_is_release_tag || exit 0
clio_validate_release_environment
exec /usr/bin/python3 "${ROOT}/scripts/cloud-release.py"
