#!/usr/bin/env bash
# anet_manual_node.sh — drive a MANUAL CommHub node (a node with no agent
# runtime behind it) from the command line.
#
# A manual node is a first-class hub node that only ever speaks the protocol:
# it registers itself with report_status(agent="manual"), keeps a heartbeat so
# it stays visible, and consumes work by hand. There is no agent-node process
# and no MCP tool surface behind it, so every protocol step is explicit here.
#
# This file is deliberately self-contained: copy it to the machine that runs
# the manual node and it works. The only requirement is node (or bun) on PATH.
#
# usage:
#   anet_manual_node.sh init    [options]              register a manual node
#   anet_manual_node.sh start   [options]              start the heartbeat
#   anet_manual_node.sh stop    [options]              stop the heartbeat
#   anet_manual_node.sh restart [options]              stop + start
#   anet_manual_node.sh status  [options]              heartbeat state + last log
#   anet_manual_node.sh logs    [options]              tail the heartbeat log
#   anet_manual_node.sh once    [options]              one heartbeat, then exit
#   anet_manual_node.sh inbox   [options]              list pending tasks
#   anet_manual_node.sh show    <task_id> [options]    one task, full record
#   anet_manual_node.sh ack     <task_id> [options]    delivered -> acked
#   anet_manual_node.sh working <task_id> [progress] [options]
#                                                    acked/delivered -> running
#   anet_manual_node.sh state   <status> [progress] [options]
#                                                    set the session state
#   anet_manual_node.sh reply   <task_id> "<text>" [replied|failed|cancelled]
#                              [--via completion|send_reply] [options]
#                                                    terminal reply
#   anet_manual_node.sh say     <alias> "<text>" [options]
#                                                    chat only, task stays open
#   anet_manual_node.sh check   [options]              hub-side truth report
#
# options (flags override environment, environment overrides defaults):
#   --node <alias>          manual node alias
#   --config <path>         node config.json path
#   --project-root <dir>    project that owns .anet/nodes (default: $PWD)
#   --hub <url>             hub base url
#   --network <id>          network id
#   --interval <seconds>    heartbeat interval (default 30)
#   --state-dir <dir>       where pid/log/status live (default: config dir)
#   --json                  machine-readable output where the command has any
#   -h, --help              this text
#
# environment overrides:
#   ANET_MANUAL_NODE, ANET_MANUAL_CONFIG, ANET_MANUAL_HUB, ANET_MANUAL_NETWORK,
#   ANET_MANUAL_INTERVAL, ANET_MANUAL_STATE_DIR, ANET_MANUAL_TOKEN,
#   ANET_MANUAL_USER_TOKEN
#
# The node token is read from the node config and is never printed.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() { sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'; }

die() { echo "$SCRIPT_NAME: $*" >&2; exit "${2:-2}"; }

# ── argument parsing ───────────────────────────────────────────────────────
NODE_NAME="${ANET_MANUAL_NODE:-}"
CONFIG="${ANET_MANUAL_CONFIG:-}"
PROJECT_ROOT="${ANET_MANUAL_PROJECT_ROOT:-$PWD}"
HUB_OVERRIDE="${ANET_MANUAL_HUB:-}"
NETWORK_OVERRIDE="${ANET_MANUAL_NETWORK:-}"
INTERVAL="${ANET_MANUAL_INTERVAL:-30}"
STATE_DIR_OVERRIDE="${ANET_MANUAL_STATE_DIR:-}"
TOKEN_OVERRIDE="${ANET_MANUAL_TOKEN:-}"
USER_TOKEN_OVERRIDE="${ANET_MANUAL_USER_TOKEN:-}"
JSON_OUT=0
REPLY_VIA=""

COMMAND=""
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE_NAME="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --hub) HUB_OVERRIDE="${2:-}"; shift 2 ;;
    --network) NETWORK_OVERRIDE="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --token) TOKEN_OVERRIDE="${2:-}"; shift 2 ;;
    --user-token) USER_TOKEN_OVERRIDE="${2:-}"; shift 2 ;;
    --via) REPLY_VIA="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) die "unknown option: $1" 2 ;;
    *)
      if [ -z "$COMMAND" ]; then COMMAND="$1"; shift
      else ARGS+=("$1"); shift; fi
      ;;
  esac
