#!/usr/bin/env bash

set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
context_file="${project_root}/cilium/tools/cilium-upgrade-context.md"
api_url="https://api.github.com/repos/cilium/cilium/releases?per_page=100"

# The current Cilium version is provided by the caller (the workflow sources
# cilium/version.sh and exports CURRENT_CILIUM_VERSION). This keeps the
# script a pure function of its inputs and avoids re-reading version.sh.
current_version="${CURRENT_CILIUM_VERSION:-}"

if [[ ! "${current_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "CURRENT_CILIUM_VERSION must be set to a stable x.y.z version" >&2
    exit 1
fi

headers=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

releases_json=$(mktemp)
trap 'rm -f "${releases_json}"' EXIT
curl --fail --silent --show-error --location "${headers[@]}" "${api_url}" > "${releases_json}"

mapfile -t stable_versions < <(
    jq -r '
        .[]
        | select(.draft == false and .prerelease == false)
        | .tag_name
        | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | sub("^v"; "")
    ' "${releases_json}" | sort -V
)

if [[ ${#stable_versions[@]} -eq 0 ]]; then
    echo "GitHub returned no stable semantic Cilium releases" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Target version selection strategy:
#
# Given the current version x.y.z, among all stable releases newer than
# x.y.z:
#
#   1. Same-minor patches: if there are higher patches within the same x.y
#      minor (e.g. x.y.(z+1)), pick the highest one.  Patch releases are
#      bugfix-only and always safe, regardless of patch number.
#
#   2. Cross-minor jump: if no same-minor patch exists, look at every newer
#      minor series (x.(y+1), x.(y+2), ...) in ascending order.  For each,
#      check whether it has a patch >= CILIUM_MIN_STABLE_PATCH (default 2).
#      The first minor series that qualifies is selected, and its highest
#      qualifying patch is chosen.  Minors that only have early patches
#      (.0, .1) are skipped entirely as they are considered unstable.
#
#   3. If no newer minor has a sufficiently stable patch, do not upgrade.
#
# CILIUM_MIN_STABLE_PATCH can be overridden via environment variable or
# repository variable (default: 2).
# ---------------------------------------------------------------------------

min_stable_patch=${CILIUM_MIN_STABLE_PATCH:-2}

current_major_minor=$(printf '%s' "${current_version}" | cut -d. -f1-2)

# Collect all stable versions strictly newer than current_version.
newer_versions=()
for v in "${stable_versions[@]}"; do
    newest=$(printf '%s\n%s\n' "${current_version}" "${v}" | sort -V | tail -n 1)
    if [[ "${v}" != "${current_version}" && "${newest}" == "${v}" ]]; then
        newer_versions+=("${v}")
    fi
done

latest_version="${current_version}"  # default: no upgrade

if [[ ${#newer_versions[@]} -gt 0 ]]; then
    # Step 1: same-minor patches — always safe, pick the highest.
    same_minor_patches=()
    for v in "${newer_versions[@]}"; do
        if [[ "$(printf '%s' "${v}" | cut -d. -f1-2)" == "${current_major_minor}" ]]; then
            same_minor_patches+=("${v}")
        fi
    done

    if [[ ${#same_minor_patches[@]} -gt 0 ]]; then
        latest_version=$(printf '%s\n' "${same_minor_patches[@]}" | sort -V | tail -n 1)
    else
        # Step 2: cross-minor jump — collect distinct newer minors in
        # ascending order and find the first one with a stable-enough patch.
        declare -A seen_minor=()
        newer_minors=()
        for v in "${newer_versions[@]}"; do
            v_minor=$(printf '%s' "${v}" | cut -d. -f1-2)
            v_minor_newest=$(printf '%s\n%s\n' "${current_major_minor}" "${v_minor}" | sort -V | tail -n 1)
            if [[ "${v_minor}" != "${current_major_minor}" \
                  && "${v_minor_newest}" == "${v_minor}" \
                  && -z "${seen_minor[${v_minor}]:-}" ]]; then
                newer_minors+=("${v_minor}")
                seen_minor[${v_minor}]=1
            fi
        done
        # Sort minors ascending so we pick the closest qualifying one.
        mapfile -t sorted_minors < <(printf '%s\n' "${newer_minors[@]}" | sort -V)

        for target_minor in "${sorted_minors[@]}"; do
            # Collect patches in this minor that are >= min_stable_patch.
            qualifying_patches=()
            for v in "${newer_versions[@]}"; do
                if [[ "$(printf '%s' "${v}" | cut -d. -f1-2)" == "${target_minor}" ]]; then
                    patch_num=$(printf '%s' "${v}" | cut -d. -f3)
                    if [[ "${patch_num}" -ge "${min_stable_patch}" ]]; then
                        qualifying_patches+=("${v}")
                    fi
                fi
            done
            if [[ ${#qualifying_patches[@]} -gt 0 ]]; then
                latest_version=$(printf '%s\n' "${qualifying_patches[@]}" | sort -V | tail -n 1)
                break
            fi
        done
        # If no minor qualified, latest_version stays as current_version
        # (no upgrade).
    fi
fi

latest_tag="v${latest_version}"
release_url=$(
    jq -r --arg tag "${latest_tag}" '.[] | select(.tag_name == $tag) | .html_url' "${releases_json}"
)
published_at=$(
    jq -r --arg tag "${latest_tag}" '.[] | select(.tag_name == $tag) | .published_at' "${releases_json}"
)

if [[ ! "${latest_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Latest upstream release tag is not a stable semantic version: ${latest_tag}" >&2
    exit 1
fi

needs_update=false
if [[ "${latest_version}" != "${current_version}" ]]; then
    needs_update=true
fi

{
    echo "# Cilium upgrade context"
    echo
    echo "- Current project version: \`${current_version}\`"
    echo "- Target upstream version: \`${latest_version}\`"
    echo "- Release URL: ${release_url}"
    echo "- Published at: ${published_at}"
    echo "- Upgrade required: \`${needs_update}\`"
    echo
    echo "## Upstream release notes in the upgrade range"
    echo
    for version in "${stable_versions[@]}"; do
        newest_range_version=$(
            printf '%s\n%s\n' "${current_version}" "${version}" | sort -V | tail -n 1
        )
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
            jq -r --arg tag "${tag}" '.[] | select(.tag_name == $tag) | .html_url' "${releases_json}"
        )
        echo "### ${tag}"
        echo
        echo "Source: ${note_url}"
        echo
        jq -r --arg tag "${tag}" \
            '.[] | select(.tag_name == $tag) | (.body // "No release notes were provided.")' \
            "${releases_json}"
        echo
    done
} > "${context_file}"

# Always print results to stdout so the caller (run-cilium-upgrade.sh or a
# workflow step) can parse them with sed/jq. Never write to GITHUB_OUTPUT
# here — the caller owns that decision.
printf 'current_version=%s\nlatest_version=%s\nlatest_tag=%s\nrelease_url=%s\nneeds_update=%s\n' \
    "${current_version}" "${latest_version}" "${latest_tag}" "${release_url}" "${needs_update}"
