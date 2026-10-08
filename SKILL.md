---
name: agent-network-skill
description: >-
  CommHub MCP 双向任务协议：规划者用 send_task / get_task / list_tasks 派发与验收任务，
  工人用 get_inbox / ack_inbox / report_status / report_completion 接活与汇报。覆盖 token
  分层（utok/atok/ntok）、任务生命周期状态机、精确匹配参数铁律、跨机双目录约定与手动三段式
  流程；需求池模式（不指定工人的任务、requirements_*、认领）。触发词：派任务、收任务、验收、
  查 inbox、任务卡在 acked、alias_not_found、report_completion 不生效、commhub、agent-network、
  MCP 工人、指挥室、需求池、发布不指定工人的任务、认领任务。
license: MIT
activation: /agent-network-skill
metadata:
  author: pixb
  version: 0.2.0
  created: 2026-10-07
  last_reviewed: 2026-10-08
  review_interval_days: 60
provenance:
  maintainer: pixb
  version: 0.2.0
  created: 2026-10-07
---

# /agent-network-skill

通过 CommHub MCP 完成「派任务 → 干活 → 回报 → 验收」闭环的统一协议。规划者（指挥室）与
工人（执行者）两个角色的规则都在本文件里；**角色由操作者的口令指定**——例如「请帮我规划
开发任务到 agent-network」即按第 1 节规划者流程执行，「收任务」即按第 2 节工人流程执行。
项目里不需要任何角色声明或说明文件。

## 何时触发

- 「把 X 派给 alias」「收任务」「验收」「任务怎么卡住了」
- 要拆解任务并派发、要消费 inbox、要按协议汇报完成
- 报错排查：`alias_not_found`、任务停在 acked/running、report_completion 后状态没变

Invocation examples：

- `/agent-network-skill 检查 commhub 连接与我的角色`
- `/agent-network-skill 拆本轮任务并派给 pi-worker，ttl 86400`
- `/agent-network-skill 收任务并按协议汇报`
- `/agent-network-skill 验收 pi-worker 的全部任务`

## 0. 前提：MCP 连接

- **端点**：`POST http://127.0.0.1:9200/mcp`（Streamable HTTP；请求头必须
  `Content-Type: application/json` + `Accept: application/json, text/event-stream`；
  响应是 SSE，取 `data:` 行）。
- **token 分层**（值永不出现在文件/仓库里，只走环境变量或本机配置）：
  - `utok_` 用户令牌（登录用）；`atok_` API 令牌（规划者/用户工具）；`ntok_` 节点令牌（工人心跳）。
  - atok 获取：`anet n create <name>`（明文只显示一次）。
  - ntok 获取：`anet node create <id>` 后读 `.anet/nodes/<id>/config.json`。
  - 本项目环境：规划者用 `TETRIS_PLANNER_TOKEN`（atok），工人用 `ANET_HUB_TOKEN`（ntok）。
- **接入命令**：
  - opencode（规划者）：`opencode mcp add commhub --url http://127.0.0.1:9200/mcp --header "Authorization=Bearer $TETRIS_PLANNER_TOKEN"`
  - pi（工人）：`pi mcp add commhub --url http://127.0.0.1:9200/mcp --bearer-token-env-var ANET_HUB_TOKEN`
- **调用形态**：
  - pi codemode：`tools.mcp__commhub__send_task({ ... })`。
  - 通用 JSON-RPC（调试用）：

```bash
curl -s http://127.0.0.1:9200/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TETRIS_PLANNER_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}'
```

- 工具集以实际 MCP 列表为准（任务类 `send_task` / `list_tasks` / `get_task` 等；
  需求池类 `requirements_*` 需要 Hub ≥ preview.66——`tools/list` 里没有就说明
  Hub 版本过旧，用 `anet hub start --version <版本>` 升级，见第 6 节）。

## 1. 角色 A：规划者（指挥室）

工具：`send_task` `get_task` `list_tasks` `cancel_task` `retry_task`
`reassign_task` `get_all_status` `broadcast` `send_message`

**手动三段式，不轮询、不自作主张**：

1. **拆任务**：每个任务必须自包含（背景 + 要做什么 + 完成判据），并明确写
   「**在你的工作目录完成**」（跨机禁忌见第 4 节）；**任务内容禁止出现任何
   绝对路径**（派发方、接收方机器的都不行）——需要指明文件位置时一律用
   相对路径（如 `src/game.js`）。统一 `ttl_seconds: 86400`；
   `alias` 由人口头指定（默认 `pi-worker`）。
2. **派发**：`send_task({ alias, task, ttl_seconds: 86400, from_session: "指挥室" })`；
   一次派完**停下**，等人工口令再进入下一步。
