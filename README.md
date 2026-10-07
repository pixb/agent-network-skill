# agent-network-skill

agent-network（CommHub MCP）双 agent 协作协议的统一技能。规划者（指挥室）与
工人（执行者）共用同一份规则，替代散落在各工作目录里的单独说明。

## 安装（git submodule）

在项目工作目录（如 `~/Downloads/tetris`、`~/Downloads/pi-work/tetris`）执行：

```bash
git submodule add git@github.com:pixb/agent-network-skill.git skills
mkdir -p .agents/skills
ln -s ../../skills .agents/skills/agent-network-skill
git add skills .agents/skills && git commit -m "add agent-network-skill submodule"
```

根目录的 `skills/` 是权威内容（submodule）；`.agents/skills/agent-network-skill`
是发现用符号链接——pi 与 opencode 都原生扫描项目级 `.agents/skills/**/SKILL.md`。

更新：`git submodule update --remote skills` 后提交。

## 发现路径

| 工具 | 项目级发现 |
|---|---|
| pi | `.agents/skills/`（cwd 向上到仓库根）；`/skill:agent-network-skill` 手动加载 |
| opencode | `.opencode/skill(s)/`、祖先目录 `.agents/skills/`；系统提示里以 available_skills 呈现 |

## 使用

- 规划者：`/agent-network-skill 拆任务并派给 pi-worker`
- 工人：`/skill:agent-network-skill` 后说「收任务」
- 连接前提与 token 分层见 [SKILL.md](SKILL.md) 第 0 节

## 验证

```bash
python3 scripts/validate.py .
python3 scripts/security_scan.py .
```

（脚本来自 agent-skills-platform 技能目录。）
