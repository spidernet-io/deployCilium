# Weekly Cilium updater

The `Weekly Cilium Upgrade` workflow runs every Monday at 02:23 UTC and can also be
started manually via `workflow_dispatch`. It compares `cilium/version.sh` with Cilium's latest stable
GitHub release. When an upgrade is available, the configured AI CLI reads the
upstream release notes and repository scripts, updates the project, validates
the result, and creates or updates `automation/cilium-latest`.

## Upgrade strategy

The updater uses a **prefer same-minor patch, stable cross-minor jump**
strategy when selecting the target version:

1. **Same-minor patches**: if there are higher patch releases within the
   current minor series (e.g. `1.18.6` → `1.18.9` when
   `1.18.7`/`1.18.8`/`1.18.9` exist), the highest same-minor patch is
   chosen. Patch releases are bugfix-only and always safe, regardless of
   patch number.
2. **Cross-minor jump**: if no same-minor patch exists, the updater looks
   at every newer minor series in ascending order. For each, it checks
   whether the highest available patch is >= `CILIUM_MIN_STABLE_PATCH`
   (default `2`). The first minor series that qualifies is selected, and
   its highest qualifying patch is chosen. Minors that only have early
   patches (`.0`, `.1`) are **skipped entirely** as they are considered
   unstable.
3. If no newer minor has a sufficiently stable patch, the updater does
   not upgrade and waits for a stable release.

The minimum stable patch threshold can be configured via the repository
variable `CILIUM_MIN_STABLE_PATCH` (default: `2`). For example, setting it
to `3` requires at least `x.y.3` before jumping to a new minor series.

Example scenarios (current version `1.18.6`, threshold `2`):

| Available releases | Target | Reason |
|---|---|---|
| `1.18.7`, `1.18.8`, `1.19.0` | `1.18.8` | Same-minor patch preferred |
| `1.19.0`, `1.19.1`, `1.19.2` | `1.19.2` | Next minor has `.2` (stable) |
| `1.19.0`, `1.19.1`, `1.20.0`, `1.20.1`, `1.20.2` | `1.20.2` | `1.19` only has `.0/.1` (unstable), skip to `1.20.2` |
| `1.19.0`, `1.19.1` | _(no upgrade)_ | No minor has a stable-enough patch |

## Duplicate PR handling

Before invoking any AI CLI, the workflow checks for existing open PRs on the
`automation/cilium-latest` branch:

- If an open PR already targets the **same** version, the run is skipped to
  avoid duplicate work.
- If an open PR targets a **lower** version, it is closed (with an explanatory
  comment and branch deletion) and the run proceeds to create a new PR for the
  higher version.

## Required repository secrets

The workflow tries each AI CLI in priority order until one succeeds:
**copilot → gemini → codex**. An agent is only attempted when its credential
secret is configured, so you can enable as many or as few fallbacks as you
like. At least one of the following must be set:

- `COPILOT_GITHUB_TOKEN`: fine-grained PAT with the "Copilot Requests"
  permission, belonging to an account with GitHub Copilot access.
- `GEMINI_API_KEY`: Gemini API key from Google AI Studio.
- `CODEX_API_KEY`: OpenAI API key consumed by `codex exec`. `OPENAI_API_KEY`
  is used as a fallback when `CODEX_API_KEY` is unset.

A separate secret is always required for PR creation:

- `CILIUM_UPDATE_TOKEN`: fine-grained PAT or GitHub App token with repository
  `Contents: Read and write` and `Pull requests: Read and write` permissions.

The workflow's default `GITHUB_TOKEN` is never used as the Copilot credential
or as the PR-creation token. Pull requests created with the default token do
not emit a new `pull_request` event, so `.github/workflows/pr.yaml` would not
start its e2e jobs. The dedicated token makes PR creation behave like a normal
user or app operation and automatically triggers those tests.

All three CLIs authenticate via environment variables, so no browser-based
OAuth flow is needed in CI:

| CLI      | Environment variable(s)                                  |
|----------|----------------------------------------------------------|
| copilot  | `COPILOT_GITHUB_TOKEN` (highest precedence), `GH_TOKEN`, `GITHUB_TOKEN` |
| gemini   | `GEMINI_API_KEY`                                         |
| codex    | `CODEX_API_KEY` (for `codex exec`), `OPENAI_API_KEY` as fallback |

Optional repository variables:

- `AI_MODEL`: model name passed to every CLI attempt. When omitted, each CLI
  uses its own default.
- `GEMINI_MODEL`: Gemini-specific model override, used when `AI_MODEL` is
  unset. Defaults to `auto` when both are unset.
- `CILIUM_MIN_STABLE_PATCH`: minimum patch number required before jumping to
  a new minor series (default: `2`). Set to `3` to require `x.y.3` before
  crossing minors. Does not affect same-minor patch upgrades.

The implementation prompt is maintained in
`cilium/tools/prompts/cilium-upgrade.md`. The workflow constrains generated
changes to deployment code, tests, and project documentation; GitHub Actions
changes must be reviewed and committed by a human.

## Local execution

Install one or more of the supported CLIs and export the matching credential(s).
The script tries copilot, then gemini, then codex, and uses the first one that
both has a credential and succeeds:

```bash
npm install --global @github/copilot@latest
npm install --global @google/gemini-cli@latest
npm install --global @openai/codex@latest

export COPILOT_GITHUB_TOKEN='...' # fine-grained PAT with "Copilot Requests"
export GEMINI_API_KEY='...'       # from Google AI Studio
export CODEX_API_KEY='...'        # OpenAI API key (or export OPENAI_API_KEY)
export AI_MODEL=auto              # optional, applies to every attempt
export GITHUB_TOKEN='...'         # optional for release API rate limits
```

The updater deliberately requires a clean worktree so AI changes cannot be
mixed with unrelated local work:

```bash
cilium/tools/run-cilium-upgrade.sh
```

The script performs the same operations as CI:

1. Reads the pinned Cilium version and fetches all stable upstream release notes
   between that version and the latest version.
2. Tries each AI CLI in priority order (copilot, gemini, codex) in headless
   mode, allowing the first successful one to edit the working tree. Failed
   attempts are discarded before retrying with the next CLI.
3. Verifies the target version, changed-file scope, and required PR rationale.
4. Runs `make prepare` and `make ci-validate`.
5. Leaves the modified files in the worktree and writes the PR description to
   `/tmp/cilium-upgrade-pr.md`.

Version detection can be tested without calling an AI CLI:

```bash
cilium/tools/run-cilium-upgrade.sh --check-only
```

For an intentionally dirty disposable worktree, set
`CILIUM_UPGRADE_ALLOW_DIRTY=true`. This bypass is not recommended for normal
use because AI-generated changes become difficult to distinguish from existing
changes.
