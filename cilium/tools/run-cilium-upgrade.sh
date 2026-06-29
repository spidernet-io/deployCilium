#!/usr/bin/env bash

set -euo pipefail

script_project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project_root=$(cd "${CILIUM_PROJECT_ROOT:-${script_project_root}}" && pwd)
updater_root=$(cd "${CILIUM_UPDATER_ROOT:-${script_project_root}}" && pwd)
release_script="${updater_root}/cilium/tools/check-cilium-release.sh"
context_file="${project_root}/cilium/tools/cilium-upgrade-context.md"
prompt_file="${updater_root}/cilium/tools/prompts/cilium-upgrade.md"
version_file="${project_root}/cilium/version.sh"
pr_body_file=${CILIUM_UPGRADE_PR_BODY:-"/tmp/cilium-upgrade-pr.md"}
check_only=false

# Current Cilium version: prefer the value supplied by the workflow (which
# sources cilium/version.sh). Fall back to reading version.sh directly so
# the script remains usable for local manual runs.
if [[ -z "${CURRENT_CILIUM_VERSION:-}" ]]; then
    CURRENT_CILIUM_VERSION=$(
        sed -n 's/^[[:space:]]*CILIUM_VERSION=${CILIUM_VERSION:-"\([^"]*\)"}.*/\1/p' "${version_file}"
    )
fi
export CURRENT_CILIUM_VERSION

usage() {
    cat <<'EOF'
Usage: cilium/tools/run-cilium-upgrade.sh [--check-only]

The script tries each AI CLI in priority order until one succeeds:
  1. copilot  (requires COPILOT_GITHUB_TOKEN)
  2. deepseek (requires DEEPSEEK_API_KEY and opencode)

Environment:
  CURRENT_CILIUM_VERSION   Current pinned Cilium version (x.y.z). When set,
                           it is forwarded to check-cilium-release.sh. When
                           unset, the script reads cilium/version.sh itself.
  CILIUM_TARGET_MINOR       Target Cilium minor (x.y). Defaults to the current
                            version's minor. Maintenance branches should set
                            this from their branch name, e.g. cilium/v1.18.
  COPILOT_GITHUB_TOKEN      Copilot credential (fine-grained PAT with
                            "Copilot Requests" permission).
  COPILOT_MODEL             Optional model name passed to copilot.
  DEEPSEEK_API_KEY          DeepSeek API key used by `opencode run`.
  DEEPSEEK_MODEL            Optional opencode model name. Defaults to
                            deepseek/deepseek-v4-flash.
  AI_MODEL                  Optional fallback model name when an agent-specific
                            model variable is unset.
  AI_AGENT_TIMEOUT          Maximum runtime for each AI CLI attempt. Defaults
                            to 15m. Uses GNU timeout duration syntax.
  GITHUB_TOKEN              Optional GitHub API token for release queries.
  CILIUM_UPGRADE_PR_BODY    Optional PR body path.
  CILIUM_UPGRADE_ALLOW_DIRTY
                            Set to "true" only if existing changes are safe.
  CILIUM_UPGRADE_SKIP_VALIDATION
                            Set to "true" to skip make validation locally.
  CILIUM_PROJECT_ROOT        Repository worktree to modify. Defaults to the
                            repository containing this script.
  CILIUM_UPDATER_ROOT        Repository containing updater scripts/prompts.
                            Defaults to the repository containing this script.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)
            check_only=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

required_commands=(curl git jq sed sort)
if [[ "${check_only}" != "true" ]]; then
    required_commands+=(make timeout)
fi

for command in "${required_commands[@]}"; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

cd "${project_root}"