done

[ -n "$COMMAND" ] || { usage; exit 2; }

# ── runtime discovery ──────────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then JSBIN=node
elif command -v bun >/dev/null 2>&1; then JSBIN=bun
else die "need node or bun on PATH" 2; fi

# ── config discovery ───────────────────────────────────────────────────────
# Order: --config, $ANET_MANUAL_CONFIG, <project-root>/.anet/nodes/<node>/config.json,
# ~/.anet/nodes/<node>/config.json, then any .anet/nodes/*/config.json whose
# alias/node_name matches --node.
resolve_config() {
  if [ -n "$CONFIG" ]; then
    [ -f "$CONFIG" ] || die "no such config: $CONFIG" 2
    echo "$CONFIG"; return
  fi
  if [ -n "$NODE_NAME" ]; then
    for cand in "$PROJECT_ROOT/.anet/nodes/$NODE_NAME/config.json" \
                "$HOME/.anet/nodes/$NODE_NAME/config.json"; do
      [ -f "$cand" ] && { echo "$cand"; return; }
    done
    for cand in "$PROJECT_ROOT"/.anet/nodes/*/config.json; do
      [ -f "$cand" ] || continue
      if grep -q "\"alias\"[[:space:]]*:[[:space:]]*\"$NODE_NAME\"" "$cand" 2>/dev/null \
         || grep -q "\"node_name\"[[:space:]]*:[[:space:]]*\"$NODE_NAME\"" "$cand" 2>/dev/null; then
        echo "$cand"; return
      fi
    done
  else
    for cand in "$PROJECT_ROOT"/.anet/nodes/*/config.json; do
      [ -f "$cand" ] || continue
      echo "$cand"; return
    done
  fi
  return 1
}

if [ "$COMMAND" = "init" ]; then
  # init may create the config, so it does not require one to exist yet.
  if [ -z "$CONFIG" ]; then
    [ -n "$NODE_NAME" ] || die "init needs --node <alias>" 2
    CONFIG="$PROJECT_ROOT/.anet/nodes/$NODE_NAME/config.json"
  fi
else
  CONFIG="$(resolve_config)" || die "no node config found for '$NODE_NAME' (use --config or --project-root)" 2
fi

STATE_DIR="${STATE_DIR_OVERRIDE:-$(dirname "$CONFIG")}"
PIDFILE="$STATE_DIR/manual-heartbeat.pid"
LOGFILE="$STATE_DIR/manual-heartbeat.log"
STATUSFILE="$STATE_DIR/manual-status.json"
CLIENT="$STATE_DIR/anet-manual-node-client.mjs"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

# ── client program ─────────────────────────────────────────────────────────
# The hub speaks MCP over HTTP (Streamable HTTP, SSE-framed answers), and the
# protocol steps here need exact byte-level control over task bodies. That is
# why this client is code, not curl one-liners.
write_client() {
  cat >"$CLIENT" <<'EOFJS'
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const CONFIG = process.env.ANET_MANUAL_CONFIG;
const STATUSFILE = process.env.ANET_MANUAL_STATUSFILE;
const MODE = process.argv[2] || "watch";
const INTERVAL = Number(process.env.ANET_MANUAL_INTERVAL || 30) * 1000;
const HUB_OVERRIDE = process.env.ANET_MANUAL_HUB || "";
const NETWORK_OVERRIDE = process.env.ANET_MANUAL_NETWORK || "";
const TOKEN_OVERRIDE = process.env.ANET_MANUAL_TOKEN || "";
const USER_TOKEN_OVERRIDE = process.env.ANET_MANUAL_USER_TOKEN || "";
const ALIAS_OVERRIDE = process.env.ANET_MANUAL_NODE || "";
const JSON_OUT = process.env.ANET_MANUAL_JSON === "1";
const ARGS = process.argv.slice(3);
const SCRIPT_NAME = "anet_manual_node.sh";

const STATES = ["working", "idle", "blocked", "error", "waiting_input", "offline"];
const TERMINAL = ["replied", "failed", "cancelled", "expired"];
const TOKEN_HINT =
  "the node token was refused (revoked, expired, or from another hub) -> " +
  "re-mint it with: anet_manual_node.sh init --node <alias>";

function die(msg, code = 2) {
  console.error(msg);
  process.exit(code);
}

function readJson(path, fallback = null) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fallback;
  }
}

