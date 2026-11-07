#!/usr/bin/env bash
# manual_node_scenario.sh — run one manual-node scenario against a throwaway
# hub and write a machine-readable result.
#
# usage:
#   manual_node_scenario.sh --input <scenario.json> [--output <result.json>]
#
# The input file is JSON: {"scenario": "<name>"} — and nothing else. The hub source is
# never named in a golden case: a golden case that embeds one machine's path is a case
# that only passes on that machine. Resolve it from ANET_E2E_HUB_SRC, else relative to
# this skill directory (see HUB_SRC below).
# where <name> is one of:
#   full-lifecycle   register, dispatch, ack, working, reply  -> task ends replied
#   stuck-delivered  register, dispatch, nothing else         -> task ends delivered
#   skipped-working  register, dispatch, reply (no working)   -> task ends replied,
#                                                             and reply warns that
#                                                             the run was invisible
#   chat-and-finished register, dispatch, a chat message from
#                    a human, a reply that leaves the task's
#                    inbox row behind                 -> inbox tells the two
#                                                             kinds apart, and
#                                                             `dm` reaches the human
#   terminal-refused register, dispatch, ack, working, reply,
#                    then a second reply                     -> the second reply is refused
#   short-pointer-payload the dispatched body is a 4-line pointer built by
#                    scripts/anet_payload.sh (summary + file + seg + sha12), the
#                    spec lives in a payload file segment; the scenario asserts
#                    the stored body is within budget and carries no absolute
#                    path, that the pointer verifies against the file, that a
#                    wrong sha12 is refused, that an over-long summary is
#                    refused, and that the short body round-trips byte-exactly
#                    through acked -> running -> replied
#
# The result JSON is: {"scenario", "ok", "final_status", "transitions": [...],
#                      "verdicts": [...], "error": null}
#
# The hub is booted from the commhub-server source tree (ANET_E2E_HUB_SRC, or the
# candidates resolved below, or an input file's legacy "hub_source" field).
# the default paths below) into a throwaway database, so nothing touches a
# real hub.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/anet_manual_node.sh"
PAYLOAD_SH="$SKILL_DIR/scripts/anet_payload.sh"

INPUT=""
OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$INPUT" ] || { echo "usage: --input <scenario.json> [--output <result.json>]" >&2; exit 2; }
[ -f "$INPUT" ] || { echo "no such scenario file: $INPUT" >&2; exit 2; }

read_json() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],''))" "$INPUT" "$1"; }
SCENARIO="$(read_json scenario)"
HUB_SRC="${ANET_E2E_HUB_SRC:-$(read_json hub_source)}"
[ -n "$SCENARIO" ] || { echo "the scenario file has no \"scenario\" field" >&2; exit 2; }
if [ -z "$HUB_SRC" ]; then
  # The hub is booted from the commhub-server source tree. Nothing here may name a
  # particular machine: resolve relative to this skill directory, so a clone of the
  # parent repo (skill at <repo>/.agents/skills/agent-network-skill) finds the server
  # on any machine, and ANET_E2E_HUB_SRC overrides it anywhere else.
  for cand in "$SKILL_DIR/../../../server" "$SKILL_DIR/../../server" "$PWD/server" \
              "$HOME/agent-network/server"; do
    [ -f "$cand/bin/commhub.ts" ] && { HUB_SRC="$cand"; break; }
  done
fi
# ANET_E2E_HUB_SRC may name the repo root instead of the server subdirectory.
[ -f "${HUB_SRC:-}/bin/commhub.ts" ] || { [ -f "${HUB_SRC:-}/server/bin/commhub.ts" ] && HUB_SRC="$HUB_SRC/server"; }
[ -n "$HUB_SRC" ] && [ -f "$HUB_SRC/bin/commhub.ts" ] || {
  echo "no commhub-server source found; set ANET_E2E_HUB_SRC" >&2; exit 2; }

WORK="$(mktemp -d /tmp/anet-manual-scenario.XXXXXX)"
PORT="${ANET_E2E_PORT:-19735}"
HUB="http://127.0.0.1:$PORT"
DB="$WORK/hub.db"
TRANSITIONS=""
VERDICTS=""
CHECKS=""
FINAL_STATUS=""

