# agent-network-skill

CommHub MCP 双 agent 协作协议的统一技能。规划者（指挥室）与工人（执行者）共用同一份规则，
替代散落在各工作目录里的单独说明。**与具体项目无关**：任何项目挂上即可用。

## 安装（git submodule）

在项目工作目录执行：

```bash
git submodule add git@github.com:pixb/agent-network-skill.git .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill .gitmodules
git commit -m "add agent-network-skill submodule"
```

SKILL.md 就在仓库根，直接挂在 `.agents/skills/<name>` 下即可被发现——不需要额外的容器
目录，也不需要符号链接。

更新：

```bash
git submodule update --remote .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill && git commit -m "bump agent-network-skill"
```

## 发现路径

| 工具 | 项目级发现 |
|---|---|
| pi | `.agents/skills/`（从 cwd 向上到仓库根）；`/skill:agent-network-skill` 手动加载 |
| opencode | `.opencode/skill(s)/`、祖先目录 `.agents/skills/`；系统提示里以 available_skills 呈现 |

## 使用

- 规划者：`/agent-network-skill 拆任务并派给 <worker-alias>`
- 工人：`/skill:agent-network-skill` 后说「收任务」
- 连接前提、令牌分层与 CLI/MCP 分工见 [SKILL.md](SKILL.md) 第 0 节

## 内容

| 文件 | 作用 |
|---|---|
| [SKILL.md](SKILL.md) | 协议全文：连接与令牌、两个角色流程、状态机、参数铁律、跨机约定、需求池、Gotchas |
| [AGENTS.md](AGENTS.md) | 目录级说明（哪些 agent 该读、触发条件） |
| [discovery.json](discovery.json) | 技能发现元数据（触发条件、证据、路由测试） |
