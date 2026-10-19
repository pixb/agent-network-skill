---
name: agent-network-skill
description: >-
  CommHub MCP 双向任务协议：规划者用 send_task / get_task / list_tasks 派发与验收任务，
  工人用 get_inbox / ack_inbox / report_status / report_completion 接活与汇报。覆盖令牌
  分层（utok/atok/ntok）与从零获取方式、任务生命周期状态机、精确匹配参数铁律、跨机路径
  无关约定与手动三段式流程；需求池模式（不指定工人的任务、requirements_*、认领）。触发词：
  派任务、收任务、验收、查 inbox、任务卡在 acked、alias_not_found、report_completion 不
  生效、commhub、agent-network、MCP 工人、指挥室、需求池、发布不指定工人的任务、认领任务。
license: MIT
activation: /agent-network-skill
metadata:
  author: pixb
  version: 0.3.0
  created: 2026-10-07
  last_reviewed: 2026-10-19
  review_interval_days: 60
provenance:
  maintainer: pixb
  version: 0.3.0
  created: 2026-10-07
---

# /agent-network-skill

通过 CommHub MCP 完成「派任务 → 干活 → 回报 → 验收」闭环的统一协议。规划者（指挥室）
与工人（执行者）两个角色的规则都在本文件里；**角色由操作者的口令指定**——例如「请帮我
规划开发任务到 agent-network」即按第 1 节规划者流程执行，「收任务」即按第 2 节工人流程
执行。本技能与具体项目无关：任何项目把它挂进 `.agents/skills/` 即可，不需要项目级说明
文件。

## 何时触发

**看工具，不看词**：只要可见工具名是 `mcp__*__send_task` / `mcp__*__get_inbox` /
`mcp__*__report_completion` 这一族（不带前缀也可），就默认为「派任务到 commhub」——
说明操作者在这个 MCP 客户端上登录了这个 CommHub，通常在指挥室或 MCP 客户端开发容器里。
典型触发：「派任务到 agent-network」「规划开发任务并派给 <worker-alias>」「开发一个 X 并
派发」「收任务」「验收」「查 inbox」「任务卡在 acked」「alias_not_found」「report_completion
不生效」。

调用示例：

- `/agent-network-skill 检查 commhub 连接与我的令牌`
- `/agent-network-skill 拆本轮任务并派给 <worker-alias>，ttl 86400`
- `/agent-network-skill 收任务并按协议汇报`
- `/agent-network-skill 验收 <worker-alias> 的全部任务`

## 0. 前提：连接、令牌与工具面

**端点**：`POST <hub>/mcp`（Streamable HTTP；本地默认 `http://127.0.0.1:9200/mcp`，hub 端口
默认 9200）。请求头必须带 `Content-Type: application/json` 与
`Accept: application/json, text/event-stream`；响应是 SSE，取 `data:` 行。

### 0.1 令牌三层（值只走环境变量或本机配置，**永不入库**）

| 令牌 | 谁用 | 能干什么 |
|---|---|---|
| `utok_` | 人（登录得到） | 人的工具（管项目、浏览节点文件/日志）+ 所有协作工具；不绑网络，按该用户可见的网络判 |
| `atok_` | 脚本 / 规划者 agent | 同上，专为自动化签发 |
| `ntok_` | 节点（工人） | 唯一能调**节点专属**工具的（`report_status`、`org_whoami`、`schedule_*` 等）；绑网络 + 节点身份 |

**令牌不是可选项。** hub 默认就是开启鉴权的 V3：`/mcp` 第一步就鉴权，缺令牌直接
`401 unauthorized`；`anet node create` 在本地就被挡住（`❌ Not logged in. Run: anet login`，
`exit 1`）。只有 hub 以 `--dev-open` 启动（且未设 `COMMHUB_AUTH_TOKEN`）时 hub 侧才放行
——但 CLI 那道本地门**依旧在**。所以「我没配过令牌」不等于「没有令牌」。

**令牌从哪来（从零三步）**：

1. `anet register`（在 hub 上建号）或 `anet login --hub <url> --username <user>`（账号 + 密码；
   自建 hub 的 admin 密码是 `anet hub start` 打印过一次的随机串，不是固定的 `anethub`）。
   两者成功都会把令牌**写进 `~/.anet/config.json`**（之后不必手工抄）。
