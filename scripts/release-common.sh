#!/bin/bash

# Shared, side-effect-free helpers for Clio's local release tooling.
# Keep this file compatible with the Bash 3.2 shipped by macOS.

clio_die() {
    echo "error: $*" >&2
    exit 1
}

clio_require_command() {
    command -v "$1" >/dev/null 2>&1 || clio_die "required command is unavailable: $1"
}

clio_sha256() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

clio_normalized_architectures() {
    lipo -archs "$1" \
        | tr ' ' '\n' \
        | sed '/^$/d' \
        | LC_ALL=C sort \
        | paste -sd ' ' -
}

clio_resolved_revision() {
    local package_file="$1"
    local expected_identity="$2"
    local index=0
    local identity
    local revision

    while identity="$(
        plutil -extract "pins.${index}.identity" raw "${package_file}" 2>/dev/null
    )"; do
        if [[ "${identity}" == "${expected_identity}" ]]; then
            revision="$(
                plutil -extract "pins.${index}.state.revision" raw "${package_file}" 2>/dev/null
            )" || return 1
            printf '%s\n' "${revision}"
            return 0
        fi
        index=$((index + 1))
    done

    return 1
}

clio_require_exact_package_lock() {
    local package_file="$1"
    local expected_markdown_revision="3c6f9523da3a1ec2fd829673e472d95b8097a3b8"
    local expected_cmark_revision="924936d0427cb25a61169739a7660230bffa6ea6"
    local lock_version
    local pin_count
    local index
    local identity
    local kind
    local location
    local revision
    local saw_markdown=0
    local saw_cmark=0

    [[ -f "${package_file}" && ! -L "${package_file}" ]] \
        || clio_die "Package.resolved is missing or is a symlink: ${package_file}"
    lock_version="$(plutil -extract version raw "${package_file}" 2>/dev/null)" \
        || clio_die "Package.resolved is missing its schema version"
    pin_count="$(plutil -extract pins raw "${package_file}" 2>/dev/null)" \
        || clio_die "Package.resolved is missing its pins"
    [[ "${lock_version}" == "3" ]] \
        || clio_die "Package.resolved must use schema version 3, found ${lock_version}"
    [[ "${pin_count}" == "2" ]] \
        || clio_die "Package.resolved must contain exactly two pins, found ${pin_count}"

    for index in 0 1; do
        identity="$(plutil -extract "pins.${index}.identity" raw "${package_file}" 2>/dev/null)" \
            || clio_die "Package.resolved pin ${index} has no identity"
        kind="$(plutil -extract "pins.${index}.kind" raw "${package_file}" 2>/dev/null)" \
            || clio_die "Package.resolved pin ${identity} has no kind"
        location="$(plutil -extract "pins.${index}.location" raw "${package_file}" 2>/dev/null)" \
            || clio_die "Package.resolved pin ${identity} has no location"
        revision="$(plutil -extract "pins.${index}.state.revision" raw "${package_file}" 2>/dev/null)" \
            || clio_die "Package.resolved pin ${identity} has no revision"
        [[ "${kind}" == "remoteSourceControl" ]] \
            || clio_die "Package.resolved pin ${identity} has unexpected kind ${kind}"

        case "${identity}" in
            swift-markdown)
                [[ "${saw_markdown}" -eq 0 ]] \
                    || clio_die "Package.resolved contains duplicate swift-markdown pins"
                [[ "${location}" == "https://github.com/swiftlang/swift-markdown.git" ]] \
                    || clio_die "swift-markdown is locked to an unexpected source: ${location}"
                [[ "${revision}" == "${expected_markdown_revision}" ]] \
                    || clio_die "unexpected swift-markdown revision ${revision}"
                saw_markdown=1
                ;;
            swift-cmark)
                [[ "${saw_cmark}" -eq 0 ]] \
                    || clio_die "Package.resolved contains duplicate swift-cmark pins"
                [[ "${location}" == "https://github.com/swiftlang/swift-cmark.git" ]] \
                    || clio_die "swift-cmark is locked to an unexpected source: ${location}"
                [[ "${revision}" == "${expected_cmark_revision}" ]] \
                    || clio_die "unexpected swift-cmark revision ${revision}"
                saw_cmark=1
                ;;
            *)
                clio_die "Package.resolved contains unexpected dependency ${identity}"
                ;;
        esac
    done

    [[ "${saw_markdown}" -eq 1 && "${saw_cmark}" -eq 1 ]] \
        || clio_die "Package.resolved does not contain both required dependency pins"
}

clio_plist_value() {
    local plist="$1"
    local key_path="$2"
    /usr/libexec/PlistBuddy -c "Print :${key_path}" "${plist}"
}

clio_require_safe_basename() {
    local value="$1"
    [[ -n "${value}" ]] || clio_die "manifest contains an empty artifact name"
    [[ "${value}" == "$(basename "${value}")" ]] \
        || clio_die "manifest artifact name is not a basename: ${value}"
    [[ "${value}" != "." && "${value}" != ".." ]] \
        || clio_die "manifest artifact name is unsafe: ${value}"
}

clio_detach_mount() {
    local mount_path="$1"
    local attempt

    for attempt in 1 2 3; do
        if hdiutil detach "${mount_path}" -quiet >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "warning: could not detach ${mount_path}; detach it manually with hdiutil" >&2
    return 1
}
