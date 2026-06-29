# 每周 Cilium 更新器

`Weekly Cilium Upgrade` workflow 每周一 02:23 UTC 从默认分支运行，也可以通过
`workflow_dispatch` 手动启动。

默认分支是更新器控制面。它会发现 Cilium 维护分支，在需要时为上游新发布的
minor 创建分支，然后检查每个维护分支是否存在 patch 更新。带版本的 Cilium
内容，例如 charts、binaries、`cilium/version.sh`、values 和部署脚本，都维护在
`cilium/vX.Y` 分支上，而不是默认分支上。

## 分支模型

- `main`：更新器 workflow、脚本和文档。
- `cilium/v1.18`：最新支持的 `1.18.z` 部署内容。
- `cilium/v1.19`：最新支持的 `1.19.z` 部署内容。

每个 `cilium/vX.Y` 分支只负责一个 Cilium minor 系列。该分支上的自动更新只会
选择匹配 `X.Y.z` 的版本。

## 发现和新 minor 分支

每次运行开始时，workflow 会：

1. 从 GitHub 获取稳定的 Cilium 版本。
2. 构建稳定上游 minor 列表。
3. 列出仓库中匹配 `cilium/v*` 的现有分支。
4. 按版本顺序，从当前最高的 `cilium/vX.Y` 分支创建缺失的更新 minor 分支。

这是“以前一个 minor 作为来源”的策略：新的 Cilium minor 分支从最新维护的 minor
分支开始，然后由常规升级任务为新分支提出第一个升级 PR。

例如，如果仓库已有 `cilium/v1.18`，且上游稳定版本包含 `1.19.0` 和 `1.20.0`，
workflow 会从 `cilium/v1.18` 创建 `cilium/v1.19`，然后从 `cilium/v1.19` 创建
`cilium/v1.20`。

如果仓库还没有任何 `cilium/v*` 分支，workflow 会从默认分支启动引导。默认分支
停止承载带版本的 Cilium 内容后，请在仓库中至少保留一个 `cilium/vX.Y` 种子分支。

## 升级策略

对于发现的每个 `cilium/vX.Y` 分支，workflow 会：

1. 检出该分支。
2. 从 `cilium/version.sh` 读取当前 `CILIUM_VERSION`。
3. 设置 `CILIUM_TARGET_MINOR=X.Y`。
4. 选择匹配 `X.Y.z` 的最新稳定上游版本。
5. 运行配置好的 AI CLI 来更新仓库内容。
6. 创建或更新以同一维护分支为目标的 pull request。

示例：

| 分支 | 当前版本 | 上游版本 | 目标版本 |
|---|---:|---|---:|
| `cilium/v1.18` | `1.18.3` | `1.18.4`, `1.19.0` | `1.18.4` |
| `cilium/v1.19` | `1.19.0` | `1.19.1`, `1.20.0` | `1.19.1` |
| `cilium/v1.20` | 分支创建后的 `1.19.4` | `1.20.0` | `1.20.0` |

现有维护分支不会发生跨 minor 升级。分支从一个 minor 移动到另一个 minor 的唯一
场景，是新创建的 `cilium/vX.Y` 分支上的第一个升级 PR，因为该分支是以前一个
minor 为起点复制出来的。

## Pull requests

升级 PR 按分支区分：

- Base branch：`cilium/vX.Y`
- Head branch：`automation/cilium-vX.Y-latest`
- Title：`chore: 将 Cilium X.Y 升级至 X.Y.z`

pull request 验证 workflow 会针对目标为 `cilium/v*` 分支的 PR 和 push 运行。

## 必需的仓库 secrets

workflow 会按优先级依次尝试每个 AI CLI，直到其中一个成功：
**copilot -> codex**。只有配置了凭据 secret 的 agent 才会被尝试，
因此可以按需要启用任意数量的 fallback。至少必须设置以下其中一项：

- `COPILOT_GITHUB_TOKEN`：fine-grained PAT，需要具备 "Copilot Requests"
  权限，并属于拥有 GitHub Copilot 访问权限的账号。
- `CODEX_API_KEY`：供 `codex exec` 使用的 OpenAI API key。当 `CODEX_API_KEY`
  未设置时，会使用 `OPENAI_API_KEY` 作为 fallback。

PR 创建还需要一个单独的 secret：

- `CILIUM_UPDATE_TOKEN`：fine-grained PAT 或 GitHub App token，需要具备仓库
  `Contents: Read and write` 和 `Pull requests: Read and write` 权限。

创建缺失的 `cilium/vX.Y` 维护分支时，workflow 会优先使用 `CILIUM_UPDATE_TOKEN`，
未设置时回退到默认 `GITHUB_TOKEN`。workflow 默认的 `GITHUB_TOKEN` 绝不会用作
Copilot 凭据或 PR 创建 token。使用默认 token 创建的 pull request 不会触发新的
`pull_request` 事件，因此 `.github/workflows/pr.yaml` 不会启动 e2e 任务。
专用 token 会让 PR 创建表现得像普通用户或 app 操作，并自动触发这些测试。

可选的仓库 variables：

- `AI_MODEL`：传给每次 CLI 尝试的模型名称。省略时，每个 CLI 使用自己的默认值。

实现提示词维护在 `cilium/tools/prompts/cilium-upgrade.md`。workflow 将生成的变更
限制在部署代码、测试和项目文档内；GitHub Actions 变更必须由人工审查并提交。

## 本地执行

要测试维护分支的版本检测：

```bash
export CURRENT_CILIUM_VERSION=1.18.3
export CILIUM_TARGET_MINOR=1.18
export GITHUB_TOKEN='...' # optional for release API rate limits
cilium/tools/run-cilium-upgrade.sh --check-only
```

要在本地运行完整升级，请安装一个或多个支持的 CLI，并导出对应凭据：

```bash
npm install --global @github/copilot@latest
npm install --global @openai/codex@latest

export COPILOT_GITHUB_TOKEN='...'
export CODEX_API_KEY='...'
export CILIUM_TARGET_MINOR=1.18
cilium/tools/run-cilium-upgrade.sh
```

更新器有意要求干净的 worktree，避免 AI 变更与无关本地工作混在一起。对于有意
保持 dirty 状态的一次性 worktree，可以设置 `CILIUM_UPGRADE_ALLOW_DIRTY=true`。