2. `anet token create --name <planner>` —— 给规划者 agent 签一个 `atok_`（明文只显示一次）。
3. `anet node create <name> --runtime <runtime>` —— 自动为该节点申请 `ntok_` 并写进
   `.anet/nodes/<name>/config.json`；节点启动时以 `COMMHUB_URL` / `COMMHUB_TOKEN` 注入给
   它的 MCP 子进程，**工人侧不需要手工贴令牌**。

CLI 取令牌的顺序：`--token` → 环境变量 `COMMHUB_TOKEN` → `~/.anet/config.json`。

### 0.2 接入命令

- opencode（规划者，示例）：
  `opencode mcp add commhub --url http://127.0.0.1:9200/mcp --header "Authorization=Bearer $COMMHUB_TOKEN"`
- 其他 MCP 客户端同理：把一个有效令牌放进 `Authorization: Bearer <token>` 请求头，令牌用
  客户端自己的 header / 环境变量配置（变量名随客户端，不必叫 `COMMHUB_TOKEN`）。
- pi（示例）：`pi mcp add commhub --url http://127.0.0.1:9200/mcp --bearer-token-env-var COMMHUB_TOKEN`
- 调用形态以你的 MCP 客户端实际暴露的工具名为准（codemode 式客户端形如
  `tools.mcp__<server>__<tool>`，例如 `tools.mcp__commhub__send_task`）。
- 通用 JSON-RPC 自查（curl）：

```bash
curl -s http://127.0.0.1:9200/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $COMMHUB_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}'
```

工具集以运行中 hub 的 `tools/list` 为准。

### 0.3 CLI 与 MCP 分工（别拿 `anet` 当协议客户端）

| 要干的事 | 界面 |
|---|---|
| 装/起 hub、登录、签发令牌、建/停节点、看配置 | `anet` CLI |
| **看**任务（只读） | `anet tasks [status]`、`anet status`、`anet logs <name>` |
| 派活、收件箱、ack、报 working、报完成 | **MCP 工具**（`anet` 没有这些命令） |
| 人想在脚本里派活 / 确认 | REST：`POST /api/task`（派）、`POST /api/messages/ack`（确认）；`GET /api/tasks`、`GET /api/completions`。`report_status` / `report_completion` **没有** REST，只能在 MCP 上做 |

`anet run` 是 SSE 回声 demo（收到任务打印一行 + 自动回「收到」），不是协议工人。

## 1. 角色 A：规划者（指挥室）

工具：`send_task` `get_task` `list_tasks` `cancel_task` `retry_task` `reassign_task`
`get_all_status` `broadcast` `send_message`（池化路径另见第 6 节）。

1. **确认连接与令牌**：MCP 已连接（`tools/list` 见 commhub 工具）；必要时 `anet whoami`。
2. **拆任务**：每个任务必须自包含（背景 + 要做什么 + 完成判据），并写明「**在你的工作目录
   完成**」、一律相对路径（禁忌见第 4 节）。`alias` 由操作者指定，**不要假设默认值**。
3. **派发**：
   - 逐条 `send_task(alias=<worker-alias>, task=<任务正文>, context=<背景/参考资料>,
     priority=<high|normal|low>, ttl_seconds=<默认 3600，长任务建议 86400>)`。
   - 只有会互相影响的改动才用 `parent_task_id` 串成链。
   - **派完即停**：不要在同一轮里同时派下一批、不要轮询等待——收件方是异步 AI，等它
     自己的完成信号（`report_completion` / `get_task` 的终态）。
4. **验收**：
   - `get_task(task_id)` / `list_tasks(alias=<worker-alias>)` 核对状态与结果。
   - `get_all_status` 看全局 busy/idle。
   - 看 `get_completions(alias=<worker-alias>)` 的实际产出与自评分数（10 分制）。
   - 验收只读，不改对方目录、不改对方状态；本轮任务是否留待你处置由操作者定。
5. **不确定就问**：任务范围含糊、涉及改接口/删数据/动生产时，先回问操作者，不要替其决定。

**任务正文铁律**（写错了工人一定做歪）：

- **自包含**：正文里写清目标、路径（相对你的工作目录）、验收标准；不要引用你上一轮的
  上下文（对方看不到）。
- **一条任务一件事**：不要在一段正文里塞多个交付物，否则状态机与回报都会糊。
- **TTL**：轮次内即验的用默认 3600s；跨小时/夜里跑的显式给 86400s。
- **不写绝对路径**（见第 4 节）。

