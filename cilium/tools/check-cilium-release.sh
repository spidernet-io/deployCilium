#!/usr/bin/env bash

set -euo pipefail

script_project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project_root=$(cd "${CILIUM_PROJECT_ROOT:-${script_project_root}}" && pwd)
context_file="${project_root}/cilium/tools/cilium-upgrade-context.md"
cilium_api_url="https://api.github.com/repos/cilium/cilium/releases?per_page=100"
hubble_api_url="https://api.github.com/repos/cilium/hubble/releases?per_page=100"
CILIUM_ROOT="${project_root}/cilium"
source "${CILIUM_ROOT}/env.sh"
version_file="${CILIUM_VERSION_FILE}"

# The current Cilium version is provided by the caller (the workflow sources
# cilium/versions/<minor>/version.sh and exports CURRENT_CILIUM_VERSION). This keeps the
# script a pure function of its inputs and avoids re-reading version.sh.
current_version="${CURRENT_CILIUM_VERSION:-${CILIUM_VERSION:-}}"
current_hubble_version="${CURRENT_HUBBLE_CLI_VERSION:-${HUBBLE_CLI_VERSION:-}}"
target_minor="${CILIUM_TARGET_MINOR:-}"

if [[ ! "${current_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "CURRENT_CILIUM_VERSION must be set to a stable x.y.z version" >&2
    exit 1
fi

if [[ -z "${current_hubble_version}" ]]; then
    current_hubble_version=$(
        sed -n 's/^[[:space:]]*HUBBLE_CLI_VERSION=${HUBBLE_CLI_VERSION:-"\([^"]*\)"}.*/\1/p' "${version_file}" |
            sed 's/^v//'
    )
else
    current_hubble_version="${current_hubble_version#v}"
fi

if [[ ! "${current_hubble_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "CURRENT_HUBBLE_CLI_VERSION must be a stable vX.Y.Z or X.Y.Z version when provided" >&2
    exit 1
fi

current_major_minor=$(printf '%s' "${current_version}" | cut -d. -f1-2)

infer_target_minor_from_ref() {
    local ref

    for ref in \
        "${GITHUB_HEAD_REF:-}" \
        "${GITHUB_REF_NAME:-}" \
        "$(git -C "${project_root}" branch --show-current 2>/dev/null || true)"
    do
        if [[ "${ref}" =~ (^|/)cilium/v([0-9]+\.[0-9]+)$ ]]; then
            printf '%s' "${BASH_REMATCH[2]}"
            return 0
        fi
    done
}

if [[ -z "${target_minor}" ]]; then
    target_minor="$(infer_target_minor_from_ref)"
fi

if [[ -z "${target_minor}" ]]; then
    target_minor="${current_major_minor}"
fi

if [[ ! "${target_minor}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "CILIUM_TARGET_MINOR must be set to a stable x.y minor when provided" >&2
    exit 1
fi

if [[ "${target_minor}" != "${current_major_minor}" ]]; then
    newest_minor=$(printf '%s\n%s\n' "${current_major_minor}" "${target_minor}" | sort -V | tail -n 1)
    if [[ "${newest_minor}" != "${target_minor}" ]]; then
        echo "Target minor ${target_minor} is older than current version minor ${current_major_minor}" >&2
        exit 1
    fi
fi

headers=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

cilium_releases_json=$(mktemp)
hubble_releases_json=$(mktemp)
trap 'rm -f "${cilium_releases_json}" "${hubble_releases_json}"' EXIT
curl --fail --silent --show-error --location "${headers[@]}" "${cilium_api_url}" > "${cilium_releases_json}"
curl --fail --silent --show-error --location "${headers[@]}" "${hubble_api_url}" > "${hubble_releases_json}"

mapfile -t stable_versions < <(
    jq -r '
        .[]
        | select(.draft == false and .prerelease == false)
        | .tag_name
        | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | sub("^v"; "")
    ' "${cilium_releases_json}" | sort -V
)

mapfile -t stable_hubble_versions < <(
    jq -r '
        .[]
        | select(.draft == false and .prerelease == false)
        | select(any(.assets[]?; .name == "hubble-linux-amd64.tar.gz"))
        | .tag_name
        | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | sub("^v"; "")
    ' "${hubble_releases_json}" | sort -V
)

if [[ ${#stable_versions[@]} -eq 0 ]]; then
    echo "GitHub returned no stable semantic Cilium releases" >&2
    exit 1
fi

if [[ ${#stable_hubble_versions[@]} -eq 0 ]]; then
    echo "GitHub returned no stable semantic Hubble releases with hubble-linux-amd64.tar.gz" >&2
    exit 1
fi

# Each version directory owns exactly one Cilium minor series. Select the newest
# stable patch in that target minor and never cross into another minor.
target_minor_versions=()
for v in "${stable_versions[@]}"; do
    if [[ "$(printf '%s' "${v}" | cut -d. -f1-2)" == "${target_minor}" ]]; then
        target_minor_versions+=("${v}")
    fi
done

if [[ ${#target_minor_versions[@]} -eq 0 ]]; then
    echo "No stable Cilium releases found for target minor ${target_minor}" >&2
    exit 1
fi

latest_version=$(printf '%s\n' "${target_minor_versions[@]}" | sort -V | tail -n 1)

target_minor_hubble_versions=()
for v in "${stable_hubble_versions[@]}"; do
    if [[ "$(printf '%s' "${v}" | cut -d. -f1-2)" == "${target_minor}" ]]; then
        target_minor_hubble_versions+=("${v}")
    fi
done

if [[ ${#target_minor_hubble_versions[@]} -eq 0 ]]; then
    echo "No stable Hubble releases with hubble-linux-amd64.tar.gz found for target minor ${target_minor}" >&2
    exit 1
fi

latest_hubble_version=$(printf '%s\n' "${target_minor_hubble_versions[@]}" | sort -V | tail -n 1)

latest_tag="v${latest_version}"
release_url=$(
    jq -r --arg tag "${latest_tag}" '.[] | select(.tag_name == $tag) | .html_url' "${cilium_releases_json}"
)
published_at=$(
    jq -r --arg tag "${latest_tag}" '.[] | select(.tag_name == $tag) | .published_at' "${cilium_releases_json}"
)
hubble_latest_tag="v${latest_hubble_version}"
hubble_release_url=$(
    jq -r --arg tag "${hubble_latest_tag}" '.[] | select(.tag_name == $tag) | .html_url' "${hubble_releases_json}"
)
hubble_download_url=$(
    jq -r --arg tag "${hubble_latest_tag}" '
        .[]
        | select(.tag_name == $tag)
        | .assets[]
        | select(.name == "hubble-linux-amd64.tar.gz")
        | .browser_download_url
    ' "${hubble_releases_json}"
)
hubble_published_at=$(
    jq -r --arg tag "${hubble_latest_tag}" '.[] | select(.tag_name == $tag) | .published_at' "${hubble_releases_json}"
)

if [[ ! "${latest_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Latest upstream release tag is not a stable semantic version: ${latest_tag}" >&2
    exit 1
fi

needs_update=false
if [[ "${latest_version}" != "${current_version}" || "${latest_hubble_version}" != "${current_hubble_version}" ]]; then
    needs_update=true
fi

{
    echo "# Cilium upgrade context"
    echo
    echo "- Current project version: \`${current_version}\`"
    echo "- Target minor: \`${target_minor}\`"
    echo "- Target upstream version: \`${latest_version}\`"
    echo "- Release URL: ${release_url}"
    echo "- Published at: ${published_at}"
    echo "- Current Hubble CLI version: \`v${current_hubble_version}\`"
    echo "- Target Hubble CLI version: \`v${latest_hubble_version}\`"
    echo "- Hubble release URL: ${hubble_release_url}"
    echo "- Hubble download URL: ${hubble_download_url}"
    echo "- Hubble published at: ${hubble_published_at}"
    echo "- Upgrade required: \`${needs_update}\`"
    echo
    echo "## Upstream release notes in the upgrade range"
    echo
    for version in "${stable_versions[@]}"; do
        if [[ "$(printf '%s' "${version}" | cut -d. -f1-2)" != "${target_minor}" ]]; then
            continue
        fi

        newest_range_version=$(printf '%s\n%s\n' "${current_version}" "${version}" | sort -V | tail -n 1)
        if [[ "${version}" == "${current_version}" || "${newest_range_version}" != "${version}" ]]; then
            continue
        fi
        # Exclude versions beyond the selected target so the release-note
        # range matches the actual upgrade path.
        target_newest=$(printf '%s\n%s\n' "${latest_version}" "${version}" | sort -V | tail -n 1)
        if [[ "${target_newest}" != "${latest_version}" ]]; then
            continue
        fi

        tag="v${version}"
        note_url=$(
            jq -r --arg tag "${tag}" '.[] | select(.tag_name == $tag) | .html_url' "${cilium_releases_json}"
        )
        echo "### ${tag}"
        echo
        echo "Source: ${note_url}"
        echo
        jq -r --arg tag "${tag}" \
            '.[] | select(.tag_name == $tag) | (.body // "No release notes were provided.")' \
            "${cilium_releases_json}"
        echo
    done
} > "${context_file}"

# Always print results to stdout so the caller (run-cilium-upgrade.sh or a
# workflow step) can parse them with sed/jq. Never write to GITHUB_OUTPUT
# here — the caller owns that decision.
printf 'current_version=%s\ntarget_minor=%s\nlatest_version=%s\nlatest_tag=%s\nrelease_url=%s\ncurrent_hubble_version=%s\nlatest_hubble_version=%s\nlatest_hubble_tag=%s\nhubble_release_url=%s\nhubble_download_url=%s\nneeds_update=%s\n' \
    "${current_version}" "${target_minor}" "${latest_version}" "${latest_tag}" "${release_url}" \
    "${current_hubble_version}" "${latest_hubble_version}" "${hubble_latest_tag}" "${hubble_release_url}" \
    "${hubble_download_url}" "${needs_update}"