cleanup() {
  [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null || true
  [ -n "$OUTPUT" ] && [ -f "$OUTPUT" ] || rm -rf "$WORK"
}
trap cleanup EXIT

write_result() {
  local ok="$1" err="${2:-}"
  [ -n "$OUTPUT" ] || return 0
  python3 - "$OUTPUT" "$SCENARIO" "$ok" "$FINAL_STATUS" "$TRANSITIONS" "$VERDICTS" "$err" "$CHECKS" <<'PY'
import json, sys
out, scenario, ok, final, transitions, verdicts, err, checks = sys.argv[1:9]
def load(s):
    if not s: return []
    return [x for x in s.split("|") if x]
def load_checks(s):
    if not s: return {}
    return {k: (v == "true") for k, v in (pair.split("=", 1) for pair in s.split("|") if pair)}
json.dump({
    "scenario": scenario,
    "ok": ok == "true",
    "final_status": final,
    "transitions": load(transitions),
    "verdicts": load(verdicts),
    "checks": load_checks(checks),
    "error": err or None,
}, open(out, "w"), indent=2)
open(out, "a").write("\n")
PY
}

fail() { write_result false "$1"; echo "scenario failed: $1" >&2; exit 1; }

# ── boot the throwaway hub ────────────────────────────────────────────────
COMMHUB_DB="$DB" bun run "$HUB_SRC/bin/commhub.ts" \
  --port "$PORT" --host 127.0.0.1 --db "$DB" --dev-open >"$WORK/hub.log" 2>&1 &
HUB_PID=$!
for _ in $(seq 1 60); do
  curl -sf "$HUB/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "$HUB/health" >/dev/null 2>&1 || { fail "the throwaway hub did not come up"; }

REG=$(curl -s -X POST "$HUB/api/auth/register" -H 'Content-Type: application/json' \
  -d '{"username":"scenario-user","password":"scenario-password-123"}')
UTOK=$(echo "$REG" | python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))")
[ -n "$UTOK" ] || fail "could not register a user: $REG"

PROJ="$WORK/project"
mkdir -p "$PROJ"
export ANET_MANUAL_USER_TOKEN="$UTOK"
"$SCRIPT" init --node scenario-node --project-root "$PROJ" --hub "$HUB" >"$WORK/init.log" 2>&1 \
  || fail "init failed: $(tail -1 "$WORK/init.log")"

NODEDIR="$PROJ/.anet/nodes/scenario-node"
NET=$(python3 -c "import json;print(json.load(open('$NODEDIR/config.json'))['network_id'])")
run() { "$SCRIPT" "$@" --project-root "$PROJ" --hub "$HUB"; }

task_status() {
  curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$1?network_id=$NET" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['task']['status'])"
}
dispatch() {
  python3 - "$HUB" "$UTOK" "$NET" "$1" <<'PY'
import json, sys, urllib.request
hub, utok, net, body = sys.argv[1:5]
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "scenario-node", "task": body, "network_id": net}).encode())
print(json.load(urllib.request.urlopen(req))["task_id"])
PY
}
record() { TRANSITIONS="${TRANSITIONS:+$TRANSITIONS|}$1"; }
# The primary task's lifecycle is recorded as "status:<s>"; any other task
# involved in the scenario is recorded as "other:<s>", so the protocol check
# only ever looks at one task's path.
record_status() { record "status:$(task_status "$1")"; }
record_other() { record "other:$(task_status "$1")"; }
record_verdict() { VERDICTS="${VERDICTS:+$VERDICTS|}$1"; }
# check <name> <true|false> — a fact this scenario verified against the hub.
check() { CHECKS="${CHECKS:+$CHECKS|}$1=$2"; }

BODY="scenario body: first line
second line, with punctuation & 特殊字符
third line"
PAYLOAD="commhub_tasks/r01/spec.md"
if [ "$SCENARIO" = "short-pointer-payload" ]; then
  # The long text is a file segment; the parameter is only a pointer at it.
  mkdir -p "$PROJ/commhub_tasks/r01"
  cat > "$PROJ/$PAYLOAD" <<'EOF'
# 第 1 轮任务规格

## seg-01 给导入模块补单元测试
步骤：为 readRows() 补 3 个用例，覆盖空文件、重复表头、超长行。
验收: 3 个用例全绿，且失败时报错指向具体行号。

## seg-02 更新使用文档
步骤：把 readRows() 的参数与默认值写进 docs/guide.md。
验收: 文档构建通过，示例可复制运行。
EOF
  (
    cd "$PROJ" && git init -q . && printf '.anet/\n' > .gitignore && git add -A &&
    git -c user.email=scenario@local -c user.name=scenario commit -qm "payload file"
  ) || fail "could not create a git project for the payload file"
  BRANCH="$(git -C "$PROJ" rev-parse --abbrev-ref HEAD)"
  POINTER_JSON="$("$PAYLOAD_SH" compose --project-root "$PROJ" --file "$PAYLOAD" --seg seg-01 \
      --summary "第1轮 seg-01：给导入模块补单元测试，3 个用例全绿" --branch "$BRANCH" --json 2>/dev/null)" \
    || fail "anet_payload.sh compose refused a body it must accept: $POINTER_JSON"
  BODY="$(printf '%s' "$POINTER_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"])')"
  [ -n "$BODY" ] || fail "compose produced no body text"