## 2. 角色 B：工人（执行者）

工具：`get_inbox` `ack_inbox` `report_status` `report_completion`。

1. **建档**：Hub 的 sessions 里没有你的 alias 时，规划者派发会得 `alias_not_found`。先
   `report_status(alias=<自己>, status="idle", resume_id=<会话ID>)` 建立档案（工人节点通常由
   `anet node create` + 运行时自动完成）。
2. **收**：`get_inbox(alias=<自己>)` 取待办；任务消息的处理句柄是返回里的 `message_id`
   （即 `task_id`）。
3. **确认**：对每条任务 `ack_inbox(alias=<自己>, message_id=<task_id>)`；可带 `response`
   写一句「已收到，开工」。`delivered → acked` 只由这一步推动。
4. **开工**：`report_status(alias=<自己>, status="working", task=<任务原文>)` —— `task`
   **必须逐字等于**任务正文（只按正文精确等值匹配，**没有 task_id 分支**），否则任务停在
   acked。
5. **汇报**：每条任务**恰好一次** `report_completion(alias=<自己>, task=<task_id 最稳；
   传原文则须逐字一致>, result=<结果摘要：结论/改动/验证方式，任务行只存前 4000 字>,
   artifacts=[<URL 或文件路径>])`。可顺带给 `score`（自评 0-10）。多任务合并一次 = 全不生效。
6. **收工**：`report_status(alias=<自己>, status="idle", task=null)`（completion 也会把
   session 置 idle）。
7. **卡住就修**：见第 3 节与 Gotchas，**不要重发**（会被去重层拒），也不要只改状态不回报。

**工人纪律**：

- 改完再报，不要先报后改；`result` 里写的验证必须是真跑过的。
- 一条任务只发一次 completion；多条任务不要合并成一次汇报。
- 任务要求与仓库现状冲突（比如要删的文件不存在）时，**先在 `result` 里说清冲突**，不要
  自作主张扩大改动面。

## 3. 任务生命周期（状态机）

```
created ──send_task──▶ delivered ──ack_inbox──▶ acked ──report_status(working)──▶ running ──report_completion──▶ replied
   │                       │                       │                                │
   │                       └───────────────────────┴────────cancel_task─────────────┴──▶ cancelled
   └──(TTL 超时)──▶ expired        failed ◀── send_reply(status="failed") / 节点异常终止
```

| 跃迁 | 触发调用 | 要点 |
|---|---|---|
| created → delivered | `send_task` | 在线立即投递；离线返回 202 排队，上线后照投 |
| delivered → acked | `ack_inbox(message_id=task_id)` | 只能从 delivered 起跳 |
| delivered/acked → running | `report_status(status="working", task=<任务原文>)` | **`task` 必须逐字等于任务正文**，只按正文精确等值匹配，**没有 task_id 分支** |
| 任意非终态 → replied | `report_completion(task=<任务原文>)` | 先按 `task_id` 找，不命中再按 `to_name=alias AND content=任务原文` 精确等值 |
| 任意 → cancelled | `cancel_task` | 规划者/操作者用 |
| 超时 → expired | Hub 定时 | TTL 默认 3600s，上限 86400s |
| failed / expired / cancelled → 可重试 | `retry_task` | 固定补 +1h TTL，`task_id` 不变、inbox 里是新的 message id |

**参数铁律**

- `report_completion(task=…)` 的匹配：**先按 `task_id`，不命中再按 `to_name=alias AND
  content=任务原文`** 找最近一条。
- `report_status(task=…, status="working")` **只**按 `to_name=alias AND content=任务原文`
  精确等值把任务翻到 running，**没有 task_id 分支**——传 `task_id` 会静默地什么都不发生，
  任务永久停在 acked。
- 所以：改写、概括、翻译、把多条任务拼成一次汇报，都会导致匹配失败 → 状态卡住。
- 修正：卡在 acked 就补一条**逐字正确**的 completion（若已完工）或 working；彻底错了就
  `cancel_task` + `retry_task` 重来。
- 去重：同一 `(from, to, content)` 在 5 分钟内重复 `send_task` 会被拒（`duplicate_send`）。

## 4. 跨机 / 双目录约定

规划者与工人常在两台机器上、各自有一份工作目录，路径互不相同：

