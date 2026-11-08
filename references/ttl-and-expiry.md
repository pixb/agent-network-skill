# Task validity: write `ttl_seconds` when you dispatch

## What the data looks like (measured)

One production network, id withheld (read 2026-11-04, read-only): of the 200 most recent tasks, 16
were `expired`, with TTL **min 600 s / median 3600 s / max 14400 s**. One batch of 5 tasks dispatched
at 04:01:44 with TTL 7200 s expired together at exactly 06:01:44, and the round sweep emitted the
"5 tasks expired" notification at 06:06:03.

**The default is 3600 s (one hour).** `send_task` in `server/src/tools.ts` declares
`ttl_seconds: z.number().min(1).max(86400).optional()` and inserts
`expires_at = datetime('now', '+${ttl_seconds || 3600} seconds')`. Omitting the parameter is a promise
that the task will be acked and finished within an hour — which a manual node that waits for a human
answer, for material, or for a human to come online almost always misses.

## Three conventions

1. **Write the TTL explicitly**, sized to the work, never inherited from the default: short work
   `ttl_seconds=3600`; same-day work `ttl_seconds=28800`; work that spans days or waits for a human
   `ttl_seconds=86400` (that is the `send_task` ceiling; larger values are refused by Zod).
2. **After an expiry, the next round is a new task, not a retry.** `retry_task` resets `expires_at` to
   `+1 hour` (the retry branch in `tools.ts`) and does not reuse the original TTL — so "retry the
   task that runs for a day" buys you a fresh hour. Re-dispatch long work, with the TTL written out.
3. **Expiry notifications go to the inbox, not to the message stream.** The hub-sent `task_expired` /
   `task_orphan_suspected` land in `user_inbox`, which the Dashboard shows at `/messages/inbox` (that
   is how the 5 notifications above were seen). The Messages page does not show them.

## The long-silence sweep (disabled by default)

`COMMHUB_STALE_OPEN_TASK_HOURS=<N>` (in the hub machine's `~/.commhub/hub.env`): tasks sitting in
`acked` / `running` with no movement for more than N hours are closed out by the 5-minute sweep into
`expired` (max 500 per round, **the dispatcher is not notified**). Default `0` = off, **not set in
production**. Documented suggestion: 72 (`docs-site/docs/deploy/production.md`,
`concepts/task-lifecycle.md`).

Point: this rule **does not replace convention 1**. It governs tasks that already started and then went
silent; TTL expiry happens before it, so turning it on does not make the one-hour expiry problem
disappear. It is a hub-side configuration change: by the repository's rules it is reviewed before it
touches production, and this skill does not apply it on the side.

## A check you can run yourself

```bash
# TTL distribution of the expired tasks in one network (reads the hub, changes nothing)
curl -s -H "Authorization: Bearer $UTOK" \
  "$HUB/api/tasks?network_id=$NET&limit=200" | python3 -c '
import json,sys
from datetime import datetime, timezone
def parse(s): return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
rows=[t for t in json.load(sys.stdin)["tasks"] if t.get("status")=="expired"]
ttl=[(parse(t["expires_at"])-parse(t["created_at"])).total_seconds() for t in rows if t.get("expires_at")]
print("expired:",len(rows),"ttl min/median/max:",min(ttl) if ttl else "-","sorted(ttl)[len(ttl)//2] if ttl else -",max(ttl) if ttl else "-")'
```

A median of 3600 is the signal that everyone is on the default. Turn that into an explicit decision.

## The TTL must cover the node's own finish time (2026-11-06)

The common illusion in a control room: the task is `expired` on the hub side and the node **is still
working**. Nodes on weak hardware running local models hit this most: one context compaction is
minutes (measured on a GTX 1070 8 GB with a 131K context: 7–9 minutes per compaction) while the hub's
default TTL is 3600 s.

The arithmetic to do at dispatch time:

```
ttl_seconds ≥ 2 × (the node's idle budget in seconds)
idle budget = the node runtime's timeout knob / 1000   (e.g. 1800 s ⇒ TTL at least 3600 s)
```

A node runtime names the source of every timeout in its start banner (env > flags > default). Example
banner, the pi runtime:

```
[pi] promptAck=900000ms(env) handshake=45000ms(default) lateAck=30000ms lateGrace=90000ms
[pi] idle=1800000ms(flags.piTimeoutMs) busyPolicy=queue rollover=262144B carry=1200chars
```

A `source=floor` means the value you asked for was shorter than one compaction and was clamped.

**The failure codes a node reports can be copied into an acceptance criterion verbatim** (none of them
is replayable, so a replay would be wasted work): `pi_prompt_ack_timeout` (waiting for the runtime to
accept the prompt timed out; the message names the knob), `pi_prompt_rejected`,
`pi_handshake_timeout`, `pi_runtime_busy` (this round was not submitted under `busyPolicy=skip`).

**"The runtime is busy / compacting" is not a failure.** The node reports the queued state through
`report_status("working", …)` and the task stays `running`. Wait on that state; do not `retry_task` —
a re-send makes the runtime run the same task twice.

Operations page for one slow local runtime: `docs-site/docs/guide/pi-slow-local-model.md`;
measurements and assertions: the hub project's `docs/tests/report-pi-rpc-ack-20261106.txt`.