fi
TASK_ID="$(dispatch "$BODY")"
record "dispatched"
record_status "$TASK_ID"

if [ "$SCENARIO" = "stuck-delivered" ]; then
  run check >"$WORK/check.log" 2>&1 || fail "check failed"
  grep -q "nobody acked it" "$WORK/check.log" \
    || fail "check did not diagnose the un-acked task: $(tail -3 "$WORK/check.log")"
  record_verdict "$(grep '^verdict:' "$WORK/check.log" | head -1 | sed 's/^verdict: //' | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g; s/after [0-9]+s/after <n>s/')"
  FINAL_STATUS="$(task_status "$TASK_ID")"
  check "stuck_task_stays_delivered" "$([ "$FINAL_STATUS" = "delivered" ] && echo true || echo false)"
  check "stuck_task_is_diagnosed" true
  check "task_reaches_replied" false
  check "terminal_task_refuses_second_reply" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── acked-by-other: somebody else acked the task under our nose ────────────
if [ "$SCENARIO" = "acked-by-other" ]; then
  # send_ack updates the task row by id without checking who owns it, so
  # another node can ack a task that sits in OUR inbox.
  OTHER_NTOK=$(curl -s -X POST "$HUB/api/auth/node-token" -H "Authorization: Bearer $UTOK" \
    -H 'Content-Type: application/json' \
    -d "{\"network_id\":\"$NET\",\"node_name\":\"scenario-other\",\"node_id\":\"n_scenother01\"}" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
  python3 - "$HUB" "$OTHER_NTOK" "$TASK_ID" <<'PY' >/dev/null
import json, sys, urllib.request
hub, ntok, task_id = sys.argv[1:4]
req = urllib.request.Request(hub + "/mcp", method="POST",
    headers={"Authorization": "Bearer " + ntok, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"},
    data=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
        "params":{"name":"send_ack","arguments":{"task_id":task_id}}}).encode())
urllib.request.urlopen(req).read()
PY
  record_status "$TASK_ID"

  if run ack "$TASK_ID" >"$WORK/hijack-ack.log" 2>&1; then
    fail "acking a task somebody else acked should have been refused"
  fi
  grep -q "acked by somebody else" "$WORK/hijack-ack.log" \
    || fail "unexpected ack error: $(tail -1 "$WORK/hijack-ack.log")"
  record_verdict "ack refused: $(tail -1 "$WORK/hijack-ack.log" | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g')"

  if run working "$TASK_ID" >"$WORK/hijack-working.log" 2>&1; then
    fail "working a task somebody else acked should have been refused"
  fi
  grep -q "acked by somebody else" "$WORK/hijack-working.log" \
    || fail "unexpected working error: $(tail -1 "$WORK/hijack-working.log")"

  run check >"$WORK/check.log" 2>&1 || fail "check failed"
  grep -q "ACKED BY SOMEONE ELSE" "$WORK/check.log" \
    || fail "check did not flag the hijacked task: $(tail -5 "$WORK/check.log")"

  FINAL_STATUS="$(task_status "$TASK_ID")"
  check "hijacked_task_is_refused" true
  check "task_reaches_replied" false
  check "stuck_task_is_diagnosed" false
  check "terminal_task_refuses_second_reply" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── reassigned-away: the task leaves our inbox silently ───────────────────
if [ "$SCENARIO" = "reassigned-away" ]; then
  run inbox >/dev/null 2>&1 || fail "inbox failed"
  python3 - "$HUB" "$UTOK" "$NET" "$TASK_ID" <<'PY' >/dev/null
import json, sys, urllib.request
hub, utok, net, task_id = sys.argv[1:5]
req = urllib.request.Request(hub + "/mcp", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"},
    data=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
        "params":{"name":"reassign_task","arguments":{"task_id":task_id,
        "new_alias":"scenario-other","network_id":net}}}).encode())
urllib.request.urlopen(req).read()
PY
  run check >"$WORK/check.log" 2>&1 || fail "check failed"
  grep -q "left behind" "$WORK/check.log" \
    || fail "check did not name the vanished task: $(tail -5 "$WORK/check.log")"
  record_verdict "$(grep '^verdict:' "$WORK/check.log" | grep 'disappeared' | head -1 | sed 's/^verdict: //' | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g')"
  FINAL_STATUS="$(task_status "$TASK_ID")"
  check "vanished_task_is_named" true
  check "task_reaches_replied" false
  check "stuck_task_is_diagnosed" false
  check "terminal_task_refuses_second_reply" false
  check "hijacked_task_is_refused" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── dm-visible-to-manager: 节点提问走 dm，经理在收件箱里看得见 ───────────