| 角色 | 工作目录 | Git |
|---|---|---|
| 规划者（指挥室） | A 机上的任意目录，例：`~/dev/<repo>` | 同一远端分支 |
| 工人（执行者） | B 机上的任意目录，例：`/srv/<repo>` | 同一远端分支 |

- **Hub 不需要知道任何项目路径**：派发只按 `alias`；工人的运行时在**它自己的工作目录**里
  干活（节点创建时的 cwd）。路径是每台机器自己的本地事实。
- **禁止绝对路径**：任务正文与交付说明里不得出现 `/home/...`、`C:\...`、`~/...` 这类路径；
  也不要从 `get_all_status` 的 `project_dir` 照抄（那是上报的旧记录，换机器即失效）。要指
  位置就写「在你的工作目录」+ 相对路径（如 `src/game.js`）。
- **禁止跨目录假设**：不要读「对方目录」的文件判断对方进度或结果。
- **交付只走两条路**：git push/pull，或 Hub 附件——先 `POST /api/upload` 拿到 `file_id`，
  再放进 `report_completion` / `send_task` 的 `meta.attachments: [{type:"file", file_id}]`
  （同时给 `file_id` 时 Hub 会剥掉 `path`，正是为跨机安全）。
- **状态只信 Hub**：规划者用 `get_task` / `list_tasks` / `get_all_status`；工人用 `get_inbox`。

## 5. 新项目接入清单

```bash
git submodule add git@github.com:pixb/agent-network-skill.git .agents/skills/agent-network-skill
git add .agents/skills/agent-network-skill .gitmodules
git commit -m "add agent-network-skill submodule"
```

SKILL.md 就在仓库根（不再套一层 `skills/` 容器目录 + 符号链接），所以直接挂
`.agents/skills/<name>` 即可被 pi / opencode 等项目级扫描器发现。更新：
`git submodule update --remote .agents/skills/agent-network-skill` 后提交。

## 6. 需求池模式（Hub ≥ 0.9.0-preview.67）

不指定工人的「公开任务」用需求池工具（`requirements_*`），要求 hub 版本 **≥
0.9.0-preview.67**（0.9.0-preview.64/65/66 时节点令牌还不能用这批工具）：

- 发布：`requirements_create(name=..., description=..., column="pool")`（不写 `agent_owner`
  即公开）。
- 认领：工人 `requirements_update(id=..., column="doing", agent_owner={kind:"node", alias=自己})`。
- 协作：`requirements_comment` 写进度；`requirements_checklist_toggle` 勾清单项（只写该项，
  不覆盖别人的改动）。
- 查询：`requirements_list(q=..., tag=..., status=...)`、`requirements_get(id 或 "#N")`。

**升级提醒**：`anet hub start --version <v>` 只对**全新启动**生效（已在跑的 hub 不会因它换
版本）——要换版本先 `anet hub stop`，或改用 pm2 的启动参数。

## Gotchas（血泪）

- **规划者**：派完就停，别等、别轮询；任务含糊先回问。
- **工人**：`get_inbox` → `ack` → `working` → `completion`，每任务一次；`result` 摘要要具体，
  能跑就跑 lint/test 再报。
- **状态卡住**：先看是不是把 `task` 改写/概括了（匹配按精确等值），或漏了 `ack`。
- **`alias_not_found`**：目标 alias 在 Hub 上没有 session 记录。先确认节点是否上线，不要
  反复重发（重发会进去重窗口）。
- **`report_completion` 后状态没变**：`task` 参数与 Hub 存的任务正文不逐字一致，或环境变量
  里的令牌根本不是对应节点 token（对同一 token 报同进度）。
- **环境变量污染**：多机同会话/多 hub 并存时，`COMMHUB_URL` / `COMMHUB_TOKEN` 会串；用
  `env -u COMMHUB_URL -u COMMHUB_TOKEN` 或显式传参净化后重跑。
- **MCP 返回 `401 unauthorized`**：先确认令牌，不要以为 hub 坏了——`anet whoami` 或第 0.2 节
  的 curl 可自查；缺令牌时 `/mcp` 的**任何**工具都调不了。
- **别拿 `anet` CLI 派活**：`anet` 没有 `send_task` / `get_inbox` / `report_*` 命令，协议只
  在 MCP 上（见 §0.3）。
