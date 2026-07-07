#!/usr/bin/env bash

set -euo pipefail

script_project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project_root=$(cd "${CILIUM_PROJECT_ROOT:-${script_project_root}}" && pwd)
updater_root=$(cd "${CILIUM_UPDATER_ROOT:-${script_project_root}}" && pwd)
prompt_file="${updater_root}/cilium/tools/prompts/cilium-upgrade-e2e-repair.md"
failed_log_file="${CILIUM_E2E_FAILED_LOG:-/tmp/cilium-e2e-failed.log}"
repair_summary_file="${CILIUM_E2E_REPAIR_SUMMARY:-/tmp/cilium-e2e-repair-summary.md}"
ai_output=$(mktemp)

cleanup() {
    rm -f "${ai_output}" "${baseline_diff:-}" "${current_diff:-}" \
        "${baseline_status:-}" "${current_status:-}"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: cilium/tools/run-cilium-e2e-repair.sh

Runs an AI-assisted repair pass for a failed Cilium upgrade e2e workflow.
This script only modifies the current worktree. The caller is responsible for
reviewing, committing, and pushing any changes.

Environment:
  CILIUM_E2E_FAILED_LOG       Failed GitHub Actions log path. Defaults to
                              /tmp/cilium-e2e-failed.log.
  CILIUM_E2E_REPAIR_SUMMARY   Output summary path. Defaults to
                              /tmp/cilium-e2e-repair-summary.md.
  CILIUM_E2E_PR_NUMBER        Pull request number for context.
  CILIUM_E2E_RUN_URL          Failed workflow run URL for context.
  COPILOT_GITHUB_TOKEN        Copilot CLI credential.
  COPILOT_MODEL               Optional model name passed to copilot.
  DEEPSEEK_API_KEY            DeepSeek API key used by `opencode run`.
  DEEPSEEK_MODEL              Optional opencode model name.
  AI_MODEL                    Optional fallback model name.
  AI_AGENT_TIMEOUT            Maximum runtime for each AI CLI attempt.
                              Defaults to 20m.
  AI_AGENT_MAX_ATTEMPTS       Maximum attempts per AI CLI. Defaults to 2.
  CILIUM_E2E_REPAIR_ALLOW_DIRTY
                              Set to "true" when the worktree already contains
                              the initial AI upgrade diff.
  CILIUM_PROJECT_ROOT         Repository worktree to modify.
  CILIUM_UPDATER_ROOT         Repository containing prompts.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

for command in git sed timeout; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Missing required command: ${command}" >&2
        exit 1
    fi
done

cd "${project_root}"

if [[ ! -f "${prompt_file}" ]]; then
    echo "Missing repair prompt: ${prompt_file}" >&2
    exit 1
fi

if [[ ! -s "${failed_log_file}" ]]; then
    echo "Missing failed e2e log: ${failed_log_file}" >&2
    exit 1
fi

allow_dirty=${CILIUM_E2E_REPAIR_ALLOW_DIRTY:-false}
baseline_diff=$(mktemp)
current_diff=$(mktemp)
baseline_status=$(mktemp)
current_status=$(mktemp)

if [[ "${allow_dirty}" != "true" ]] && [[ -n "$(git status --porcelain)" ]]; then
    echo "The repair worktree must be clean before AI changes are applied." >&2
    git status --short >&2
    exit 1
fi

git diff --binary > "${baseline_diff}"
git status --short > "${baseline_status}"

agent_order=(copilot deepseek)
agent_timeout=${AI_AGENT_TIMEOUT:-20m}
agent_max_attempts=${AI_AGENT_MAX_ATTEMPTS:-2}
success_agent=""

if ! [[ "${agent_max_attempts}" =~ ^[0-9]+$ ]] || [[ "${agent_max_attempts}" -lt 1 ]]; then
    echo "AI_AGENT_MAX_ATTEMPTS must be a positive integer; got '${AI_AGENT_MAX_ATTEMPTS}'." >&2
    exit 1
fi

credential_for() {
    case "$1" in
        copilot) printf '%s' "${COPILOT_GITHUB_TOKEN:-}" ;;
        deepseek) printf '%s' "${DEEPSEEK_API_KEY:-}" ;;
    esac
}

model_for() {
    case "$1" in
        copilot)  printf '%s' "${COPILOT_MODEL:-${AI_MODEL:-}}" ;;
        deepseek) printf '%s' "${DEEPSEEK_MODEL:-${AI_MODEL:-deepseek/deepseek-v4-flash}}" ;;
    esac
}

credential_usable_for() {
    local agent="$1"
    local credential
    credential=$(credential_for "${agent}")

    case "${agent}" in
        copilot)
            if [[ "${credential}" == ghp_* ]]; then
                echo "Skipping ${agent}: COPILOT_GITHUB_TOKEN is a classic PAT (ghp_), which Copilot CLI does not support." >&2
                return 1
            fi
            ;;
    esac
    return 0
}

reset_worktree() {
    if [[ "${allow_dirty}" == "true" ]]; then
        echo "Keeping dirty baseline worktree; not resetting initial upgrade files." >&2
    else
        git checkout -- cilium test README.md Makefile Makefile.defs 2>/dev/null || true
        git clean -fd -- cilium test README.md Makefile Makefile.defs 2>/dev/null || true
    fi
    rm -f "${repair_summary_file}"
}