# 钉的是本仓约定的那条路：中途提问必须用 send_desktop_message（anet_manual_node.sh
# 的 `dm`），它是唯一能到人手里的消息工具；而它落的是 user_inbox，只有
# `?scope=user` 返回 —— Messages 页读的 `?alias=` 里没有它。两条都要钉住：
# 只钉「scope=user 看得见」，将来有人把收件箱页改成读 alias 消息，测试不会红。
if [ "$SCENARIO" = "dm-visible-to-manager" ]; then
  run ack "$TASK_ID" >/dev/null 2>&1 || fail "ack failed"
  record_status "$TASK_ID"
  run working "$TASK_ID" "scenario: started the first line" >/dev/null 2>&1 || fail "working failed"
  QUESTION="scenario question: which output directory should 033 use?"
  run dm scenario-user "$QUESTION" >"$WORK/dm.log" 2>&1 \
    || fail "dm failed: $(tail -1 "$WORK/dm.log")"
  record "asked"
  record_status "$TASK_ID"

  USER_ROWS=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/messages?scope=user&network_id=$NET")
  check "dm_visible_in_user_scope" "$(echo "$USER_ROWS" | grep -qF "$QUESTION" && echo true || echo false)"
  ALIAS_ROWS=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/messages?alias=scenario-user&network_id=$NET")
  check "dm_absent_from_alias_messages" "$(echo "$ALIAS_ROWS" | grep -qF "$QUESTION" && echo false || echo true)"

  # 提问不是交付：任务必须还在跑，经理才有得可派。
  FINAL_STATUS="$(task_status "$TASK_ID")"
  [ "$FINAL_STATUS" = "running" ] \
    || fail "asking must leave the task running, got $FINAL_STATUS"
  FOLLOW_ID="$(dispatch "scenario follow-up: use /work/out")"
  record "followup-dispatched"
  run inbox >"$WORK/inbox.log" 2>&1 || fail "inbox failed"
  grep -q "$FOLLOW_ID" "$WORK/inbox.log" \
    || fail "the follow-up never reached the node's inbox: $(tail -3 "$WORK/inbox.log")"
  # 跟进任务是**另一条**任务：记成 other，不混进主任务的状态轨迹（协议检查只读
  # 一个任务的路径，两条任务拼起来会得到一条不存在的路径）。
  record_other "$FOLLOW_ID"

  check "ask_keeps_task_dispatchable" true
  check "task_reaches_replied" false
  check "terminal_task_refuses_second_reply" false
  check "stuck_task_is_diagnosed" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── ask-by-reply-strands: 把提问写成 reply，任务当场终结 ──────────────────
if [ "$SCENARIO" = "ask-by-reply-strands" ]; then
  run ack "$TASK_ID" >/dev/null 2>&1 || fail "ack failed"
  run working "$TASK_ID" "scenario: need a decision" >/dev/null 2>&1 || fail "working failed"
  QUESTION="scenario question asked as a reply: which output directory?"
  run reply "$TASK_ID" "$QUESTION" >/dev/null 2>&1 || fail "reply failed"
  record "asked-as-reply"
  record_status "$TASK_ID"

  # 它在 Tasks 页的读路径里（作为任务结果），不在 Messages 页的读路径里，也不在
  # 收件箱页的读路径里。三条一起钉：reply 落 completions + 任务的 result（实测），
  # inbox / user_inbox 一行都不会多。哪条读路径变了，测试都会红。
  check "reply_visible_in_task_result" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/tasks?network_id=$NET&limit=50" | grep -qF "$QUESTION" && echo true || echo false)"
  check "reply_absent_from_alias_messages" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/messages?alias=scenario-user&network_id=$NET" | grep -qF "$QUESTION" && echo false || echo true)"
  check "reply_absent_from_user_scope" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/messages?scope=user&network_id=$NET" | grep -qF "$QUESTION" && echo false || echo true)"

  # 代价一：任务终结，这条对话没有「下一轮」。
  FINAL_STATUS="$(task_status "$TASK_ID")"
  [ "$FINAL_STATUS" = "replied" ] \
    || fail "a reply must close the task, got $FINAL_STATUS"
  if run reply "$TASK_ID" "scenario: follow-up question" >"$WORK/second-reply.log" 2>&1; then
    fail "a terminal task accepted a second reply"
  fi
  record_verdict "second reply refused: $(tail -1 "$WORK/second-reply.log" | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g')"

  # 代价二：没有未读。人在自己的收件箱里看不到有一条问题在等回答（实测
  # user_inbox 为空），所以问题只能靠人主动去看任务详情才会被发现。
  check "question_creates_no_unread_for_the_human" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/messages?scope=user&unacked=1&network_id=$NET" | grep -qF "$QUESTION" && echo false || echo true)"
  check "terminal_task_refuses_second_reply" true
  check "task_reaches_replied" true
  check "dm_visible_in_user_scope" false
  check "dm_absent_from_alias_messages" false
  check "ask_keeps_task_dispatchable" false
  check "stuck_task_is_diagnosed" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── ask-by-send-reply-visible: 写成 send_reply 的问题进得了别名收件箱 ──────
