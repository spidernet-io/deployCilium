# 每月 Cilium 更新器

`Monthly Cilium Upgrade` workflow 每月 20 日 02:23 UTC 从默认分支运行，也可以通过
`workflow_dispatch` 手动启动。

默认分支是更新器控制面。它通过 `.github/cilium-supported-versions.json` 记录当前
仓库明确支持的 Cilium minor，例如 `1.18` 和 `1.19`。每次运行时，workflow 只处理
该文件中 `enabled=true` 的 minor：先确保对应的 `cilium/release-vX.Y` 分支存在，再检查该
分支是否需要升级到同一 minor 的最新 patch。带版本的 Cilium 内容，例如 charts、
binaries、`cilium/version.sh`、values 和部署脚本，都维护在 `cilium/release-vX.Y` 分支上，
而不是默认分支上。

## 分支模型

- `main`：更新器 workflow、脚本和文档。
- `cilium/release-v1.18`：最新支持的 `1.18.z` 部署内容。
- `cilium/release-v1.19`：最新支持的 `1.19.z` 部署内容。

每个 `cilium/release-vX.Y` 分支只负责一个 Cilium minor 系列。该分支上的自动更新只会
选择匹配 `X.Y.z` 的版本。

## 支持版本清单

`.github/cilium-supported-versions.json` 是 schedule 和手动触发共同使用的输入：

```json
{
  "supported": [
    {
      "minor": "1.18",
      "branch": "cilium/release-v1.18",
      "latest_version": "1.18.3",
      "updated_at": "2026-06-29T00:00:00Z",
      "enabled": true
    }
  ]
}
```

- `minor`：要维护的 Cilium minor。
- `branch`：对应维护分支，当前约定为 `cilium/release-vX.Y`。
- `latest_version`：workflow 最近一次确认并写回 main 的该 minor 最新 patch。
- `updated_at`：`latest_version` 最近一次变化的 UTC 时间。
- `enabled=false`：临时保留记录但不再纳入自动升级矩阵。

## 发现和新 minor 分支

每次运行开始时，workflow 会：

1. 从 `.github/cilium-supported-versions.json` 读取启用的 minor。
2. 从 GitHub 获取稳定的 Cilium 版本，并为每个启用 minor 选择最新 patch。
3. 检查每个 `cilium/release-vX.Y` 分支是否存在，不存在则创建。
4. 生成只包含清单中启用 minor 的升级矩阵。

如果需要新增或停止维护某个 minor，应先修改 `.github/cilium-supported-versions.json`。
workflow 不会自动把上游出现的新 minor 加入支持范围，避免意外创建未经确认的维护线。

## 升级策略

对于发现的每个 `cilium/release-vX.Y` 分支，workflow 会：

1. 检出该分支。
2. 从 `cilium/version.sh` 读取当前 `CILIUM_VERSION`。
3. 设置 `CILIUM_TARGET_MINOR=X.Y`。
4. 分别从 `cilium/cilium` 和 `cilium/hubble` 选择匹配 `X.Y.z` 的最新稳定上游版本。
5. 运行配置好的 AI CLI 来更新仓库内容。
6. 创建或更新以同一维护分支为目标的 pull request。
7. 所有维护分支处理成功后，再创建或更新一个以 `main` 为目标的 pull request，
   写回 `.github/cilium-supported-versions.json` 中记录的最新 patch 版本。

示例：

| 分支 | 当前版本 | 上游版本 | 目标版本 |
|---|---:|---|---:|
| `cilium/release-v1.18` | `1.18.3` | `1.18.4`, `1.19.0` | `1.18.4` |
| `cilium/release-v1.19` | `1.19.0` | `1.19.1`, `1.20.0` | `1.19.1` |
| `cilium/release-v1.20` | 分支创建后的 `1.19.4` | `1.20.0` | `1.20.0` |

现有维护分支不会发生跨 minor 升级。分支从一个 minor 移动到另一个 minor 的唯一
场景，是新创建的 `cilium/release-vX.Y` 分支上的第一个升级 PR，因为该分支是以前一个
minor 为起点复制出来的。Hubble CLI 也按同一个 `X.Y` minor 选择
`cilium/hubble` 中已经发布的最新稳定 patch；如果该 minor 没有可用 Hubble release，
版本检测会失败，避免把不存在的下载地址保存成二进制制品。

## Pull requests

升级 PR 按分支区分：

- Base branch：`cilium/release-vX.Y`
- Head branch：`automation/cilium-vX.Y-latest`
- Title：`[AutoUpdate vX.Y] Cilium version vA.B.C -> vX.Y.z`