const cfg = readJson(CONFIG, {}) || {};
const homeCfg = readJson(`${process.env.HOME}/.anet/config.json`, {}) || {};

const alias = ALIAS_OVERRIDE || cfg.alias || cfg.node_name || cfg.name || "";
const node_id = cfg.node_id || "";
const token = TOKEN_OVERRIDE || cfg.token || "";
const hub = (HUB_OVERRIDE || cfg.hub || homeCfg.hub || "http://127.0.0.1:9200").replace(/\/+$/, "");
// The user's global config may point at a different hub than this node's, and
// its network id means nothing there. Only fall back to it when the hubs
// actually match.
const globalNetwork = homeCfg.hub && homeCfg.hub.replace(/\/+$/, "") === hub ? homeCfg.network_id : "";
const network_id = NETWORK_OVERRIDE || cfg.network_id || globalNetwork || "";

function nowIso() { return new Date().toISOString(); }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function out(obj) {
  if (JSON_OUT) console.log(JSON.stringify(obj, null, 2));
}

// ── hub transport ──────────────────────────────────────────────────────────
async function rpc(path, method, body, bearer) {
  let res;
  try {
    res = await fetch(hub + path, {
      method,
      headers: {
        Authorization: "Bearer " + bearer,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        "MCP-Protocol-Version": "2025-03-26",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (e) {
    const why = e && e.cause && e.cause.message ? ` (${e.cause.message})` : "";
    die(`hub unreachable (${hub}): ${e.message}${why}`, 3);
  }
  const text = await res.text();
  let msg = null;
  const lines = text.split("\n").filter((l) => l.startsWith("data:"));
  try {
    msg = lines.length
      ? JSON.parse(lines.map((l) => l.slice(5).trim()).join(""))
      : JSON.parse(text);
  } catch {
    die(`hub response is not JSON (HTTP ${res.status}): ${text.slice(0, 200)}`, 3);
  }
  if (msg && msg.error) {
    const m = typeof msg.error === "string" ? msg.error : msg.error.message || JSON.stringify(msg.error);
    die(`${method} ${path} failed: ${m}`, res.status === 401 ? 4 : 3);
  }
  if (!res.ok) {
    die(
      `${method} ${path} failed: HTTP ${res.status}` +
      (res.status === 401 ? " — " + TOKEN_HINT : ""),
      res.status === 401 ? 4 : 3,
    );
  }
  return msg;
}

async function mcp(name, args, bearer) {
  const msg = await rpc("/mcp", "POST", {
    jsonrpc: "2.0",
    id: Date.now(),
    method: "tools/call",
    params: { name, arguments: args },
  }, bearer || token);
  const t = msg && msg.result && msg.result.content && msg.result.content[0] && msg.result.content[0].text;
  return t ? JSON.parse(t) : (msg && msg.result) || {};
}

// ── local state (what the heartbeat keeps re-reporting) ────────────────────
function readState() {
  const s = readJson(STATUSFILE, null);
  if (!s) return { status: "idle", progress: null, task: null };
  return {
    status: STATES.includes(s.status) ? s.status : "idle",
    progress: s.progress ?? null,
    task: s.task ?? null,
  };
}
function writeState(s) {
  try {
    mkdirSync(dirname(STATUSFILE), { recursive: true, mode: 0o700 });
    writeFileSync(STATUSFILE, JSON.stringify(s));
  } catch {}
}

// ── protocol steps ─────────────────────────────────────────────────────────
async function reportOnce(state) {
  const args = {
    resume_id: node_id,
    alias,
    status: state.status,
    agent: "manual",
    node_id,
    network_id,
  };
  if (state.task) args.task = state.task;
  else if (state.status === "idle") args.task = ""; // clears the stale task text
  if (state.progress != null) args.progress = state.progress;
  const r = await mcp("report_status", args);
  console.log(
    `${nowIso()} report ${state.status}${state.progress != null ? " " + state.progress + "%" : ""}` +
    ` ok=${r.ok} inbox=${r.inbox_count == null ? "?" : r.inbox_count}`,
  );
  if ((r.inbox_count || 0) > 0) {
    console.log(`${nowIso()} ${r.inbox_count} pending task(s) — run: ${SCRIPT_NAME} inbox`);
  }
  return r;
}
const heartbeatOnce = () => reportOnce(readState());

async function registerNode() {
  if (!alias) die("no alias: pass --node <alias> or write \"alias\" into the config", 2);
  const userToken = USER_TOKEN_OVERRIDE || homeCfg.token || "";
  if (!userToken) {
    die(
      "init needs a human token: log in first (anet login) so ~/.anet/config.json holds one",
      2,
    );
  }
  // The network to join: the explicit one, the node config's, or the user's
  // first network on THIS hub. Never a network id from a different hub.
  let targetNetwork = network_id;
  if (!targetNetwork) {
    const me = await rpc("/api/auth/me", "GET", undefined, userToken);
    const nets = (me && me.networks) || [];
    if (!nets.length) die("no network to join: pass --network <id>", 2);
    targetNetwork = nets[0].network_id;
  }
  let mintedId = node_id;
  if (!mintedId) {
    // An alias is bound to exactly one node id on the hub: minting a second,
    // different id for the same alias is refused with node_owner_mismatch. So
    // reuse the id the hub already knows, if there is one.
    const existing = await rpc("/api/nodes?alias=" + encodeURIComponent(alias), "GET", undefined, userToken);
    const known = (existing && existing.nodes && existing.nodes[0] && existing.nodes[0].node_id) || "";
    mintedId = known || "n_" + Math.random().toString(16).slice(2, 10);
  }
  const body = await rpc(
    "/api/auth/node-token",
    "POST",
    { network_id: targetNetwork, node_name: alias, node_id: mintedId },
    userToken,
  );
  if (!body || !body.ok || !body.token) {
    const err = (body && body.error) || "unknown";
    const hints = {
      node_owner_mismatch:
        "that alias already belongs to a different node id or another owner — " +
        "reuse the existing config, or pick another alias",
      no_write_access_to_this_network: "your account has no write access to that network",
      invalid_node_id: "the node id in the config is not accepted by the hub",
    };
    die(`could not mint a node token: ${err}${hints[err] ? " — " + hints[err] : ""}`, 4);
  }
  const finalId = body.node_id || mintedId;
  const dir = dirname(CONFIG);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const saved = {
    alias,
    node_name: alias,
    node_id: finalId,
    network_id: targetNetwork,
    token: body.token,
    hub,
    runtime: "manual",
  };
  writeFileSync(CONFIG, JSON.stringify(saved, null, 2) + "\n", { mode: 0o600 });
  console.log(`${nowIso()} registered manual node "${alias}" (node_id ${finalId}) -> ${CONFIG}`);
  // Register the session row so the node is visible and dispatchable.
  const r = await mcp("report_status", {
    resume_id: finalId,
    alias,
    status: "idle",
    agent: "manual",
    node_id: finalId,
    network_id: targetNetwork,
    task: "",
  }, body.token);
  console.log(`${nowIso()} report idle ok=${r.ok} inbox=${r.inbox_count == null ? "?" : r.inbox_count}`);
  console.log(
    `next: ${SCRIPT_NAME} start --node ${alias}   (keeps the node visible; ` +
    `then: ${SCRIPT_NAME} inbox --node ${alias})`,
  );
}

async function listInbox() {
  const r = await mcp("get_inbox", { alias, limit: 50, network_id: network_id });
  if (!r.ok) die(`get_inbox failed: ${JSON.stringify(r)}`, 3);
  const messages = r.messages || [];
  if (!messages.length) {
    console.log("(no pending tasks)");
    out({ ok: true, pending: 0, messages: [] });
    return;
  }
  for (const m of messages) {
    const id = m.task_id || m.id;
    console.log("-".repeat(60));
    console.log("id      :", id);
    console.log("from    :", m.from_session);
    console.log("type    :", m.type, "| priority:", m.priority, "| at:", m.created_at, m.late ? "(late)" : "");
    console.log("content :", m.content);
    if (m.context) console.log("context :", m.context);
    if (m.meta && Object.keys(m.meta).length) console.log("meta    :", JSON.stringify(m.meta));
  }
  out({ ok: true, pending: messages.length, messages: messages.map((m) => ({ id: m.task_id || m.id, from: m.from_session })) });
}

async function showTask(id) {
  const r = await mcp("get_task", { task_id: id });
  console.log(JSON.stringify(r, null, 2));
  if (!r.ok) die(`task ${id}: ${r.error || "not found"}`, 5);
}

async function ackTask(id) {
  const before = await mcp("get_task", { task_id: id });
  if (!before.ok || !before.task) die(`task ${id} not found`, 5);
  if (TERMINAL.includes(before.task.status)) {
    die(`task ${id} is already ${before.task.status} — it cannot be acked`, 5);
  }
  const r = await mcp("ack_inbox", { alias, message_id: id, network_id });
  if (!r.ok) {
    die(
      `ack failed: ${r.error || "unknown"}` +
      (String(r.error || "").includes("already acknowledged")
        ? " — the inbox row for this task is gone; check the hub task state with: show " + id
        : ""),
      5,
    );
  }
  const after = await mcp("get_task", { task_id: id });
  console.log(`acked ${id} (hub task status: ${after.task ? after.task.status : "?"})`);
  out({ ok: true, task_id: id, status: after.task ? after.task.status : null });
}

async function workingTask(id, progress) {
  const t = await mcp("get_task", { task_id: id });
  if (!t.ok || !t.task) die(`task ${id} not found`, 5);
  if (TERMINAL.includes(t.task.status)) {
    die(`task ${id} is already ${t.task.status} — a terminal task cannot go back to running`, 5);
  }
  // The body must be byte-identical to what the hub stored: report_status
  // matches on to_name + content equality, so it is fetched, never retyped.
  const body = t.task.content;
  if (t.task.status === "delivered") {
    // The hub only accepts running for delivered/acked tasks, and an unacked
    // inbox row keeps the node pinned as in-flight. Ack first.
    const a = await mcp("ack_inbox", { alias, message_id: id, network_id });
    if (!a.ok) die(`could not ack ${id} before starting it: ${a.error || "unknown"}`, 5);
    console.log(`acked ${id} first (it was still delivered)`);
  }
  const state = {
    status: "working",
    progress: Number.isFinite(progress) ? progress : null,
    task: body,
  };
  writeState(state);
  await reportOnce(state);
  const after = await mcp("get_task", { task_id: id });
  const status = after.task ? after.task.status : "?";
  if (status !== "running") {
    die(
      `task ${id} did not reach running (hub says ${status}) — the body sent did not match the stored body`,
      5,
    );
  }
  console.log(`task ${id} is now running`);
  out({ ok: true, task_id: id, status });
}

async function setState(state, progress) {
  if (!STATES.includes(state)) die(`usage: state <${STATES.join("|")}> [progress]`, 2);
  const prev = readState();
  const next = {
    status: state,
    progress: Number.isFinite(progress) ? progress : 0,
    task: state === "working" ? prev.task : null,
  };
  writeState(next);
  await reportOnce(next);
  out({ ok: true, state: next });
}

async function replyTask(id, text, status, via) {
  if (!id || !text) die('usage: reply <task_id> "<text>" [replied|failed|cancelled]', 2);
  const t = await mcp("get_task", { task_id: id });
  if (!t.ok || !t.task) die(`task ${id} not found`, 5);
  if (TERMINAL.includes(t.task.status)) {
    die(`task ${id} is already ${t.task.status} — nothing to close`, 5);
  }
  const outcome = status || "replied";
  if (via === "send_reply" || outcome !== "replied") {
    // send_reply finalizes the task and drops a reply into the sender's inbox.
    // in_reply_to must be the original task id; the target is derived from it.
    const r = await mcp("send_reply", { in_reply_to: id, text, status: outcome, network_id });
    if (!r.ok) {
      die(
        `reply failed: ${r.error || "unknown"}` +
        (r.error === "reply_task_terminal" ? " — the task was closed by someone else" : ""),
        5,
      );
    }
  } else {
    // report_completion matches the task id first and also flips the session
    // back to idle, so the heartbeat has nothing left to report.
    const r = await mcp("report_completion", {
      alias,
      task: id,
      result: text,
      network_id,
    });
    if (!r.ok) die(`report_completion failed: ${JSON.stringify(r)}`, 5);
  }
  writeState({ status: "idle", progress: 0, task: null });
  await reportOnce({ status: "idle", progress: 0, task: null });
  const after = await mcp("get_task", { task_id: id });
  console.log(`replied to ${id} (hub task status: ${after.task ? after.task.status : "?"})`);
  out({ ok: true, task_id: id, status: after.task ? after.task.status : null });
}

async function sayTo(target, text) {
  if (!target || !text) die('usage: say <alias> "<text>"', 2);
  const r = await mcp("send_message", { alias: target, message: text, network_id });
  console.log(JSON.stringify(r));
  if (!r.ok) die(`send_message failed: ${r.error || "unknown"}`, 5);
}

function ageSeconds(stamp) {
  if (!stamp) return null;
  const t = Date.parse(String(stamp).replace(" ", "T") + "Z");
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.round((Date.now() - t) / 1000));
}

async function check() {
  const verdict = [];
  const status = await mcp("get_all_status", { filter_alias: alias });
  const session = (status.sessions || []).find((s) => s.alias === alias) || null;
  const inbox = await mcp("get_inbox", { alias, limit: 50, network_id });
  const pending = inbox.messages || [];
  const tasks = await mcp("list_tasks", { alias, network_id, limit: 50 });
  const open = (tasks.tasks || []).filter(
    (t) => ["created", "delivered", "acked", "running"].includes(t.status),
  );

  console.log(`node        : ${alias}`);
  console.log(`session     : ${session ? session.status : "no session row (never registered)"}`);
  if (session) {
    console.log(`last seen   : ${session.last_seen_at || session.updated_at || "?"}`);
    console.log(`hub task txt: ${session.task || "(empty)"}`);
    console.log(`queue depth : ${session.queue_depth == null ? "?" : session.queue_depth}`);
  }
  console.log(`pending     : ${pending.length} inbox row(s), ${open.length} open task(s)`);
  for (const t of open) {
    const age = ageSeconds(t.created_at);
    console.log(
      `- ${t.task_id} status=${t.status} age=${age == null ? "?" : age + "s"} from=${t.from_name}`,
    );
  }

  if (!session) {
    verdict.push("no session row — the node never registered: run init, then start");
  } else {
    for (const t of open) {
      const age = ageSeconds(t.created_at);
      if (t.status === "delivered") {
        verdict.push(
          `task ${t.task_id} is still delivered` +
          (age == null ? "" : ` after ${age}s`) +
          " — nobody acked it: the node is reachable but the work never started",
        );
      } else if (t.status === "acked") {
        verdict.push(
          `task ${t.task_id} is acked but not running` +
          " — the body was never reported verbatim: use working <task_id>",
        );
      } else if (t.status === "running") {
        verdict.push(`task ${t.task_id} is running — the work is in progress`);
      } else if (t.status === "created") {
        verdict.push(`task ${t.task_id} was created but never delivered to the inbox`);
      }
    }
    if (!open.length) {
      verdict.push("no open tasks — nothing is in flight");
    }
  }
  console.log("");
  for (const v of verdict) console.log("verdict: " + v);
  out({ ok: true, alias, session: session ? session.status : null, pending: pending.length, open_tasks: open.length, verdict });
}

// ── entry point ────────────────────────────────────────────────────────────
async function main() {
  if (MODE === "watch") {
    for (;;) {
      try {
        await heartbeatOnce();
      } catch (e) {
        console.error(`${nowIso()} heartbeat failed: ${e.message}`);
      }
      await sleep(INTERVAL);
    }
  } else if (MODE === "once") {
    await heartbeatOnce();
  } else if (MODE === "init") {
    await registerNode();
  } else if (MODE === "inbox") {
    await listInbox();
  } else if (MODE === "show") {
    await showTask(ARGS[0]);
  } else if (MODE === "ack") {
    await ackTask(ARGS[0]);
  } else if (MODE === "working") {
    await workingTask(ARGS[0], ARGS[1] == null ? null : Number(ARGS[1]));
  } else if (MODE === "state") {
    await setState(ARGS[0], ARGS[1] == null ? null : Number(ARGS[1]));
  } else if (MODE === "reply") {
    const via = (process.env.ANET_MANUAL_REPLY_VIA || "completion").trim();
    const positional = ARGS.filter((a) => a !== "--via");
    if (!["completion", "send_reply"].includes(via)) die(`unknown --via ${via}`, 2);
    await replyTask(positional[0], positional[1], positional[2], via);
  } else if (MODE === "say") {
    await sayTo(ARGS[0], ARGS[1]);
  } else if (MODE === "check") {
    await check();
  } else {
    die("unknown mode: " + MODE, 2);
  }
}

main().catch((e) => {
  console.error("error: " + (e && e.message ? e.message : String(e)));
  process.exit(1);
});
EOFJS
  chmod 600 "$CLIENT"
}

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

cmd_start() {
  if running; then
    echo "already running (pid $(cat "$PIDFILE"))"
    return 0
  fi
  write_client
  env \
  "ANET_MANUAL_CONFIG=$CONFIG" "ANET_MANUAL_STATUSFILE=$STATUSFILE" \
  "ANET_MANUAL_INTERVAL=$INTERVAL" "ANET_MANUAL_HUB=$HUB_OVERRIDE" \
  "ANET_MANUAL_NETWORK=$NETWORK_OVERRIDE" "ANET_MANUAL_NODE=$NODE_NAME" \
  "ANET_MANUAL_TOKEN=$TOKEN_OVERRIDE" "ANET_MANUAL_USER_TOKEN=$USER_TOKEN_OVERRIDE" \
  "ANET_MANUAL_REPLY_VIA=$REPLY_VIA" \
  "ANET_MANUAL_JSON=$JSON_OUT" \
    nohup "$JSBIN" "$CLIENT" watch >>"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 1
  if running; then
    echo "started heartbeat (pid $(cat "$PIDFILE"), every ${INTERVAL}s) -> $LOGFILE"
  else
    echo "failed to start (see $LOGFILE)"
    tail -n 20 "$LOGFILE" 2>/dev/null || true
    return 1
  fi
}

cmd_stop() {
  if [ ! -f "$PIDFILE" ]; then
    echo "not running (no pidfile)"
    return 0
  fi
  pid="$(cat "$PIDFILE")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do
      sleep 0.2
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    echo "stopped heartbeat (pid $pid)"
  else
    echo "stale pidfile (pid $pid not running)"
  fi
  rm -f "$PIDFILE"
}

cmd_run() {
  write_client
  exec env \
  "ANET_MANUAL_CONFIG=$CONFIG" "ANET_MANUAL_STATUSFILE=$STATUSFILE" \
  "ANET_MANUAL_INTERVAL=$INTERVAL" "ANET_MANUAL_HUB=$HUB_OVERRIDE" \
  "ANET_MANUAL_NETWORK=$NETWORK_OVERRIDE" "ANET_MANUAL_NODE=$NODE_NAME" \
  "ANET_MANUAL_TOKEN=$TOKEN_OVERRIDE" "ANET_MANUAL_USER_TOKEN=$USER_TOKEN_OVERRIDE" \
  "ANET_MANUAL_REPLY_VIA=$REPLY_VIA" \
  "ANET_MANUAL_JSON=$JSON_OUT" \
    "$JSBIN" "$CLIENT" "$@"
}

case "$COMMAND" in
  init) cmd_run init ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status)
    if running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "not running"; fi
    echo "reported state: $(cat "$STATUSFILE" 2>/dev/null || echo '(none — defaults to idle)')"
    [ -f "$LOGFILE" ] && tail -n 5 "$LOGFILE" || true
    ;;
  logs) tail -f "$LOGFILE" ;;
  once) cmd_run once ;;
  inbox) cmd_run inbox ;;
  show) cmd_run show "${ARGS[@]}" ;;
  ack) cmd_run ack "${ARGS[@]}" ;;
  working) cmd_run working "${ARGS[@]}" ;;
  state) cmd_run state "${ARGS[@]}" ;;
  reply) cmd_run reply "${ARGS[@]}" ;;
  say) cmd_run say "${ARGS[@]}" ;;
  check) cmd_run check ;;
  ""|-h|--help|help) usage ;;
  *)
    echo "unknown command: $COMMAND (see: $SCRIPT_NAME --help)" >&2
    exit 2
    ;;
esac