# 与 ask-by-reply-strands 只差一个参数：`--via send_reply`。两个 case 一起钉出
# 两条交付通道的真实落点（reply 默认走 report_completion，只进 completions）。
if [ "$SCENARIO" = "ask-by-send-reply-visible" ]; then
  run ack "$TASK_ID" >/dev/null 2>&1 || fail "ack failed"
  run working "$TASK_ID" "scenario: need a decision" >/dev/null 2>&1 || fail "working failed"
  QUESTION="scenario question sent via send_reply: which output directory?"
  run reply "$TASK_ID" "$QUESTION" --via send_reply >/dev/null 2>&1 || fail "send_reply failed"
  record "asked-via-send-reply"
  record_status "$TASK_ID"

  check "send_reply_visible_in_alias_messages" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/messages?alias=scenario-user&network_id=$NET" | grep -qF "$QUESTION" && echo true || echo false)"
  check "send_reply_visible_in_task_result" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/tasks?network_id=$NET&limit=50" | grep -qF "$QUESTION" && echo true || echo false)"
  check "send_reply_absent_from_user_scope" "$(curl -s -H "Authorization: Bearer $UTOK" \
    "$HUB/api/messages?scope=user&network_id=$NET" | grep -qF "$QUESTION" && echo false || echo true)"

  # 它仍然是终态：send_reply 把任务关到 replied，所以「问一句」不能拿它当提问工具。
  FINAL_STATUS="$(task_status "$TASK_ID")"
  [ "$FINAL_STATUS" = "replied" ] || fail "send_reply must close the task, got $FINAL_STATUS"
  check "terminal_task_refuses_second_reply" false
  check "task_reaches_replied" true
  check "dm_visible_in_user_scope" false
  check "dm_absent_from_alias_messages" false
  check "ask_keeps_task_dispatchable" false
  check "stuck_task_is_diagnosed" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── two-tasks: one node, one slot, no parallelism ─────────────────────────
if [ "$SCENARIO" = "two-tasks" ]; then
  SECOND_ID="$(dispatch "a second task that must wait for the slot")"
  record_other "$SECOND_ID"
  run ack "$TASK_ID" >/dev/null 2>&1 || fail "ack failed"
  record_status "$TASK_ID"
  run working "$TASK_ID" 30 >/dev/null 2>&1 || fail "working failed"
  record_status "$TASK_ID"

  if run working "$SECOND_ID" >"$WORK/second.log" 2>&1; then
    fail "working a second task in parallel should have been refused"
  fi
  grep -q "one node runs one task at a time" "$WORK/second.log" \
    || fail "unexpected refusal text: $(tail -1 "$WORK/second.log")"
  record_verdict "second task refused: $(tail -1 "$WORK/second.log" | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g')"
  SECOND_STATUS="$(task_status "$SECOND_ID")"
  [ "$SECOND_STATUS" = "delivered" ] \
    || fail "the refused task must stay delivered (it is $SECOND_STATUS)"

  run check >"$WORK/check.log" 2>&1 || fail "check failed"
  grep -q "IN THE SLOT" "$WORK/check.log" \
    || fail "check did not show which task holds the slot: $(tail -5 "$WORK/check.log")"
  grep -q "only ONE slot" "$WORK/check.log" \
    || fail "check did not warn that the tasks will not run in parallel: $(tail -5 "$WORK/check.log")"

  # finishing the first task frees the slot for the second
  run reply "$TASK_ID" "first task done" >/dev/null 2>&1 || fail "reply failed"
  record_status "$TASK_ID"
  run ack "$SECOND_ID" >/dev/null 2>&1 || fail "ack of the second task failed"
  run working "$SECOND_ID" 10 >/dev/null 2>&1 || fail "working of the second task failed"
  record_other "$SECOND_ID"

  FINAL_STATUS="$(task_status "$TASK_ID")"
  check "second_task_is_refused" true
  check "task_reaches_replied" true
  check "result_stored_on_task_row" true
  check "transitions_observed" true
  check "stuck_task_is_diagnosed" false
  check "terminal_task_refuses_second_reply" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── chat-and-finished: a message row and a finished task row in the inbox ──