case "${pr_body_file}" in
    "${project_root}"/*)
        echo "CILIUM_UPGRADE_PR_BODY must point outside the repository." >&2
        exit 1
        ;;
esac

for file in "${release_script}" "${prompt_file}" "${version_file}"; do
    if [[ ! -f "${file}" ]]; then
        echo "Missing required updater file: ${file}" >&2
        exit 1
    fi
done

if [[ "${CILIUM_UPGRADE_ALLOW_DIRTY:-false}" != "true" ]] &&
    [[ -n "$(git status --porcelain)" ]]; then
    echo "The worktree must be clean before an automated upgrade." >&2
    echo "Commit or stash existing changes, or explicitly set CILIUM_UPGRADE_ALLOW_DIRTY=true." >&2
    exit 1
fi

release_output=$(mktemp)
ai_output=$(mktemp)
cleanup() {
    rm -f "${release_output}" "${ai_output}" "${context_file}"
}
trap cleanup EXIT

"${release_script}" | tee "${release_output}"

current_version=$(sed -n 's/^current_version=//p' "${release_output}")
target_minor=$(sed -n 's/^target_minor=//p' "${release_output}")
latest_version=$(sed -n 's/^latest_version=//p' "${release_output}")
release_url=$(sed -n 's/^release_url=//p' "${release_output}")
current_hubble_version=$(sed -n 's/^current_hubble_version=//p' "${release_output}")
latest_hubble_version=$(sed -n 's/^latest_hubble_version=//p' "${release_output}")
needs_update=$(sed -n 's/^needs_update=//p' "${release_output}")

if [[ "${needs_update}" != "true" ]]; then
    echo "Cilium ${current_version} and Hubble CLI v${current_hubble_version} are already the latest stable releases for ${target_minor}."
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "changed=false" >> "${GITHUB_OUTPUT}"
    fi
    exit 0
fi

echo "Cilium ${target_minor} upgrade available: ${current_version} -> ${latest_version}"
echo "Hubble CLI ${target_minor} target: v${current_hubble_version} -> v${latest_hubble_version}"
echo "Release: ${release_url}"

if [[ "${check_only}" == "true" ]]; then
    echo "Check-only mode: AI CLIs were not invoked."
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "current_version=${current_version}"
            echo "latest_version=${latest_version}"
            echo "current_hubble_version=${current_hubble_version}"
            echo "latest_hubble_version=${latest_hubble_version}"
            echo "release_url=${release_url}"
            echo "changed=false"
        } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
fi

agent_prompt="Read and follow ${prompt_file}. Read ${context_file} for the complete release-note range. Upgrade only the target Cilium minor recorded in that context; do not select a different Cilium minor. Modify this working tree and return only the required Markdown PR body. The complete PR body must be written in Chinese."

# Priority order: copilot -> deepseek.
agent_order=(copilot deepseek)
success_agent=""
agent_timeout=${AI_AGENT_TIMEOUT:-15m}

# Return the credential for a given agent, or empty if none is configured.
credential_for() {
    case "$1" in
        copilot) printf '%s' "${COPILOT_GITHUB_TOKEN:-}" ;;
        deepseek) printf '%s' "${DEEPSEEK_API_KEY:-}" ;;
    esac
}

# Return the model name for a given agent, or empty to use the CLI default.
model_for() {
    case "$1" in
        copilot)  printf '%s' "${COPILOT_MODEL:-${AI_MODEL:-}}" ;;
        deepseek) printf '%s' "${DEEPSEEK_MODEL:-${AI_MODEL:-deepseek/deepseek-v4-flash}}" ;;
    esac
}

# Reset the working tree to a clean state so a failed attempt does not pollute
# the next one. Only tracked files within the allowed scope are touched. The
# generated context file is preserved across retries via -e so the next agent
# can still read the upstream release notes.
reset_worktree() {
    git checkout -- cilium test README.md Makefile Makefile.defs 2>/dev/null || true
    git clean -fd -e cilium/tools/cilium-upgrade-context.md \
        -- cilium test README.md Makefile Makefile.defs 2>/dev/null || true
    rm -f "${pr_body_file}"
}

# Run a single AI CLI. Returns 0 on success, non-zero on failure.
# The PR body is written to ${pr_body_file}.
run_single_agent() {
    local agent="$1"
    local credential
    local model
    local -a model_args=()

    credential=$(credential_for "${agent}")
    [[ -n "${credential}" ]] || return 1

    model=$(model_for "${agent}")
    [[ -z "${model}" ]] || model_args=(--model "${model}")

    case "${agent}" in
        copilot)
            COPILOT_GITHUB_TOKEN="${credential}" \
            timeout --foreground "${agent_timeout}" \
            copilot \
                --prompt "${agent_prompt}" \
                --allow-all \
                --no-ask-user \
                --no-auto-update \
                --silent \
                --output-format text \
                "${model_args[@]}" \
                > "${pr_body_file}" 2> "${ai_output}"
            ;;
        deepseek)
            DEEPSEEK_API_KEY="${credential}" \
            timeout --foreground "${agent_timeout}" \
            opencode run \
                --dir "${project_root}" \
                --dangerously-skip-permissions \
                --variant high \
                "${model_args[@]}" \
                "${agent_prompt}" \
                > "${pr_body_file}" 2> "${ai_output}"
            ;;
    esac
}

print_ai_output() {
    local agent="$1"

    if [[ ! -s "${ai_output}" ]]; then
        echo "${agent} produced no CLI output." >&2
        return 0
    fi

    echo "::group::${agent} CLI output" >&2
    sed -n '1,240p' "${ai_output}" >&2
    if [[ "$(wc -l < "${ai_output}")" -gt 240 ]]; then
        echo "... output truncated; showing first 240 lines" >&2
    fi
    echo "::endgroup::" >&2
}

# Validate that the PR body contains every required section and that the
# working tree reflects a successful upgrade. Returns 0 on success.
validate_upgrade() {
    local agent="$1"

    for heading in \
        "### 摘要" \
        "### 已审阅的发布说明" \
        "### 配置和行为变更" \
        "### 验证" \
        "### 风险和审查重点"
    do
        grep -Fq "${heading}" "${pr_body_file}" || {
            echo "${agent} response is missing required PR section: ${heading}" >&2
            return 1
        }
    done

    local actual_version
    actual_version=$(
        sed -n 's/^[[:space:]]*CILIUM_VERSION=${CILIUM_VERSION:-"\([^"]*\)"}.*/\1/p' \
            cilium/version.sh
    )
    if [[ "${actual_version}" != "${latest_version}" ]]; then
        echo "${agent} did not pin Cilium ${latest_version}; found ${actual_version}." >&2
        return 1
    fi

    local actual_hubble_version
    actual_hubble_version=$(
        sed -n 's/^[[:space:]]*HUBBLE_CLI_VERSION=${HUBBLE_CLI_VERSION:-"\([^"]*\)"}.*/\1/p' \
            cilium/version.sh |
            sed 's/^v//'
    )
    if [[ "${actual_hubble_version}" != "${latest_hubble_version}" ]]; then
        echo "${agent} did not pin Hubble CLI v${latest_hubble_version}; found v${actual_hubble_version}." >&2
        return 1
    fi

    local invalid_paths
    invalid_paths=$(
        git status --short |
            sed 's/^...//' |
            grep -Ev '^(cilium/|test/|README\.md$|Makefile$|Makefile\.defs$)' || true
    )
    if [[ -n "${invalid_paths}" ]]; then
        echo "${agent} changed paths outside the allowed scope:" >&2
        echo "${invalid_paths}" >&2
        return 1
    fi

    if git diff --quiet && git diff --cached --quiet; then
        echo "${agent} produced no upgrade changes." >&2
        return 1
    fi

    return 0
}

