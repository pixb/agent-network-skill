#!/usr/bin/env bash
# Manual-node E2E against a throwaway local hub.
# Registers a user, mints a manual-node token, dispatches a task, then drives
# the whole lifecycle with scripts/anet_manual_node.sh and asserts the hub rows.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/anet_manual_node.sh"
PAYLOAD_SH="$SKILL_DIR/scripts/anet_payload.sh"
WORK="$(mktemp -d /tmp/anet-manual-e2e.XXXXXX)"
PORT="${PORT:-19733}"
HUB="http://127.0.0.1:$PORT"
DB="$WORK/hub.db"

# Where the hub source lives: ANET_E2E_HUB_SRC first, else resolved relative to this
# skill directory (a clone of the parent repo has the skill at
# <repo>/.agents/skills/agent-network-skill). Nothing here names a specific machine.
HUB_SRC="${ANET_E2E_HUB_SRC:-}"
if [ -z "$HUB_SRC" ]; then
  for cand in "$SKILL_DIR/../../../server" "$SKILL_DIR/../../server" "$PWD/server" \
              "$HOME/agent-network/server"; do
    [ -f "$cand/bin/commhub.ts" ] && { HUB_SRC="$cand"; break; }
  done
fi
[ -f "${HUB_SRC:-}/bin/commhub.ts" ] || { [ -f "${HUB_SRC:-}/server/bin/commhub.ts" ] && HUB_SRC="$HUB_SRC/server"; }
[ -f "${HUB_SRC:-}/bin/commhub.ts" ] || { echo "no commhub-server source found; set ANET_E2E_HUB_SRC" >&2; exit 2; }

cleanup() {
  [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== booting throwaway hub on $HUB (db $DB)"
COMMHUB_DB="$DB" bun run "$HUB_SRC/bin/commhub.ts" \
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

echo "== a pointer-style dispatch: short body, the spec lives in a payload file (§1.2)"
PAYLOAD="commhub_tasks/e2e/spec.md"
mkdir -p "$PROJ/commhub_tasks/e2e"
cat > "$PROJ/$PAYLOAD" <<'EOF'
# e2e 规格

## seg-01 给导出函数补单元测试
为 exportRows() 补 3 个用例，覆盖空输入、单行、超长行。
验收: 3 个用例全绿。
EOF
(
  cd "$PROJ" && git init -q . && printf '.anet/\n' > .gitignore && git add -A &&
  git -c user.email=e2e@local -c user.name=e2e commit -qm "payload file"
) || { echo "could not create a git project for the payload file"; exit 1; }
BRANCH="$(git -C "$PROJ" rev-parse --abbrev-ref HEAD)"
POINTER4="$("$SKILL_DIR/scripts/anet_payload.sh" compose --project-root "$PROJ" --file "$PAYLOAD" \
  --seg seg-01 --summary "e2e seg-01：给导出函数补单元测试，3 个用例全绿" --branch "$BRANCH" --json 2>/dev/null)"
BODY4="$(printf '%s' "$POINTER4" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"])')"
[ -n "$BODY4" ] || { echo "compose produced no body"; exit 1; }
"$SKILL_DIR/scripts/anet_payload.sh" guard --body "$BODY4" >/dev/null \
  || { echo "the composed body breaks the parameter budget"; exit 1; }
echo "   pointer body ($(printf '%s' "$POINTER4" | python3 -c 'import json,sys;print(json.load(sys.stdin)["chars"])') chars, one commhub call this round):"
printf '%s\n' "$BODY4" | sed 's/^/     /'
TASK4=$(python3 - "$HUB" "$UTOK" "$NET" "$BODY4" <<'PY'
import json, sys, urllib.request
hub, utok, net, body = sys.argv[1:5]
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "e2e-manual-node", "task": body, "network_id": net}).encode())
print(json.load(urllib.request.urlopen(req))["task_id"])
PY
)
run ack "$TASK4" >/dev/null
run working "$TASK4" 10 >/dev/null
[ "$(task_status "$TASK4")" = "running" ] || { echo "the short pointer body did not flip the task to running"; exit 1; }
run reply "$TASK4" "seg-01 done: 3 unit tests green" >/dev/null
[ "$(task_status "$TASK4")" = "replied" ] || { echo "expected replied"; exit 1; }
echo "   short body round-tripped byte-exactly: acked -> running -> replied"