# Two inbox kinds that are NOT work, and the operator must be able to tell
# them apart:
#   · a chat row (type=message) has no task id, so it cannot be answered with
#     `reply`/`send_reply` (both resolve the id against the tasks table) —
#     it needs `dm <username>`, which reaches a human;
#   · a task that was closed without being acked keeps its inbox row on the
#     hub forever, so a finished task shows up next to real work.
if [ "$SCENARIO" = "chat-and-finished" ]; then
  # A human sends the node a chat message.
  python3 - "$HUB" "$UTOK" "$NET" <<'PY' >"$WORK/msgid"
import json, sys, urllib.request
hub, utok, net = sys.argv[1:4]
req = urllib.request.Request(hub + "/mcp", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"},
    data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "send_message", "arguments": {
            "alias": "scenario-node", "message": "方案确认一下", "network_id": net}}}).encode())
raw = urllib.request.urlopen(req).read().decode()
frames = [l[5:].strip() for l in raw.split("\n") if l.startswith("data:")]
msg = json.loads("".join(frames) if frames else raw)
print(json.loads(msg["result"]["content"][0]["text"]).get("message_id", ""))
PY
  MSG_ID="$(cat "$WORK/msgid")"
  [ -n "$MSG_ID" ] || fail "could not send a chat message to the node"

  # A task that is closed WITHOUT being acked keeps its inbox row on the hub.
  run reply "$TASK_ID" "the work is finished" >"$WORK/reply.log" 2>&1 \
    || fail "reply failed: $(tail -1 "$WORK/reply.log")"
  record_status "$TASK_ID"

  # The inbox must label both kinds: the chat row and the finished task.
  run inbox >"$WORK/inbox.log" 2>&1 || fail "inbox failed"
  grep -q "type    : message" "$WORK/inbox.log" \
    || fail "inbox did not show the chat row: $(tail -5 "$WORK/inbox.log")"
  grep -q "FINISHED" "$WORK/inbox.log" \
    || fail "inbox did not mark the finished task: $(tail -5 "$WORK/inbox.log")"
  # …and must not offer `working` for a task that is already closed.
  if grep -q "working $TASK_ID" "$WORK/inbox.log"; then
    fail "inbox offered to start a task that is already finished: $(tail -8 "$WORK/inbox.log")"
  fi
  # …but must point at `dm` for the chat row.
  grep -q "dm scenario-user" "$WORK/inbox.log" \
    || fail "inbox did not point at dm for the chat row: $(tail -8 "$WORK/inbox.log")"
  record_verdict "inbox separates chat and finished rows"

  # `reply` on a message id must say what to use instead, not just fail.
  if run reply "$MSG_ID" "谢谢" >"$WORK/reply-msg.log" 2>&1; then
    fail "replying to a chat message should have been refused"
  fi
  grep -q "is a message in your inbox" "$WORK/reply-msg.log" \
    || fail "reply did not explain that a message has no task id: $(tail -2 "$WORK/reply-msg.log")"
  grep -q "dm scenario-user" "$WORK/reply-msg.log" \
    || fail "reply did not point at dm: $(tail -2 "$WORK/reply-msg.log")"

  # `say` cannot reach a human (no sessions row) — it must say so and point
  # at `dm` rather than leaving the operator with a bare alias_not_found.
  if run say scenario-user "你好" >"$WORK/say.log" 2>&1; then
    fail "say to a human should have been refused"
  fi
  grep -q "not a node alias" "$WORK/say.log" \
    || fail "say did not explain that a human is not a node: $(tail -2 "$WORK/say.log")"
  grep -q "dm scenario-user" "$WORK/say.log" \
    || fail "say did not point at dm: $(tail -2 "$WORK/say.log")"

  # `dm` is the command that actually reaches the human.
  run dm scenario-user "收到，方案如下" >"$WORK/dm.log" 2>&1 \
    || fail "dm failed: $(tail -2 "$WORK/dm.log")"
  grep -q "sent to scenario-user" "$WORK/dm.log" \
    || fail "dm did not report the send: $(tail -2 "$WORK/dm.log")"

  # The human really received it.
  USER_INBOX=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/messages?scope=user&since=2020-01-01%2000:00:00" \
    | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('messages',[])))")
  [ "${USER_INBOX:-0}" -ge 1 ] || fail "the human never received the dm"

  # check must count the chat row separately from the open tasks.
  run check >"$WORK/check.log" 2>&1 || fail "check failed"
  grep -q "chat message" "$WORK/check.log" \
    || fail "check did not report the chat row: $(tail -8 "$WORK/check.log")"

  FINAL_STATUS="$(task_status "$TASK_ID")"
  [ "$FINAL_STATUS" = "replied" ] \
    || fail "the task did not reach replied (it is $FINAL_STATUS)"
  check "chat_row_is_labelled" true
  check "finished_task_row_is_labelled" true
  check "chat_row_points_at_dm" true
  check "dm_reaches_the_human" true
  check "task_reaches_replied" true
  check "stuck_task_is_diagnosed" false
  check "terminal_task_refuses_second_reply" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── short-pointer-payload: the parameter is a pointer, the spec is a file ──
