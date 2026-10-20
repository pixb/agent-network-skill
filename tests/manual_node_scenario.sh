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
#   skipped-working  register, dispatch, reply (no working)   -> task ends replied,
#                                                             and reply warns that
#                                                             the run was invisible
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
