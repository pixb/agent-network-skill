#!/usr/bin/env bash
# Manual-node E2E against a throwaway local hub.
# Registers a user, mints a manual-node token, dispatches a task, then drives
# the whole lifecycle with scripts/anet_manual_node.sh and asserts the hub rows.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/anet_manual_node.sh"
WORK="$(mktemp -d /tmp/anet-manual-e2e.XXXXXX)"
PORT="${PORT:-19733}"
HUB="http://127.0.0.1:$PORT"
DB="$WORK/hub.db"

cleanup() {
  [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== booting throwaway hub on $HUB (db $DB)"
COMMHUB_DB="$DB" bun run /vol1/1000/docker/nec8-docker/agent-network/server/bin/commhub.ts \
  --port "$PORT" --host 127.0.0.1 --db "$DB" --dev-open >"$WORK/hub.log" 2>&1 &
HUB_PID=$!

for i in $(seq 1 60); do
  if curl -sf "$HUB/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -sf "$HUB/health" >/dev/null || { echo "hub did not come up"; tail -30 "$WORK/hub.log"; exit 1; }
echo "   hub is up"

jqq() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

echo "== registering a user"
REG=$(curl -s -X POST "$HUB/api/auth/register" -H 'Content-Type: application/json' \
  -d '{"username":"e2euser","password":"e2e-password-12345"}')
UTOK=$(echo "$REG" | jqq "['token']")
[ -n "$UTOK" ] || { echo "register failed: $REG"; exit 1; }
NET=$(echo "$REG" | jqq "['network_id']")
echo "   user registered, network $NET"

echo "== minting a manual-node token through the script's own init path"
PROJ="$WORK/project"
mkdir -p "$PROJ"
export ANET_MANUAL_USER_TOKEN="$UTOK"
"$SCRIPT" init --node e2e-manual-node --project-root "$PROJ" --hub "$HUB" | sed 's/^/   /'
NODEDIR="$PROJ/.anet/nodes/e2e-manual-node"
[ -f "$NODEDIR/config.json" ] || { echo "init did not write a config"; exit 1; }
NTOK=$(python3 -c "import json;print(json.load(open('$NODEDIR/config.json'))['token'])")
NID=$(python3 -c "import json;print(json.load(open('$NODEDIR/config.json'))['node_id'])")
NET=$(python3 -c "import json;print(json.load(open('$NODEDIR/config.json'))['network_id'])")
[ -n "$NTOK" ] || { echo "no node token in config"; exit 1; }
echo "   node token minted (node_id $NID, network $NET)"

run() { "$SCRIPT" "$@" --project-root "$PROJ" --hub "$HUB"; }

echo "== registering the node (report_status agent=manual)"
run once | tail -2
echo "== dispatching a task to the manual node"
TASK_BODY="line one summary of the work
second line of the body
third line with 特殊字符 to prove byte-exact matching"
DISPATCH=$(python3 - "$HUB" "$UTOK" "$NET" "$TASK_BODY" <<'PY'
import json, sys, urllib.request
hub, utok, net, body = sys.argv[1:5]
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "e2e-manual-node", "task": body, "network_id": net}).encode())
print(json.load(urllib.request.urlopen(req))["task_id"])
PY
)
echo "   task dispatched: $TASK_BODY"
TASK_ID="$DISPATCH"
echo "   task id: $TASK_ID"

task_status() {
  curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$1?network_id=$NET" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['task']['status'])"
}

echo "== check BEFORE the work starts (this is the stuck-task diagnosis)"
run check | sed 's/^/   /'
[ "$(task_status "$TASK_ID")" = "delivered" ] || { echo "expected delivered"; exit 1; }

echo "== inbox"
run inbox | sed 's/^/   /'

echo "== ack"
run ack "$TASK_ID" | sed 's/^/   /'
[ "$(task_status "$TASK_ID")" = "acked" ] || { echo "expected acked"; exit 1; }

echo "== working (body fetched from the hub, never retyped)"
run working "$TASK_ID" 42 | sed 's/^/   /'
[ "$(task_status "$TASK_ID")" = "running" ] || { echo "expected running"; exit 1; }

echo "== state working 80 (heartbeat keeps re-reporting)"
run state working 80 | sed 's/^/   /'

echo "== check WHILE running"
run check | sed 's/^/   /'

echo "== reply (terminal)"
run reply "$TASK_ID" "done: 301 images generated, report committed as abc1234" | sed 's/^/   /'
[ "$(task_status "$TASK_ID")" = "replied" ] || { echo "expected replied"; exit 1; }

RESULT=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$TASK_ID?network_id=$NET" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['task']['result'])")
echo "   hub result: $RESULT"
case "$RESULT" in *"abc1234"*) ;; *) echo "result not stored"; exit 1 ;; esac