# The rule under test (SKILL.md §1.1, §1.2): the dispatched body stays short and
# points at a payload-file segment; the worker verifies that pointer before it
# works, and the short body is exactly what lets `working` echo it byte-for-byte
# and flip the task acked -> running.
if [ "$SCENARIO" = "short-pointer-payload" ]; then
  STORED=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$TASK_ID?network_id=$NET" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['task']['content'])")
  # The budget is asserted through the script's own guard, so the test measures the
  # body exactly the way compose measures it: characters counted in python (a C
  # locale counts bytes, which would inflate a CJK body ~3x and make the assertion
  # depend on the machine running the test), and the absolute-path rule read from
  # one place instead of duplicated here.
  "$PAYLOAD_SH" guard --body "$STORED" >"$WORK/guard.log" 2>&1 \
    || fail "the dispatched body breaks the parameter budget: $(cat "$WORK/guard.log")"
  case "$STORED" in
    *"file: $PAYLOAD"*) ;;
    *) fail "the body does not point at the payload file: $STORED" ;;
  esac
  SHA_BODY="$(printf '%s' "$STORED" | python3 -c 'import re,sys;m=re.search(r"sha12:\s*([0-9a-f]{12})", sys.stdin.read());print(m.group(1) if m else "")')"
  [ -n "$SHA_BODY" ] || fail "the body carries no sha12: $STORED"

  # the pointer is verifiable against the file the worker pulled
  "$PAYLOAD_SH" verify --project-root "$PROJ" --file "$PAYLOAD" --seg seg-01 \
    --sha12 "$SHA_BODY" >"$WORK/verify.log" 2>&1 \
    || fail "verify refused the revision the pointer names: $(tail -2 "$WORK/verify.log")"
  # a wrong revision is refused, so a worker never works on a guess
  if "$PAYLOAD_SH" verify --project-root "$PROJ" --file "$PAYLOAD" --seg seg-01 \
       --sha12 000000000000 >"$WORK/verify-bad.log" 2>&1; then
    fail "verify accepted a sha12 that does not match the file"
  fi
  # the guard that keeps the parameter short really fires
  if "$PAYLOAD_SH" compose --project-root "$PROJ" --file "$PAYLOAD" --seg seg-01 \
       --summary "$(python3 -c 'print("字"*81)')" >"$WORK/compose-long.log" 2>&1; then
    fail "compose accepted an 81-character summary line"
  fi
  # and the guard reports the budget it measured, so the verdict is a real sentence
  BUDGET_JSON="$("$PAYLOAD_SH" guard --body "$STORED" --json 2>/dev/null)"
  FIRST_LINE="$(printf '%s' "$BUDGET_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["first_line_chars"])')"
  BODY_CHARS="$(printf '%s' "$BUDGET_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["chars"])')"
  record_verdict "$(printf '%s' "body $BODY_CHARS chars, summary line $FIRST_LINE chars" | sed -E 's/[0-9]+/<n>/g')"

  run ack "$TASK_ID" >/dev/null 2>&1 || fail "ack failed"
  record_status "$TASK_ID"
  # `working` fetches the stored body and sends it back unchanged: with a short
  # body the exact-equality match is reproducible, so the task flips to running
  run working "$TASK_ID" 20 >/dev/null 2>&1 \
    || fail "working failed, the short body did not match byte-for-byte"
  record_status "$TASK_ID"
  run reply "$TASK_ID" "seg-01 done: 3 unit tests green, docs updated" >"$WORK/reply.log" 2>&1 \
    || fail "reply failed: $(tail -1 "$WORK/reply.log")"
  record_status "$TASK_ID"
  FINAL_STATUS="$(task_status "$TASK_ID")"
  [ "$FINAL_STATUS" = "replied" ] || fail "the task did not reach replied (it is $FINAL_STATUS)"

  RESULT=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$TASK_ID?network_id=$NET" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['task']['result'])")
  case "$RESULT" in *"seg-01 done"*) ;; *) fail "the result was not stored on the task row" ;; esac

  check "payload_body_within_budget" true
  check "payload_first_line_is_summary" true
  check "payload_pointer_is_verifiable" true
  check "payload_wrong_revision_is_refused" true
  check "compose_refuses_long_summary" true
  check "task_reaches_replied" true
  check "result_stored_on_task_row" true
  check "stuck_task_is_diagnosed" false
  check "terminal_task_refuses_second_reply" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

