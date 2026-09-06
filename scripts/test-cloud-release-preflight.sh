#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/release-common.sh"
source "${SCRIPT_DIR}/cloud-release-preflight.sh"

unset DEVELOPER_ID_CERT_P12 DEVELOPER_ID_CERT_PASSWORD DEVELOPER_TEAM_ID
unset NOTARY_ISSUER_ID NOTARY_KEY_ID NOTARY_PRIVATE_KEY GITHUB_TOKEN CI_COMMIT
unset EXPECTED_CLOUD_TEAM_ID CI_TEAM_ID
unset CI_TAG CI_GIT_REF CI_PULL_REQUEST_NUMBER
if clio_is_release_tag; then clio_die "branch build classified as release"; fi
export CI_TAG=v0.1.0 CI_GIT_REF=refs/tags/v0.1.0
clio_is_release_tag
if (CI_TAG=v01.1.0 clio_is_release_tag) 2>/dev/null; then clio_die "leading zero accepted"; fi
if (CI_GIT_REF=refs/heads/main clio_is_release_tag) 2>/dev/null; then clio_die "branch ref accepted"; fi
if (CI_PULL_REQUEST_NUMBER=1 clio_is_release_tag); then clio_die "PR accepted"; fi
if (CI_TAG=v0.1.0-rc1 clio_is_release_tag) 2>/dev/null; then clio_die "prerelease accepted"; fi
if (clio_validate_release_environment) 2>/dev/null; then clio_die "missing credentials accepted"; fi

# Synthetic fixtures only. These deliberately aren't usable signing credentials.
export DEVELOPER_ID_CERT_P12=Zml4dHVyZQ== DEVELOPER_ID_CERT_PASSWORD=fixture
export DEVELOPER_TEAM_ID=TESTTEAM01 NOTARY_ISSUER_ID=fixture NOTARY_KEY_ID=fixture
export EXPECTED_CLOUD_TEAM_ID=00000000-0000-0000-0000-000000000000 CI_TEAM_ID=00000000-0000-0000-0000-000000000000
export NOTARY_PRIVATE_KEY='-----BEGIN PRIVATE KEY----- fixture -----END PRIVATE KEY-----'
export GITHUB_TOKEN=fixture CI_COMMIT=0123456789012345678901234567890123456789
clio_validate_release_environment
if (DEVELOPER_TEAM_ID=OTHER clio_validate_release_environment) 2>/dev/null; then clio_die "wrong team accepted"; fi
if (NOTARY_PRIVATE_KEY=invalid clio_validate_release_environment) 2>/dev/null; then clio_die "invalid PEM envelope accepted"; fi
if (CI_COMMIT=invalid clio_validate_release_environment) 2>/dev/null; then clio_die "invalid commit accepted"; fi
if (DEVELOPER_ID_CERT_P12='!!!' clio_validate_release_environment) 2>/dev/null; then clio_die "invalid Base64 accepted"; fi
if (EXPECTED_CLOUD_TEAM_ID= clio_validate_release_environment) 2>/dev/null; then clio_die "missing Cloud configuration accepted"; fi
if (CI_TEAM_ID=11111111-1111-1111-1111-111111111111 clio_validate_release_environment) 2>/dev/null; then clio_die "wrong Cloud team accepted"; fi
echo "Cloud release preflight checks passed (14 cases)."
