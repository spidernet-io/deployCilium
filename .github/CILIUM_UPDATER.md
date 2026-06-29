# 每周 Cilium 更新器

`Weekly Cilium Upgrade` workflow 每周一 02:23 UTC 从默认分支运行，也可以通过
`workflow_dispatch` 手动启动。

默认分支是更新器控制面。它通过 `.github/cilium-supported-versions.json` 记录当前
仓库明确支持的 Cilium minor，例如 `1.18` 和 `1.19`。每次运行时，workflow 只处理
该文件中 `enabled=true` 的 minor：先确保对应的 `cilium/vX.Y` 分支存在，再检查该
分支是否需要升级到同一 minor 的最新 patch。带版本的 Cilium 内容，例如 charts、
binaries、`cilium/version.sh`、values 和部署脚本，都维护在 `cilium/vX.Y` 分支上，
而不是默认分支上。

## 分支模型

- `main`：更新器 workflow、脚本和文档。
- `cilium/v1.18`：最新支持的 `1.18.z` 部署内容。
- `cilium/v1.19`：最新支持的 `1.19.z` 部署内容。

每个 `cilium/vX.Y` 分支只负责一个 Cilium minor 系列。该分支上的自动更新只会
选择匹配 `X.Y.z` 的版本。

## 支持版本清单

`.github/cilium-supported-versions.json` 是 schedule 和手动触发共同使用的输入：

```json
{
  "supported": [
    {
      "minor": "1.18",
      "branch": "cilium/v1.18",
      "latest_version": "1.18.3",
      "updated_at": "2026-06-29T00:00:00Z",
      "enabled": true
    }
  ]
}
```

- `minor`：要维护的 Cilium minor。
- `branch`：对应维护分支，当前约定为 `cilium/vX.Y`。
- `latest_version`：workflow 最近一次确认并写回 main 的该 minor 最新 patch。
- `updated_at`：`latest_version` 最近一次变化的 UTC 时间。
- `enabled=false`：临时保留记录但不再纳入自动升级矩阵。

## 发现和新 minor 分支

每次运行开始时，workflow 会：

1. 从 `.github/cilium-supported-versions.json` 读取启用的 minor。
2. 从 GitHub 获取稳定的 Cilium 版本，并为每个启用 minor 选择最新 patch。
3. 检查每个 `cilium/vX.Y` 分支是否存在，不存在则创建。
4. 生成只包含清单中启用 minor 的升级矩阵。

如果需要新增或停止维护某个 minor，应先修改 `.github/cilium-supported-versions.json`。
workflow 不会自动把上游出现的新 minor 加入支持范围，避免意外创建未经确认的维护线。

## 升级策略

对于发现的每个 `cilium/vX.Y` 分支，workflow 会：

1. 检出该分支。
2. 从 `cilium/version.sh` 读取当前 `CILIUM_VERSION`。
3. 设置 `CILIUM_TARGET_MINOR=X.Y`。
4. 选择匹配 `X.Y.z` 的最新稳定上游版本。
5. 运行配置好的 AI CLI 来更新仓库内容。
6. 创建或更新以同一维护分支为目标的 pull request。
7. 所有维护分支处理成功后，再创建或更新一个以 `main` 为目标的 pull request，
   写回 `.github/cilium-supported-versions.json` 中记录的最新 patch 版本。

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
**copilot -> deepseek**。只有配置了凭据 secret 的 agent 才会被尝试，
因此可以按需要启用任意数量的 fallback。至少必须设置以下其中一项：

- `COPILOT_GITHUB_TOKEN`：fine-grained PAT，需要具备 "Copilot Requests"
  权限，并属于拥有 GitHub Copilot 访问权限的账号。
- `DEEPSEEK_API_KEY`：供 `opencode run` 调用 DeepSeek 使用的 API key。

PR 创建还需要一个单独的 secret：

- `CILIUM_UPDATE_TOKEN`：fine-grained PAT 或 GitHub App token，需要具备仓库
  `Contents: Read and write` 和 `Pull requests: Read and write` 权限。

创建缺失的 `cilium/vX.Y` 维护分支时，workflow 会优先使用 `CILIUM_UPDATE_TOKEN`，
未设置时回退到默认 `GITHUB_TOKEN`。workflow 默认的 `GITHUB_TOKEN` 绝不会用作
Copilot 凭据或 PR 创建 token。使用默认 token 创建的 pull request 不会触发新的
`pull_request` 事件，因此 `.github/workflows/pr.yaml` 不会启动 e2e 任务。
专用 token 会让 PR 创建表现得像普通用户或 app 操作，并自动触发这些测试。

可选的仓库 variables：

- `AI_MODEL`：传给每次 CLI 尝试的模型名称。省略时，Copilot 使用自己的默认值，
  DeepSeek 使用 `deepseek/deepseek-v4-pro`。
- `DEEPSEEK_MODEL`：只覆盖 DeepSeek 的 opencode 模型名称，例如
  `deepseek/deepseek-v4-pro`。

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
npm install --global opencode-ai@latest

export COPILOT_GITHUB_TOKEN='...'
export DEEPSEEK_API_KEY='...'
export CILIUM_TARGET_MINOR=1.18
cilium/tools/run-cilium-upgrade.sh
```

更新器有意要求干净的 worktree，避免 AI 变更与无关本地工作混在一起。对于有意
保持 dirty 状态的一次性 worktree，可以设置 `CILIUM_UPGRADE_ALLOW_DIRTY=true`。
