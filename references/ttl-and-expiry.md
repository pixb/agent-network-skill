# 任务有效期：派活时要不要写 `ttl_seconds`

## 实测到的形状

生产网络 `net_b91c0d535346`（2026-11-04 读取，只读不改）：最近 200 条任务里 16 条
`expired`，它们的 TTL 是 **最小 600s / 中位 3600s / 最大 14400s**；其中一批 5 条
2026-11-04 04:01:44 派出、TTL 7200s，在 06:01:44 整点集体过期，06:06:03 巡检发出
「5 个任务已过期」的通知。

**默认值就是 3600s（一小时）**：`server/src/tools.ts` 的 `send_task` 写
`ttl_seconds: z.number().min(1).max(86400).optional()`，插入时
`expires_at = datetime('now', '+${ttl_seconds || 3600} seconds')`。派活时不写这个参数，
就等于承诺「一小时内会被 ack 并跑完」。手动节点等人回答、等素材、等人上线，一小时的
默认值几乎必然过期。

## 三条约定

1. **派活时显式写 TTL**，按工作时长给，不要靠默认值：短任务 `ttl_seconds=3600`；
   当天要完成的 `ttl_seconds=28800`；跨天/需要人回话的 `ttl_seconds=86400`（这是
   `send_task` 的上限，超过会被 Zod 拒）。
2. **过期后的下一轮是新任务，不是重试。** `retry_task` 把 `expires_at` 重置成
   `+1 hour`（`tools.ts` 的 retry 分支），不沿用原 TTL —— 所以「retry 一个要跑一天的
   任务」得到的是新的一小时有效期。长跑的活重新派，显式写 TTL。
3. **过期通知进的是收件箱，不是消息流。** Hub 代发的 `task_expired` /
   `task_orphan_suspected` 落 `user_inbox`，在 Dashboard 的 `/messages/inbox` 里看得见
   （上面那批 5 条过期通知就是这么看到的）。Messages 页看不到它们。

## 巡检的长时间无动静规则（默认关闭）

`COMMHUB_STALE_OPEN_TASK_HOURS=<N>`（写进 hub 机器的 `~/.commhub/hub.env`）：
`acked` / `running` 状态、超过 N 小时毫无动静的任务，由每 5 分钟的巡检收口成
`expired`（每轮最多 500 条，**不通知派活方**）。默认 `0` = 关闭，**生产当前未设置**。
文档建议值 72（`docs-site/docs/deploy/production.md`、`concepts/task-lifecycle.md`）。

要点：这条规则**不能替代第 1 条**。它管的是「已开工后静默」的任务，TTL 过期发生在
它之前；把它打开不会让一小时过期的问题消失。它是 hub 侧配置变更，按仓库规则要先评审
再改生产，不在本 skill 的约定里顺手执行。

## 一条能自查的判据

```bash
# 某网络里过期任务的 TTL 分布（读 hub，不改任何状态）
curl -s -H "Authorization: Bearer $UTOK" \
  "$HUB/api/tasks?network_id=$NET&limit=200" | python3 -c '
import json,sys
from datetime import datetime, timezone
def parse(s): return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
rows=[t for t in json.load(sys.stdin)["tasks"] if t.get("status")=="expired"]
ttl=[(parse(t["expires_at"])-parse(t["created_at"])).total_seconds() for t in rows if t.get("expires_at")]
print("expired:",len(rows),"ttl min/median/max:",min(ttl) if ttl else "-","sorted(ttl)[len(ttl)//2] if ttl else -",max(ttl) if ttl else "-")'
```

`ttl median` 落在 3600 上，就是「大家都在用默认值」的信号；把它变成显式决定即可。