3. **验收**：收到「验收」口令后，对每个任务 `get_task({ task_id })` 逐个点查，
   期望 `status: "replied"` 且有 `result`。**只信 Hub 返回的任务行**。

派发有两条路：**定向**（上面的 `send_task` 指定 alias）与**池化**（不指定工人、
先入需求池再由操作者手动认领）——池化流程见第 6 节。

## 2. 角色 B：工人（执行者）

工具：`get_inbox` `ack_inbox` `report_status` `report_completion`

**协议流程（顺序执行）**：

1. **建档**（新 alias 必须，之后每次会话建议）：
   `report_status({ resume_id: "<会话唯一ID>", alias: "pi-worker", status: "idle" })`
   —— sessions 表里没有档案时，规划者 `send_task` 会直接报 `alias_not_found`。
2. **收**：`get_inbox({ alias })` 拿消息；任务消息的处理句柄是返回里的 `task_id`。
3. **确认**：`ack_inbox({ alias, message_id: <task_id> })`（任务消息传 `task_id`，
   非任务消息传 `id`）。任务状态 `delivered → acked` 只由这一步推动。
4. **开工**：`report_status({ ..., status: "working", task: "<任务原文全文>" })`
   —— `task` 必须**逐字**等于任务原文，否则任务停在 acked 不进 running。
5. **汇报**：**每个任务单独一次**
   `report_completion({ alias, task: <task_id>, result: "<结果摘要>", artifacts: [...] })`
   —— 传 `task_id` 最稳；传原文 fallback 必须逐字一致。多任务合并一次汇报 = 全部不生效。
6. **收工**：全部完成后再
   `report_status({ ..., status: "idle", task: null })`（report_completion 本身也会把
   session 置 idle）。

## 3. 任务生命周期（状态机）

| 跃迁 | 触发调用 | 要点 |
|---|---|---|
| created → delivered | `send_task` | 在线立即投递；离线返回 202 排队，上线后照投 |
| delivered → acked | `ack_inbox(message_id=task_id)` | 只能从 delivered 起跳 |
| delivered/acked → running | `report_status(status=working + task 匹配)` | task 须等于原文或 task_id |
| 任意非终态 → replied | `report_completion(task 匹配)` | 先按 task_id，再按 to_name+content 精确等值 |
| 任意 → cancelled | `cancel_task` | |
| 超时 → expired | Hub 定时 | TTL 默认 3600s，上限 86400s |
| failed/expired/cancelled → 可重试 | `retry_task` | 固定补 +1h TTL，task_id 不变、inbox 新 id |

**参数铁律（第一轮测试失败的根因，`server/src/tools.ts` 实证）**：

- `report_completion.task` / `report_status(task=working)` 的匹配是**精确等值**：
  先按 `task_id` 匹配，不命中再按 `to_name=alias AND content=task` 找最近一条。
  改写、概括、翻译、多个任务拼一次汇报 → 匹配失败 → 状态永久卡住。
- 修正方式：卡在 acked 就补正确的 completion；坏任务用 `cancel_task` +
  `retry_task` 重来（retry 固定 +1h TTL）。
- 同 `(from, to, content)` 5 分钟内重复 `send_task` 会被去重层拒绝
  （`duplicate_send`）；要重发就改写任务文本或等窗口过。

## 4. 跨机 / 双目录约定

> 下表是 tetris 测试环境的**示例**，路径随项目/机器变化。任何项目都在任意
> 路径下工作，写死路径没有意义——规则只有下面的条目，与具体路径无关。

本示例是**同一仓库的两个 clone**（双机模拟）：

| 角色 | 工作目录（示例） | Git |
|---|---|---|
| 规划者 opencode | `~/Downloads/tetris` | 同一 `main`，push/pull 协作 |
| 工人 pi | `~/Downloads/pi-work/tetris` | 同一 `main`，push/pull 协作 |

- **禁止跨目录假设**：不要读「对方目录」的文件来判断对方状态或结果；
  任务文案必须写「在你的工作目录完成」。
- **禁止写死路径**：任务文案、交付说明里不得出现 `/home/...`、`C:\...`
  之类的绝对路径——你无法验证对方机器的目录结构。即使 `get_all_status`
  显示了对方 `project_dir`，也不要抄进任务（可能是旧记录，换机器即失效）。
- 工件交换只经 `report_completion.result` / `artifacts`（文本/路径列表）与 git push。
- 状态判定只信 Hub：规划者用 `get_task`/`list_tasks`/`get_all_status`；
  工人用 `get_inbox`。