echo "== one file per task: the pointer names a FILE, so its sha12 is the FILE's hash"
FILE_TASK="commhub_tasks/e2e/export-tests.md"
cat > "$PROJ/$FILE_TASK" <<'EOF'
# e2e 导出测试

为 exportRows() 补 3 个用例，覆盖空输入、单行、超长行。
把新增用例挂在现有导出测试模块下。

验收: 3 个用例全绿，失败时报错指向具体行号。
EOF
( cd "$PROJ" && git add -A && git -c user.email=e2e@local -c user.name=e2e commit -qm "task file" )
POINTER5="$("$SKILL_DIR/scripts/anet_payload.sh" compose --project-root "$PROJ" --file "$FILE_TASK" \
  --summary "e2e 导出测试：给导出函数补单元测试，3 个用例全绿" --branch "$BRANCH" --json 2>/dev/null)"
BODY5="$(printf '%s' "$POINTER5" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"])')"
SHA5="$(printf '%s' "$POINTER5" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha12"])')"
[ -n "$BODY5" ] || { echo "compose produced no body for the per-task file"; exit 1; }
case "$BODY5" in
  *"seg:"*) echo "a whole-file pointer carries a seg: field"; exit 1 ;;
esac
case "$BODY5" in *"file: $FILE_TASK"*) ;; *) echo "the pointer does not name the task's own file"; exit 1 ;; esac
# the hash must be the whole file's, computed here by an independent algorithm
EXPECT5="$(python3 -c "import hashlib,sys;t=open(sys.argv[1],encoding='utf-8').read().rstrip(chr(10));print(hashlib.sha256(t.encode('utf-8')).hexdigest()[:12])" "$PROJ/$FILE_TASK")"
[ "$SHA5" = "$EXPECT5" ] || { echo "pointer sha12 $SHA5, the file hashes to $EXPECT5"; exit 1; }
"$SKILL_DIR/scripts/anet_payload.sh" verify --project-root "$PROJ" --file "$FILE_TASK" --sha12 "$SHA5" >/dev/null \
  || { echo "verify refused the correct whole-file sha12"; exit 1; }
set +e
"$SKILL_DIR/scripts/anet_payload.sh" verify --project-root "$PROJ" --file "$FILE_TASK" --sha12 000000000000 >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = 3 ] || { echo "verify accepted a whole-file sha12 that does not match (exit $RC)"; exit 1; }
echo "   whole-file pointer (no seg:), sha12 $SHA5 matches an independent sha256; a wrong sha exits 3"
echo "   a neighbour's task text is not in this file: $(grep -c 'seg-' "$PROJ/$FILE_TASK") segment anchors"

# the per-task pointer must move a real task through the hub, byte-for-byte
TASK5=$(python3 - "$HUB" "$UTOK" "$NET" "$BODY5" <<'PY'
import json, sys, urllib.request
hub, utok, net, body = sys.argv[1:5]
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "e2e-manual-node", "task": body, "network_id": net}).encode())
print(json.load(urllib.request.urlopen(req))["task_id"])
PY
)
run ack "$TASK5" >/dev/null
run working "$TASK5" 10 >/dev/null
[ "$(task_status "$TASK5")" = "running" ] || { echo "the per-task pointer did not flip the task to running"; exit 1; }
run reply "$TASK5" "done: 3 unit tests green, report in the task file's directory" >/dev/null
[ "$(task_status "$TASK5")" = "replied" ] || { echo "expected replied"; exit 1; }
echo "   per-task pointer round-tripped: acked -> running -> replied"

