# 每月 Cilium 更新器

`Monthly Cilium Upgrade` workflow 每月 20 日 02:23 UTC 从 `main` 运行，也可以
通过 `workflow_dispatch` 手动启动。

仓库只在 `main` 分支维护部署脚本和自动化逻辑。不同 Cilium minor 的安装资产放在
`cilium/versions/vX.Y/` 下，例如：

- `cilium/versions/v1.18`：最新支持的 `1.18.z` 部署内容。
- `cilium/versions/v1.19`：最新支持的 `1.19.z` 部署内容。

每个版本目录只负责一个 Cilium minor 系列。自动更新只会选择匹配 `X.Y.z` 的最新
稳定 patch，不会把 `v1.18` 目录升级到 `1.19.z`。

## 支持版本清单

`.github/cilium-supported-versions.json` 是 schedule 和手动触发共同使用的输入：

```json
{
  "supported": [
    {
      "minor": "1.18",
      "latest_version": "1.18.3",
      "updated_at": "2026-06-29T00:00:00Z",
      "enabled": true
    }
  ]
}
```

- `minor`：要维护的 Cilium minor，对应 `cilium/versions/vX.Y`。
- `latest_version`：workflow 最近一次确认并写回的该 minor 最新 patch。
- `updated_at`：`latest_version` 最近一次变化的 UTC 时间。
- `enabled=false`：临时保留记录但不再纳入自动升级和 PR 校验矩阵。

## 升级策略

每次运行开始时，workflow 会：

1. 从 `.github/cilium-supported-versions.json` 读取启用的 minor。
2. 从 GitHub 获取稳定的 Cilium 版本，并为每个启用 minor 选择最新 patch。
3. 生成只包含清单中启用 minor 的升级矩阵。

对于矩阵中的每个 minor，workflow 会：

1. 检出 `main` 到 worktree。
2. 设置 `CILIUM_MINOR=vX.Y`。
3. 从 `cilium/versions/vX.Y/version.sh` 读取当前 `CILIUM_VERSION`。
4. 分别从 `cilium/cilium` 和 `cilium/hubble` 选择匹配 `X.Y.z` 的最新稳定上游版本。
5. 运行配置好的 AI CLI 来更新该版本目录及必要的共享脚本。
6. 创建或更新以 `main` 为目标的 pull request。
7. 所有 minor 处理成功后，再创建或更新一个以 `main` 为目标的 pull request，
   写回 `.github/cilium-supported-versions.json` 中记录的最新 patch 版本。

示例：

| 版本目录 | 当前版本 | 上游版本 | 目标版本 |
|---|---:|---|---:|
| `cilium/versions/v1.18` | `1.18.3` | `1.18.4`, `1.19.0` | `1.18.4` |
| `cilium/versions/v1.19` | `1.19.0` | `1.19.1`, `1.20.0` | `1.19.1` |

## Pull requests

升级 PR 按版本目录区分：

- Base branch：`main`
- Head branch：`automation/cilium-vX.Y-latest`
- Title：`[AutoUpdate vX.Y] Cilium version vOLD -> vNEW`

`Validate Cilium Installation` workflow 会针对 `main` 上的 PR 和 push 运行，并按
`.github/cilium-supported-versions.json` 中启用的 minor 生成 `CILIUM_MINOR` 矩阵。

## e2e 失败后的 AI 修复流程

首次升级阶段只负责生成升级 diff、通过静态验证并创建或更新 PR；它不会在同一次
运行里等待 PR e2e 完成。PR 创建后，`Validate Cilium Installation` workflow 会
按支持 minor 运行 `make test-single` 和 `make test-multi`。如果 e2e 失败，后续
修复应作为独立阶段处理，避免把初始升级、CI 诊断和推送修复混在同一个 agent 回合里。

推荐流程：