## 5. 新项目接入清单（能力即齐）

其他项目要具备 agent-network 能力只需两步，**不需要任何项目级说明文件**：

1. **接 MCP**（本机全局配置，做一次即可）：见第 0 节接入命令与 token 分层。
2. **引 skill**（随仓库分发）：

```bash
mkdir -p skills .agents/skills
git submodule add git@github.com:pixb/agent-network-skill.git skills/agent-network-skill
ln -s ../../skills/agent-network-skill .agents/skills/agent-network-skill
git add skills .agents/skills && git commit -m "add agent-network-skill"
```

角色、流程、状态机、铁律全部在本 skill 内，由操作者的口令激活。

## 6. 需求池模式：不指定工人的任务（Hub ≥ preview.66）

指挥者两种派发：**定向**（第 1 节）与**池化**（本节）。池化 = 任务先发布为需求池
卡片（`column: pool`），由操作者按各工人的**模型额度**与**繁忙程度**手动认领给具体
工人。需求池是 `requirements_*` 卡片看板，与 tasks 表是两套记录、**之间没有自动桥**
——认领时把卡片正文人肉派成 `send_task`（两步都做，缺一不可）。

- **发布**（规划者/操作者）：
  `requirements_create({ name: "<≤80 字标题>", description: "<任务正文 markdown ≤20k>", column: "pool", priority })`
- **看池**：`requirements_list({ status: "pool" })`
  - list 的过滤参数是 **`status`**，不是 `column`（create/update 两者皆可，list 只认 `status`）；
  - 默认**排除**归档卡，`include_archived: true` 才列出；
  - 分页 `limit`/`cursor`，搜索 `q`，视图默认 summary（正文要 `view: "full"`）。
- **认领**（操作者手动两步）：
  1. 选工人：`get_all_status` 看忙闲、`send_task` 回执的 `target_busy` /
     `est_wait_minutes` 作参考；模型额度由操作者人工判断。
  2. 派活 + 记账：
     `send_task({ alias: <选定工人>, task: <卡片 description 正文>, ttl_seconds: 86400, from_session: "指挥室" })`
     + `requirements_update({ id, column: "doing", agent_owner: { kind: "node", alias } })`
- **验收**：工人回单后 `get_task` 点查 → 过了
  `requirements_update({ id, column: "done" })`；打回 = `cancel_task` + 改写重发
  （第 3 节铁律不变），卡片留在 `doing` 继续跟。
- **注意**：agent 不能删卡，只能 `archived: true` 隐藏；卡片另有 due/checklist/
  tags/participants（人）/external_ref（外部系统幂等同步）等字段按需填。
- **版本前提**：`requirements_*` 自 preview.66 进入主干；升级用
  `anet hub start --version 0.9.0-preview.<N>`（anet 的 floor 兜底版本没有这些
  工具）。pm2 守护时要把 `--version` 写进 ecosystem 的 args，否则重启会回退到
  floor 版本、工具消失。

## Gotchas

- `alias_not_found` = Hub 的 sessions 表没有该 alias 档案；手动工人第一次必须先调一次
  `report_status` 建档。`get_inbox` 不校验 alias，是弱检查点（查不到≠连上）。
- `report_completion` **每任务一次**，聚合汇报无效；`result` 写入 tasks 表只留前
  4000 字符（completions 表存全量）——要点放前面，长报告放 artifacts。
- `report_status` 只认 `ntok_`；utok/atok 调用返回 `network_token_required`。
- TTL 默认 3600 秒，工人没在窗口内回复就变 expired；长任务派发时显式
  `ttl_seconds: 86400`（上限）。
- session 超 5 分钟没刷新即视为离线，但 `send_task` 照样 202 排队并最终投递——
  离线不是失败，别重发（撞 `duplicate_send`）。
- `retry_task` 只允许 failed/expired/cancelled，且固定 +1h TTL（不沿用原 TTL）。
- `send_task` 会触发收件方 AI 处理；`send_message`/`send_reply`/`send_ack` 不触发。
- 消息按 high > normal > low 排序；同优先级按时间。
- Hub 时间是 UTC（本地 UTC+8），对时间戳别直接比较。
- pi 的 codemode 调用形态是 `tools.mcp__commhub__*`，不是裸工具名；
  opencode 端以 MCP 工具列表里的名字为准。
- 任务文案里出现 `/home/...` 之类的绝对路径 = 跨机假设（实测：规划者曾把
  工人的绝对路径写进任务，换机器即坏）。只写「在你的工作目录」+ 相对路径；
  Hub 没有「修改任务」工具，已派任务文案不可变，只能 cancel 后重新 send。