echo "== attachments: a task carries a file through the hub, the manual node pulls it"
SPEC="$WORK/attach-spec.md"
printf '%s\n' '# 附件规格' '' '## seg-01 附件里的规格正文' '这一段的正文由 hub 传输，不走两台机器的磁盘。' > "$SPEC"
SPEC_SHA12=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$SPEC")
# The dispatcher's half is the payload script's own command, not an ad-hoc curl.
UPLOAD_JSON="$(ANET_TOKEN="$UTOK" "$PAYLOAD_SH" upload --project-root "$WORK" --file attach-spec.md \
    --hub "$HUB" --network "$NET" --name spec.md --mime text/markdown --allow-untracked --json)"
FILE_ID=$(printf '%s' "$UPLOAD_JSON" | jqq "['file_id']")
UP_SHA=$(printf '%s' "$UPLOAD_JSON" | jqq "['sha12']")
[ -n "$FILE_ID" ] || { echo "upload failed: $UPLOAD_JSON"; exit 1; }
[ "$UP_SHA" = "$SPEC_SHA12" ] || { echo "upload reported sha12 $UP_SHA, the file hashes to $SPEC_SHA12"; exit 1; }
echo "   uploaded via anet_payload.sh: file_id=$FILE_ID sha12=$SPEC_SHA12"

# 12 MiB is refused before a byte goes on the wire.
BIG="$WORK/big.bin"; dd if=/dev/zero of="$BIG" bs=1M count=13 status=none
set +e
BIG_OUT="$(ANET_TOKEN="$UTOK" "$PAYLOAD_SH" upload --project-root "$WORK" --file big.bin --hub "$HUB" --network "$NET" --allow-untracked 2>&1)"
RC=$?; set -e
echo "$BIG_OUT" | sed 's/^/   /'
[ "$RC" = 3 ] || { echo "a 13 MiB file was not refused (exit $RC)"; exit 1; }
case "$BIG_OUT" in *"12 MiB"*) ;; *) echo "the size refusal did not name the cap"; exit 1 ;; esac
rm -f "$BIG"

# The access string is an env var by design: argv is readable in ps and shell history.
set +e
NOAUTH_OUT="$(env -u ANET_TOKEN "$PAYLOAD_SH" upload --project-root "$WORK" --file attach-spec.md --hub "$HUB" --network "$NET" --allow-untracked 2>&1)"
RC=$?; set -e
[ "$RC" != 0 ] || { echo "upload ran with no ANET_TOKEN in the environment"; exit 1; }
case "$NOAUTH_OUT" in *"ANET_TOKEN"*) ;; *) echo "the missing-token refusal did not name ANET_TOKEN"; exit 1 ;; esac
echo "   upload refuses to run without ANET_TOKEN in the environment (never an argv value)"

# A malformed attachment must be refused at dispatch, not silently dropped (#507).
BAD=$(python3 - "$HUB" "$UTOK" "$NET" <<'PY'
import json, sys, urllib.request, urllib.error
hub, utok, net = sys.argv[1:4]
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "e2e-manual-node", "task": "bad attachment probe",
                     "network_id": net, "attachments": [{"type": "document", "file_id": "abc12345"}]}).encode())
try:
    print(json.load(urllib.request.urlopen(req)).get("error", ""))
except urllib.error.HTTPError as e:
    print(json.loads(e.read()).get("error", ""))
PY
)
[ "$BAD" = "bad_attachments" ] || { echo "a malformed attachment was not refused (got: ${BAD:-none})"; exit 1; }
echo "   hub refused a malformed attachment: $BAD"

ATT_TASK=$(python3 - "$HUB" "$UTOK" "$NET" "$FILE_ID" "$SPEC_SHA12" <<'PY'
import json, sys, urllib.request
hub, utok, net, file_id, sha12 = sys.argv[1:6]
body = ("seg-01 附件规格：按附件正文执行\n"
        f"attachment: {file_id}  sha12: {sha12}\n"
        "work it in your own working directory; accept: the attachment's acceptance list\n"
        "report_completion once, result <= 400 chars")
req = urllib.request.Request(
    hub + "/api/task", method="POST",
    headers={"Authorization": "Bearer " + utok, "Content-Type": "application/json"},
    data=json.dumps({"alias": "e2e-manual-node", "task": body, "network_id": net,
                     "attachments": [{"type": "file", "file_id": file_id, "name": "spec.md",
                                      "mime": "text/markdown"}]}).encode())
print(json.load(urllib.request.urlopen(req))["task_id"])
PY
)
echo "   task with attachment: $ATT_TASK"
run ack "$ATT_TASK" >/dev/null
FILES_OUT="$(run files "$ATT_TASK" 2>&1)"
echo "$FILES_OUT" | sed 's/^/   /'
case "$FILES_OUT" in *"carries 1 attachment"*"$FILE_ID"*) ;; *) echo "files did not name the attachment"; exit 1 ;; esac

