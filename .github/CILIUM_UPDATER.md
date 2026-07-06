# 每月 Cilium 更新器

`Monthly Cilium Upgrade` workflow 每月 20 日 02:23 UTC 从默认分支运行，也可以通过
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
4. 分别从 `cilium/cilium` 和 `cilium/hubble` 选择匹配 `X.Y.z` 的最新稳定上游版本。
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
minor 为起点复制出来的。Hubble CLI 也按同一个 `X.Y` minor 选择
`cilium/hubble` 中已经发布的最新稳定 patch；如果该 minor 没有可用 Hubble release，
版本检测会失败，避免把不存在的下载地址保存成二进制制品。

## Pull requests

升级 PR 按分支区分：

- Base branch：`cilium/vX.Y`
- Head branch：`automation/cilium-vX.Y-latest`
- Commit message 和 title：
  `[AutoUpdate vX.Y] Cilium version vCURRENT -> vTARGET`

pull request 验证 workflow 会针对目标为 `cilium/v*` 分支的 PR 和 push 运行。

## e2e 失败后的 AI 修复流程

首次升级阶段只负责生成升级 diff、通过静态验证并创建或更新 PR；它不会在同一次
运行里等待 PR e2e 完成。PR 创建后，`Validate Cilium Installation` workflow 会
运行 `make test-single` 和 `make test-multi`。如果 e2e 失败，后续修复应作为独立
阶段处理，避免把初始升级、CI 诊断和推送修复混在同一个不可控的 agent 回合里。

推荐流程：

1. 检出失败 PR 的 head 分支，例如 `automation/cilium-vX.Y-latest`。
2. 获取失败的 GitHub Actions job 完整日志，并优先定位第一个真实失败点。不要只根据
   `make debug` 最后的 event 下结论。
3. 让 AI 使用 `cilium/tools/prompts/cilium-upgrade-e2e-repair.md` 作为修复提示词。
   该提示词要求 AI 对照 PR diff、目标 chart 默认值、官方升级文档和 CI 日志分析根因。
4. 如果失败 job 的 kind 集群仍然可用，修复后优先在当前集群上重新执行安装脚本或
   `cilium/setup.sh`，让 Helm 走 `upgrade --install` 原地更新：
   - `test/scripts/install-cilium.sh <cluster> <cluster-id> <pod-cidr> <hubble-port> <clustermesh-port>`
   - 或在 `cilium/` 目录下使用同一组环境变量重新运行 `./setup.sh`
5. 原地升级后继续运行 `cilium status --wait`、必要的 `kubectl wait` 和失败用例。
   只有当旧资源残留让问题无法判断时，才清理并重建 kind 集群。
6. 修复验证通过后，AI 只暂存相关文件，提交并推送到同一个 PR head 分支。推送会再次
   触发 PR e2e，保留 CI 的最终结果作为合并依据。

这种模式可以显著缩短调试周期：例如 values 字段缺失导致 Pod 挂载失败时，修复
`cilium/values.yaml` 后直接重新运行 Helm upgrade，即可验证 Deployment 是否重新
渲染出所需 ConfigMap/Secret，而无需重新创建整个 kind 集群。

## 必需的仓库 secrets

workflow 会按优先级依次尝试每个 AI CLI，直到其中一个成功：
**copilot -> deepseek**。只有配置了凭据 secret 的 agent 才会被尝试，
因此可以按需要启用任意数量的 fallback。每个 agent 默认最多尝试 3 次，
单次尝试超时时间为 15 分钟。至少必须设置以下其中一项：

- `COPILOT_GITHUB_TOKEN`：供 GitHub Copilot CLI 使用的凭据。Copilot CLI 不接受
  `ghp_` 开头的 classic PAT；应使用 `copilot /login` 获得的 Copilot OAuth token，
  并属于拥有 GitHub Copilot 访问权限的账号。
- `DEEPSEEK_API_KEY`：供 `opencode run` 调用 DeepSeek 使用的 API key。

创建维护分支、推送自动化分支、创建或更新 PR 需要额外配置：

- `AUTOMATION_GITHUB_TOKEN`：fine-grained PAT，需要授权给
  `spidernet-io/deployCilium`，并授予 `Contents: Read and write` 和
  `Pull requests: Read and write` 权限。建议使用独立的自动化账号 token。

创建缺失的 `cilium/vX.Y` 维护分支时，workflow 使用当前 job 的 `GITHUB_TOKEN`
推送新分支。升级 PR 也由 `peter-evans/create-pull-request` 使用 `GITHUB_TOKEN`
创建，目标分支是对应的 `cilium/vX.Y`。manifest PR 会先校验
`AUTOMATION_GITHUB_TOKEN || COPILOT_GITHUB_TOKEN` 是否能访问仓库，并用它配置
manifest 自动化分支的 push remote；PR 创建动作本身仍使用 `GITHUB_TOKEN`。

注意：使用默认 `GITHUB_TOKEN` 创建的 pull request 通常不会触发新的
`pull_request` 事件，因此 `.github/workflows/pr.yaml` 可能不会自动启动 e2e 任务。
如果需要像普通用户操作一样触发后续 workflow，应改造 PR 创建步骤使用
`AUTOMATION_GITHUB_TOKEN` 作为 create-pull-request 的 token。

可选的仓库 variables：

- `AI_MODEL`：传给每次 CLI 尝试的模型名称。省略时，Copilot 使用自己的默认值，
  DeepSeek 使用 `deepseek/deepseek-v4-flash`。
- `DEEPSEEK_MODEL`：只覆盖 DeepSeek 的 opencode 模型名称，例如
  `deepseek/deepseek-v4-flash`。
- `COPILOT_MODEL`：只覆盖 Copilot CLI 的模型名称。

可选的运行时环境变量：

- `AI_AGENT_TIMEOUT`：每次 AI CLI 尝试的最大运行时间，默认 `15m`，使用 GNU
  `timeout` 的 duration 语法。
- `AI_AGENT_MAX_ATTEMPTS`：每个 AI CLI 的最大尝试次数，默认 `3`；设为 `1` 可关闭重试。
- `CILIUM_UPGRADE_SKIP_VALIDATION=true`：本地调试时跳过 `make prepare` 和
  `make ci-validate`。workflow 不设置该变量，因此默认会执行验证。

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