1. 检出失败 PR 的 head 分支，例如 `automation/cilium-v1.19-latest`。
2. 获取失败的 GitHub Actions job 完整日志，并优先定位第一个真实失败点。
3. 导出失败 job 对应的 `CILIUM_MINOR`，例如 `export CILIUM_MINOR=v1.19`。
4. 优先使用 debug 信息，但不要把它作为 AI 排查的前置条件：
   - CI 失败日志中如果包含 `make debug` 输出，优先使用该输出。
   - 如果当前 kind 集群仍然可用，单集群失败可以执行 `make debug`。
   - 多集群失败可以分别执行
     `kubectl config use-context kind-cluster1 && make debug` 和
     `kubectl config use-context kind-cluster2 && make debug`。
   - 如果没有 debug 输出，AI 也可以直接基于失败日志、Kubernetes 事件、pod 日志、
     `kubectl describe`、Helm 渲染结果和 PR diff 排查。
5. 让 AI 使用 `cilium/tools/prompts/cilium-upgrade-e2e-repair.md` 作为修复提示词，并把
   失败日志、可用的 debug 证据、`CILIUM_MINOR` 和当前 PR diff 一并提供给 AI。
6. AI 先基于 debug 证据定位根因，再在当前 worktree 中做最小修复。不要先清理集群或重建集群。
7. 如果失败 job 的 kind 集群仍然可用，修复后优先在当前集群上重新执行安装脚本或
   `cilium/setup.sh`，让 Helm 走 `upgrade --install` 原地更新。
8. 原地升级后继续运行 `cilium status --wait`、必要的 `kubectl wait` 和原失败路径：
   `make test-single` 或 `make test-multi`。如果只重跑其中一段连接性测试，需要说明覆盖范围。
   只有当旧资源残留让问题无法判断时，才清理并重建 kind 集群。

## 必需的仓库 secrets

workflow 会按优先级依次尝试每个 AI CLI，直到其中一个成功：
**copilot -> deepseek**。只有配置了凭据 secret 的 agent 才会被尝试，
因此可以按需要启用任意数量的 fallback。至少必须设置以下其中一项：

- `COPILOT_GITHUB_TOKEN`：fine-grained PAT，需要具备 "Copilot Requests"、
  `Contents: Read and write` 和 `Pull requests: Read and write` 权限，并属于拥有
  GitHub Copilot 访问权限的账号。workflow 也使用该 token 创建 PR。
- `DEEPSEEK_API_KEY`：供 `opencode run` 调用 DeepSeek 使用的 API key。

创建或更新 PR 时必须设置 `COPILOT_GITHUB_TOKEN`。workflow 默认的 `GITHUB_TOKEN`
不会用作 Copilot 凭据或 PR 创建 token。使用默认 token 创建的 pull request 不会
触发新的 `pull_request` 事件，因此 `.github/workflows/pr.yaml` 不会启动 e2e 任务。

可选的仓库 variables：

- `AI_MODEL`：传给每次 CLI 尝试的模型名称。省略时，Copilot 使用自己的默认值，
  DeepSeek 使用脚本内的默认模型。
- `DEEPSEEK_MODEL`：只覆盖 DeepSeek 的 opencode 模型名称。

## 本地执行

要测试某个版本目录的版本检测：

```bash
export CILIUM_MINOR=v1.18
export GITHUB_TOKEN='...' # optional for release API rate limits
cilium/tools/run-cilium-upgrade.sh --check-only
```

要在本地运行完整升级，请安装一个或多个支持的 CLI，并导出对应凭据：

```bash
npm install --global @github/copilot@latest
npm install --global opencode-ai@latest

export COPILOT_GITHUB_TOKEN='...'
export DEEPSEEK_API_KEY='...'
export CILIUM_MINOR=v1.18
cilium/tools/run-cilium-upgrade.sh
```

更新器有意要求干净的 worktree，避免 AI 变更与无关本地工作混在一起。对于有意
保持 dirty 状态的一次性 worktree，可以设置 `CILIUM_UPGRADE_ALLOW_DIRTY=true`。
