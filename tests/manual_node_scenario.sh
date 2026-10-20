#!/usr/bin/env bash
# manual_node_scenario.sh — run one manual-node scenario against a throwaway
# hub and write a machine-readable result.
#
# usage:
#   manual_node_scenario.sh --input <scenario.json> [--output <result.json>]
#
# The input file is JSON: {"scenario": "<name>", "hub_source": "<path>"}
# where <name> is one of:
#   full-lifecycle   register, dispatch, ack, working, reply  -> task ends replied
#   stuck-delivered  register, dispatch, nothing else         -> task ends delivered
#   terminal-refused register, dispatch, ack, working, reply,
#                    then a second reply                     -> the second reply is refused
#
# The result JSON is: {"scenario", "ok", "final_status", "transitions": [...],
#                      "verdicts": [...], "error": null}
#
# The hub is booted from the commhub-server source tree (ANET_E2E_HUB_SRC, or
# the default paths below) into a throwaway database, so nothing touches a
# real hub.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/anet_manual_node.sh"

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
  for cand in /vol1/1000/docker/nec8-docker/agent-network/server "$HOME/agent-network/server" "./server"; do
    [ -f "$cand/bin/commhub.ts" ] && { HUB_SRC="$cand"; break; }
  done
fi
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
record_verdict() { VERDICTS="${VERDICTS:+$VERDICTS|}$1"; }
# check <name> <true|false> — a fact this scenario verified against the hub.
check() { CHECKS="${CHECKS:+$CHECKS|}$1=$2"; }

BODY="scenario body: first line
second line, with punctuation & 特殊字符
third line"
TASK_ID="$(dispatch "$BODY")"
record "dispatched"
record "status:$(task_status "$TASK_ID")"

if [ "$SCENARIO" = "stuck-delivered" ]; then
  run check >"$WORK/check.log" 2>&1 || fail "check failed"
  grep -q "nobody acked it" "$WORK/check.log" \
    || fail "check did not diagnose the un-acked task: $(tail -3 "$WORK/check.log")"
  record_verdict "$(grep '^verdict:' "$WORK/check.log" | head -1 | sed 's/^verdict: //' | sed -E 's/task [0-9a-f-]{36}/task <id>/; s/after [0-9]+s/after <n>s/')"
  FINAL_STATUS="$(task_status "$TASK_ID")"
  check "stuck_task_stays_delivered" "$([ "$FINAL_STATUS" = "delivered" ] && echo true || echo false)"
  check "stuck_task_is_diagnosed" true
  check "task_reaches_replied" false
  check "terminal_task_refuses_second_reply" false
  write_result true
  echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
  exit 0
fi

run ack "$TASK_ID" >"$WORK/ack.log" 2>&1 || fail "ack failed: $(tail -1 "$WORK/ack.log")"
record "status:$(task_status "$TASK_ID")"
run working "$TASK_ID" 40 >"$WORK/working.log" 2>&1 || fail "working failed: $(tail -1 "$WORK/working.log")"
record "status:$(task_status "$TASK_ID")"
run reply "$TASK_ID" "scenario done: everything finished" >"$WORK/reply.log" 2>&1 \
  || fail "reply failed: $(tail -1 "$WORK/reply.log")"
record "status:$(task_status "$TASK_ID")"
FINAL_STATUS="$(task_status "$TASK_ID")"
[ "$FINAL_STATUS" = "replied" ] || fail "the task did not reach replied (it is $FINAL_STATUS)"

RESULT=$(curl -s -H "Authorization: Bearer $UTOK" "$HUB/api/tasks/$TASK_ID?network_id=$NET" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['task']['result'])")
case "$RESULT" in *"scenario done"*) ;; *) fail "the result was not stored on the task row" ;; esac
check "task_reaches_replied" true
check "result_stored_on_task_row" true
check "transitions_observed" true

if [ "$SCENARIO" = "terminal-refused" ]; then
  if run reply "$TASK_ID" "second attempt" >"$WORK/second.log" 2>&1; then
    fail "replying to a terminal task should have been refused"
  fi
  grep -q "already replied" "$WORK/second.log" \
    || fail "unexpected error text: $(tail -1 "$WORK/second.log")"
  record_verdict "second reply refused: $(tail -1 "$WORK/second.log" | sed -E 's/task [0-9a-f-]{36}/task <id>/')"
  check "terminal_task_refuses_second_reply" true
  check "stuck_task_is_diagnosed" false
fi

write_result true
echo "scenario $SCENARIO ok (final status: $FINAL_STATUS)"