for agent in "${agent_order[@]}"; do
    if [[ -z "$(credential_for "${agent}")" ]]; then
        echo "Skipping ${agent}: no credential configured."
        continue
    fi
    case "${agent}" in
        copilot)
            if ! command -v copilot >/dev/null 2>&1; then
                echo "Skipping ${agent}: CLI not installed."
                continue
            fi
            ;;
        deepseek)
            if ! command -v opencode >/dev/null 2>&1; then
                echo "Skipping ${agent}: opencode CLI not installed."
                continue
            fi
            ;;
    esac

    echo "Attempting Cilium upgrade with ${agent}..."
    echo "${agent} attempt timeout: ${agent_timeout}"
    if run_single_agent "${agent}" && validate_upgrade "${agent}"; then
        success_agent="${agent}"
        echo "${agent} completed the upgrade successfully."
        break
    fi

    print_ai_output "${agent}"
    echo "${agent} failed; resetting worktree before next attempt." >&2
    reset_worktree
done

rm -f "${context_file}"

if [[ -z "${success_agent}" ]]; then
    echo "All AI agents (copilot, deepseek) failed or were unavailable." >&2
    exit 1
fi

if [[ "${CILIUM_UPGRADE_SKIP_VALIDATION:-false}" != "true" ]]; then
    make prepare
    make ci-validate
    cat >> "${pr_body_file}" <<'EOF'

#### 自动化验证

- `make prepare`：通过
- `make ci-validate`：通过
- 完整 kind e2e：推迟到 PR 工作流执行
EOF
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "current_version=${current_version}"
        echo "target_minor=${target_minor}"
        echo "latest_version=${latest_version}"
        echo "current_hubble_version=${current_hubble_version}"
        echo "latest_hubble_version=${latest_hubble_version}"
        echo "release_url=${release_url}"
        echo "pr_body_path=${pr_body_file}"
        echo "changed=true"
    } >> "${GITHUB_OUTPUT}"
fi

echo
echo "Upgrade changes are ready in the working tree."
echo "PR body: ${pr_body_file}"
git status --short