DL="$WORK/downloaded.md"
FETCH_OUT="$(run fetch "$FILE_ID" --out "$DL" --sha12 "$SPEC_SHA12" 2>&1)"
echo "$FETCH_OUT" | sed 's/^/   /'
case "$FETCH_OUT" in *"sha12 $SPEC_SHA12"*) ;; *) echo "fetch did not report the sha12"; exit 1 ;; esac
[ -f "$DL" ] || { echo "fetch wrote no file"; exit 1; }
cmp -s "$SPEC" "$DL" || { echo "the fetched bytes differ from what was uploaded"; exit 1; }
echo "   fetched bytes match the uploaded file (sha12 $SPEC_SHA12)"

# A wrong revision is refused with exit 3 — the same signal anet_payload.sh verify gives.
set +e
BAD_FETCH="$(run fetch "$FILE_ID" --out "$WORK/never-written.md" --sha12 000000000000 2>&1)"
RC=$?
set -e
echo "$BAD_FETCH" | sed 's/^/   /' | tail -2
[ "$RC" = 3 ] || { echo "fetch accepted a sha12 that does not match (exit $RC)"; exit 1; }
case "$BAD_FETCH" in *"sha12 mismatch"*) ;; *) echo "fetch did not name the sha12 conflict"; exit 1 ;; esac
[ ! -f "$WORK/never-written.md" ] || { echo "the refused fetch left a file behind"; exit 1; }

# An unknown id answers 404, never 403 (no enumeration oracle).
set +e
GONE="$(run fetch "deadbeefcafe0000" --out "$WORK/none.md" 2>&1)"
RC=$?
set -e
echo "$GONE" | sed 's/^/   /' | tail -1
case "$GONE" in *"no such file for this node"*) ;; *) echo "an unknown file_id was not reported as 404"; exit 1 ;; esac

# …and so does a REAL file that lives in another network: download rights are
# network-scoped, and the hub keeps that a 404 too.
REG2=$(curl -s -X POST "$HUB/api/auth/register" -H 'Content-Type: application/json' \
  -d '{"username":"e2eother","password":"e2e-password-12345"}')
UTOK2=$(echo "$REG2" | jqq "['token']"); NET2=$(echo "$REG2" | jqq "['network_id']")
[ "$NET2" != "$NET" ] || { echo "the second user did not get its own network"; exit 1; }
PROJ2="$WORK/project2"; mkdir -p "$PROJ2"
ANET_MANUAL_USER_TOKEN="$UTOK2" "$SCRIPT" init --node e2e-manual-node --project-root "$PROJ2" --hub "$HUB" >/dev/null
run2() { "$SCRIPT" "$@" --project-root "$PROJ2" --hub "$HUB"; }
set +e
OTHER="$(run2 fetch "$FILE_ID" --out "$WORK/other-network.md" 2>&1)"
RC=$?; set -e
echo "$OTHER" | sed 's/^/   /' | tail -1
[ "$RC" != 0 ] || { echo "a node read a file from another network"; exit 1; }
case "$OTHER" in *"no such file for this node"*) ;; *) echo "the cross-network read was not reported as 404"; exit 1 ;; esac
[ ! -f "$WORK/other-network.md" ] || { echo "the refused cross-network fetch left a file behind"; exit 1; }
echo "   node of network $NET2 cannot read the file uploaded in $NET (hub answers 404, not 403)"

echo
 echo "ALL E2E ASSERTIONS PASSED"