print_ai_output() {
    local agent="$1"

    if [[ ! -s "${ai_output}" ]]; then
        echo "${agent} produced no CLI stderr output." >&2
        return 0
    fi

    echo "::group::${agent} CLI output" >&2
    sed -n '1,240p' "${ai_output}" >&2
    if [[ "$(wc -l < "${ai_output}")" -gt 240 ]]; then
        echo "... output truncated; showing first 240 lines" >&2
    fi
    echo "::endgroup::" >&2
}

allowed_changes_only() {
    local invalid_paths
    invalid_paths=$(
        git status --short |
            sed 's/^...//' |
            grep -Ev '^(cilium/|test/|README\.md$|Makefile$|Makefile\.defs$)' || true
    )
    if [[ -n "${invalid_paths}" ]]; then
        echo "AI repair changed paths outside the allowed scope:" >&2
        echo "${invalid_paths}" >&2
        return 1
    fi
}

has_new_repair_changes() {
    git diff --binary > "${current_diff}"
    git status --short > "${current_status}"
    ! cmp -s "${baseline_diff}" "${current_diff}" ||
        ! cmp -s "${baseline_status}" "${current_status}"
}

run_static_validation() {
    make prepare
    make ci-validate
}

run_single_agent() {
    local agent="$1"
    local credential
    local model
    local -a model_args=()
    local branch
    local run_url
    local pr_number
    local prompt

    credential=$(credential_for "${agent}")
    [[ -n "${credential}" ]] || return 1

    model=$(model_for "${agent}")
    [[ -z "${model}" ]] || model_args=(--model "${model}")

    branch=$(git branch --show-current)
    run_url=${CILIUM_E2E_RUN_URL:-unknown}
    pr_number=${CILIUM_E2E_PR_NUMBER:-unknown}
    prompt="Read and follow ${prompt_file}. The failed e2e log is ${failed_log_file}. PR number: ${pr_number}. Workflow run: ${run_url}. Current branch: ${branch}. Analyze the failed log, make the smallest safe repair in this working tree, run relevant validation if possible, and write a Chinese repair summary to ${repair_summary_file}. The summary must explicitly list every manually changed parameter or script behavior, explain what each change does, and explain why it allowed e2e to pass. If no extra parameter was changed, say so explicitly. Do not commit or push; the workflow will do that after validation."

    case "${agent}" in
        copilot)
            COPILOT_GITHUB_TOKEN="${credential}" \
            timeout --foreground "${agent_timeout}" \
            copilot \
                --prompt "${prompt}" \
                --allow-all \
                --no-ask-user \
                --no-auto-update \
                --silent \
                --output-format text \
                "${model_args[@]}" \
                > "${repair_summary_file}" 2> "${ai_output}"
            ;;
        deepseek)
            DEEPSEEK_API_KEY="${credential}" \
            timeout --foreground "${agent_timeout}" \
            opencode run \
                --dir "${project_root}" \
                --dangerously-skip-permissions \
                --variant high \
                "${model_args[@]}" \
                "${prompt}" \
                > "${repair_summary_file}" 2> "${ai_output}"
            ;;
    esac
}

for agent in "${agent_order[@]}"; do
    if [[ -z "$(credential_for "${agent}")" ]]; then
        echo "Skipping ${agent}: no credential configured."
        continue
    fi
    if ! credential_usable_for "${agent}"; then
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

    echo "Attempting Cilium e2e repair with ${agent} (up to ${agent_max_attempts} attempt(s))..."
    for attempt in $(seq 1 "${agent_max_attempts}"); do
        echo "--- ${agent} repair attempt ${attempt}/${agent_max_attempts} ---"
        agent_status=0
        if run_single_agent "${agent}"; then
            agent_status=0
        else
            agent_status=$?
        fi

        if allowed_changes_only && has_new_repair_changes; then
            if run_static_validation; then
                success_agent="${agent}"
                if [[ "${agent_status}" -ne 0 ]]; then
                    echo "${agent} returned exit status ${agent_status}, but produced a valid repair; accepting result." >&2
                fi
                break 2
            fi
        else
            echo "${agent} did not produce repair changes." >&2
        fi

        print_ai_output "${agent}"
        if [[ "${attempt}" -lt "${agent_max_attempts}" ]]; then
            reset_worktree
        fi
    done
    if [[ -z "${success_agent}" ]]; then
        reset_worktree
    fi
done

if [[ -z "${success_agent}" ]]; then
    echo "All AI repair agents failed, were unavailable, or produced no valid repair." >&2
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "changed=false" >> "${GITHUB_OUTPUT}"
    fi
    exit 1
fi

if [[ ! -s "${repair_summary_file}" ]]; then
    cat > "${repair_summary_file}" <<EOF
### 修复

${success_agent} 生成了 e2e 修复变更，并通过了 \`make prepare\` 和 \`make ci-validate\`。
EOF
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "changed=true"
        echo "agent=${success_agent}"
        echo "summary_path=${repair_summary_file}"
    } >> "${GITHUB_OUTPUT}"
fi

echo "Cilium e2e repair changes are ready."
git status --short