echo "== check AFTER completion"
run check | sed 's/^/   /'

echo "== heartbeat: start, verify it re-reports, stop"
run start | sed 's/^/   /'
sleep 2
run status | sed 's/^/   /'
grep -q "report idle" "$NODEDIR/manual-heartbeat.log" \
  || { echo "heartbeat did not report"; exit 1; }
run stop | sed 's/^/   /'
run status | sed 's/^/   /'

echo "== negative: replying to an already-terminal task must fail"
if run reply "$TASK_ID" "again" >"$WORK/second-reply.log" 2>&1; then
  echo "replying to a terminal task should have failed"; cat "$WORK/second-reply.log"; exit 1
fi
grep -q "already replied" "$WORK/second-reply.log" \
  || { echo "unexpected error text:"; cat "$WORK/second-reply.log"; exit 1; }
echo "   correctly refused: $(tail -1 "$WORK/second-reply.log")"

echo "== negative: working on a terminal task must fail"
if run working "$TASK_ID" >"$WORK/second-working.log" 2>&1; then
  echo "working a terminal task should have failed"; cat "$WORK/second-working.log"; exit 1
fi
echo "   correctly refused: $(tail -1 "$WORK/second-working.log")"

echo "== a second task closed with --via send_reply"
BODY2="a second task body that ends through send_reply"
TASK2=$(python3 - "$HUB" "$UTOK" "$NET" "$BODY2" <<'PY'
import json, sys, urllib.request
hub, utok, net, body = sys.argv[1:5]
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "e2e-manual-node", "task": body, "network_id": net}).encode())
print(json.load(urllib.request.urlopen(req))["task_id"])
PY
)
run ack "$TASK2" | sed 's/^/   /'
run working "$TASK2" | sed 's/^/   /'
run reply "$TASK2" "answered through send_reply" --via send_reply | sed 's/^/   /'
[ "$(task_status "$TASK2")" = "replied" ] || { echo "expected replied"; exit 1; }

echo "== a task dispatched by another NODE, not a human"
# This is the common shape: a planner node dispatches, the manual node answers.
PLANNER_NTOK=$(curl -s -X POST "$HUB/api/auth/node-token" -H "Authorization: Bearer $UTOK" \
  -H 'Content-Type: application/json' \
  -d "{\"network_id\":\"$NET\",\"node_name\":\"e2e-planner-node\",\"node_id\":\"n_planner0001\"}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
[ -n "$PLANNER_NTOK" ] || { echo "could not mint a planner node token"; exit 1; }
PLANNER_CFG="$WORK/planner.json"
cat >"$PLANNER_CFG" <<EOF
{"alias":"e2e-planner-node","node_name":"e2e-planner-node","node_id":"n_planner0001",
 "network_id":"$NET","token":"$PLANNER_NTOK","hub":"$HUB","runtime":"manual"}
EOF
BODY3="a task from a planner node to a manual node"
TASK3=$(python3 - "$HUB" "$PLANNER_NTOK" "$NET" "$BODY3" <<'PY'
import json, sys, urllib.request
hub, ntok, net, body = sys.argv[1:5]
req = urllib.request.Request(
    hub + "/mcp", method="POST",
    headers={"Authorization": "Bearer " + ntok, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"},
    data=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
        "params":{"name":"send_task","arguments":{"alias":"e2e-manual-node","task":body,
        "network_id":net}}}).encode())
raw = urllib.request.urlopen(req).read().decode()
frames = [l[5:].strip() for l in raw.split("\n") if l.startswith("data:")]
msg = json.loads("".join(frames) if frames else raw)
text = json.loads(msg["result"]["content"][0]["text"])
# send_task returns the task id as message_id
print(text.get("task_id") or text.get("message_id") or json.dumps(text))
PY
)
echo "   planner node dispatched task $TASK3"
run ack "$TASK3" | sed 's/^/   /'
run working "$TASK3" | sed 's/^/   /'
run reply "$TASK3" "manual node finished the planner's task" --via send_reply | sed 's/^/   /'
[ "$(task_status "$TASK3")" = "replied" ] || { echo "expected replied"; exit 1; }
# the planner must actually receive the answer
PLAN_INBOX=$(curl -s -H "Authorization: Bearer $PLANNER_NTOK" "$HUB/api/messages?alias=e2e-planner-node&since=2020-01-01%2000:00:00" \
  | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('messages',[])))")
echo "   planner inbox rows: $PLAN_INBOX"
[ "${PLAN_INBOX:-0}" -ge 1 ] || { echo "the planner never received the reply"; exit 1; }

echo
echo "ALL E2E ASSERTIONS PASSED"