pull request 验证 workflow 会针对目标为 `cilium/release-v*` 分支的 PR 和 push 运行，
也可以通过 `workflow_dispatch` 手动指定 `ref` 运行。自动升级 PR 使用仓库默认的
`GITHUB_TOKEN` 创建，因此 GitHub 可能要求人工在 PR 页面批准或手动触发 e2e。月度
升级 workflow 会在创建 PR 前先运行同一套 e2e，避免把明显失败的升级直接提交成 PR。

## PR 前 e2e 和 AI 修复流程

首次升级阶段会生成升级 diff 并通过静态验证。之后，月度 workflow 会在同一个
`worktree` 里运行 `make test-single` 和 `make test-multi`，只有 e2e 通过后才创建
或更新 PR。

默认流程：

1. AI 先按 `cilium/tools/prompts/cilium-upgrade.md` 完成版本升级和静态验证。
2. workflow 在创建 PR 前运行 `make test-single` 和 `make test-multi`。
3. 如果 e2e 失败且仓库 variable `ENABLE_AI_E2E_REPAIR=true`，workflow 会收集失败日志，
   让 AI 使用 `cilium/tools/prompts/cilium-upgrade-e2e-repair.md` 作为修复提示词。
   该提示词要求 AI 对照升级 diff、目标 chart 默认值、官方升级文档和 CI 日志分析根因。
4. 修复脚本在已有升级 diff 的基础上做最小修改，并要求 AI 在修复总结中明确列出：
   修改了哪些参数或脚本行为、每项修改的作用、为什么能让 e2e 通过。
5. 修复后 workflow 重新运行 `make test-single` 和 `make test-multi`。这两个目标的
   集群创建逻辑是幂等的：如果同名 kind 集群已经存在，就跳过创建，继续执行
   `install-cilium.sh` / `setup.sh`，让 Helm 走 `upgrade --install` 验证修复后的
   `values.yaml` 或脚本参数。只有修复后 e2e 通过，才继续创建或更新 PR；否则
   workflow 失败，不提交 PR。
6. 最终 PR 描述会追加“升级测试和修复记录”，包括初次 e2e 结果、是否运行 AI 修复、
   修复说明、最终验证结果。

如果需要人工复现失败，仍可检出自动升级分支并按提示词里的建议优先使用原地升级：

   - `test/scripts/install-cilium.sh <cluster> <cluster-id> <pod-cidr> <hubble-port> <clustermesh-port>`
   - 或在 `cilium/` 目录下使用同一组环境变量重新运行 `./setup.sh`

这种模式可以显著缩短调试周期：例如 values 字段缺失导致 Pod 挂载失败时，修复
`cilium/values.yaml` 后直接重新运行 Helm upgrade，即可验证 Deployment 是否重新
渲染出所需 ConfigMap/Secret，而无需重新创建整个 kind 集群。

## 必需的仓库 secrets

workflow 会按优先级依次尝试每个 AI CLI，直到其中一个成功：
**copilot -> deepseek**。只有配置了凭据 secret 的 agent 才会被尝试，
因此可以按需要启用任意数量的 fallback。至少必须设置以下其中一项：

- `COPILOT_GITHUB_TOKEN`：Copilot CLI 凭据，需要可用于 `@github/copilot` CLI。
  它只用于 AI 升级步骤，不用于创建分支或 PR。
- `DEEPSEEK_API_KEY`：供 `opencode run` 调用 DeepSeek 使用的 API key。

workflow 使用默认 `GITHUB_TOKEN` 创建缺失的 `cilium/release-vX.Y` 维护分支、
推送自动化分支并创建或更新 PR。这样不依赖个人 PAT 或组织成员权限。代价是 GitHub
可能不会自动运行 bot 创建 PR 的普通 `pull_request` e2e，需要由 assignee 在 PR 页面
批准运行，或者手动触发 `Validate Cilium Installation` workflow 并填写 PR head 分支。

可选的仓库 variables：

- `AI_MODEL`：传给每次 CLI 尝试的模型名称。省略时，Copilot 使用自己的默认值，
  DeepSeek 使用 `deepseek/deepseek-v4-pro`。
- `DEEPSEEK_MODEL`：只覆盖 DeepSeek 的 opencode 模型名称，例如
  `deepseek/deepseek-v4-pro`。
- `CILIUM_UPGRADE_PR_ASSIGNEE`：自动升级 PR 和版本清单 PR 的 assignee。省略时为
  `cyclinder`。
- `ENABLE_AI_E2E_REPAIR`：设置为 `true` 时，允许月度升级 workflow 在 PR 前 e2e
  失败后运行 AI 修复并重跑 e2e。

初始升级提示词维护在 `cilium/tools/prompts/cilium-upgrade.md`。PR e2e 失败后的
修复提示词维护在 `cilium/tools/prompts/cilium-upgrade-e2e-repair.md`。workflow 将
生成的变更限制在部署代码、测试和项目文档内；GitHub Actions 变更必须由人工审查并提交。

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