# ── skipped-working: the hub lets a task skip straight to replied ─────────
# The failure this scenario pins down: a manual node reads the inbox, does the
# work, and replies — never calling `working`. The hub ACCEPTS that (report_
# completion matches status IN ('delivered','acked','running')), so the reply
# lands and the run is silently invisible: the task sat in 'delivered' the
# whole time and the planner saw an idle node. `reply` must warn.
if [ "$SCENARIO" = "skipped-working" ]; then
  run inbox >"$WORK/inbox.log" 2>&1 || fail "inbox failed"
  # The inbox must point at the next step, or an operator has no way to learn
  # that reading the inbox is not the same as starting the work. The command
  # is printed ready to run (it carries --node), so it can be copied as-is.
  grep -q "working $TASK_ID 0 --node scenario-node" "$WORK/inbox.log" \
    || fail "inbox did not print the next step (working $TASK_ID): $(tail -5 "$WORK/inbox.log")"

  # No ack, no working — go straight to reply, exactly like the production
  # incident this scenario came from.
  run reply "$TASK_ID" "scenario done: the work was finished" >"$WORK/reply.log" 2>&1 \
    || fail "reply failed: $(tail -1 "$WORK/reply.log")"
  record_status "$TASK_ID"

  grep -q "warning: task $TASK_ID was closed while still 'delivered'" "$WORK/reply.log" \
    || fail "reply did not warn that working was skipped: $(tail -5 "$WORK/reply.log")"
  record_verdict "reply warned: $(grep '^warning: task' "$WORK/reply.log" | head -1 | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g')"

  # The task still reached a terminal state — the reply is not blocked, the
  # work was really done.
  FINAL_STATUS="$(task_status "$TASK_ID")"
  [ "$FINAL_STATUS" = "replied" ] \
    || fail "the task did not reach replied (it is $FINAL_STATUS)"

  # …but it never passed through acked/running: that is the whole point.
  EVENTS=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/task_events?task_id=$TASK_ID" \
    | python3 -c "
import json,sys
print(' '.join(e.get('event_type','') for e in json.load(sys.stdin).get('events',[])))
")
  case "$EVENTS" in
    *task.ack*) fail "the task was acked, but this scenario skips the ack too: $EVENTS" ;;
  esac
  case "$EVENTS" in
    *task.started*) fail "the task reached running, but this scenario skips working too: $EVENTS" ;;
  esac

  check "skipped_working_is_warned" true
  check "skipped_working_task_still_replies" true
  check "skipped_working_never_reached_running" true
  check "task_reaches_replied" true
  check "stuck_task_is_diagnosed" false
  check "terminal_task_refuses_second_reply" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

run ack "$TASK_ID" >"$WORK/ack.log" 2>&1 || fail "ack failed: $(tail -1 "$WORK/ack.log")"
record_status "$TASK_ID"
run working "$TASK_ID" 40 >"$WORK/working.log" 2>&1 || fail "working failed: $(tail -1 "$WORK/working.log")"
record_status "$TASK_ID"
run reply "$TASK_ID" "scenario done: everything finished" >"$WORK/reply.log" 2>&1 \
  || fail "reply failed: $(tail -1 "$WORK/reply.log")"
record_status "$TASK_ID"
FINAL_STATUS="$(task_status "$TASK_ID")"
[ "$FINAL_STATUS" = "replied" ] || fail "the task did not reach replied (it is $FINAL_STATUS)"

RESULT=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$TASK_ID?network_id=$NET" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['task']['result'])")
case "$RESULT" in *"scenario done"*) ;; *) fail "the result was not stored on the task row" ;; esac
check "task_reaches_replied" true
check "result_stored_on_task_row" true
check "transitions_observed" true
check "stuck_task_is_diagnosed" false
check "terminal_task_refuses_second_reply" false
check "hijacked_task_is_refused" false
check "vanished_task_is_named" false
check "second_task_is_refused" false

if [ "$SCENARIO" = "terminal-refused" ]; then
  if run reply "$TASK_ID" "second attempt" >"$WORK/second.log" 2>&1; then
    fail "replying to a terminal task should have been refused"
  fi
  grep -q "already replied" "$WORK/second.log" \
    || fail "unexpected error text: $(tail -1 "$WORK/second.log")"
  record_verdict "second reply refused: $(tail -1 "$WORK/second.log" | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<id>/g')"
  check "terminal_task_refuses_second_reply" true
  check "stuck_task_is_diagnosed" false
  check "hijacked_task_is_refused" false
  check "vanished_task_is_named" false
  check "second_task_is_refused" false
fi

write_result true
echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
