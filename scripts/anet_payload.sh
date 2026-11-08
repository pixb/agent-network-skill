#!/usr/bin/env bash
# anet_payload.sh — compose and verify SHORT commhub task bodies that point at a
# segment of a payload file (SKILL.md §1.2, "short params, long text on disk").
#
# The rule this script enforces:
#   · the `task` / `message` argument of a commhub call stays short (<= 300 chars,
#     <= 6 lines, first line <= 80 chars);
#   · the long text (spec, steps, acceptance list, code, tables) lives in a file
#     inside the project working tree, one file per task (segments only when the
#     task really is one section of a document you must not split);
#   · the parameter carries only: relative path + sha12 (+ seg id) + acceptance.
#
# Budgets and the hub's own ceilings (the budgets below are discipline, not limits):
#   task body      <= 300 chars   hub accepts 10 000 (TASK_CONTENT_MAX)
#   result body    <= 1200 chars  hub stores the first 4000
#   message body   <= 1500 chars  hub accepts 10 000 (send_reply text)
#   line 1         <= 80 chars    sessions.task keeps the first 200, cut blindly
#
# Why the sha12 is not decoration: `report_status(status="working", task=…)`
# matches the stored body byte-for-byte, and `sessions.task` keeps only the first
# 200 characters (cut blindly). A short body is what makes the exact match
# survive the round-trip; the sha12 is what makes the pointer verifiable, so a
# worker never works on the wrong revision of the file.
#
# usage:
#   anet_payload.sh compose --file <relpath> --summary "<=80 chars" [--seg <seg-id>]
#                           [--accept "<one line>"] [--deliver "<one line>"]
#                           [--branch <name>] [--max 300] [--json]
#       prints the exact text to pass as send_task(task=…). WITHOUT --seg the unit is the whole
#       file, which is the default shape: one task, one file, so the worker reads only its task.
#       WITH --seg the unit is that segment (legacy multi-task files, and tasks that are one
#       section of a bigger document) — and then the sha12 is the SEGMENT's hash, not the file's.
#   anet_payload.sh verify  --file <relpath> [--seg <seg-id>] [--sha12 <expected>]
#                           [--print-body] [--json]
#       worker side: proves the file (or the named segment) is the revision the task pointed at;
#       exits non-zero when it is not
#   anet_payload.sh list    --file <relpath> [--json]
#       segment ids, titles and character counts
#   anet_payload.sh guard   --body "<text>" [--max 300] [--summary-max 80] [--no-markup] [--json]
#       audit a body you already have (a hub row, a draft): char/line budget, first
#       line budget, code block, absolute path. It is the same rule the compose
#       guards apply, so a test can assert the rule against a stored body without
#       duplicating the pattern — and it counts characters in python, so a C locale
#       cannot turn a 100-character Chinese body into a 300-byte one.
#       A delivered result is audited with the delivery budget: --max 1200 --no-markup.
#       --no-markup refuses the markup that the Dashboard's plain-text surfaces
#       (node card, node list rows, Tasks detail, Messages) show as raw characters:
#       tables, `#` headings, `**bold**`, backticks. The task pane is the one surface
#       that renders markdown, and a table there is paid for by four plain surfaces.
#   anet_payload.sh upload  --file <relpath> [--hub <url>] [--network <id>]
#                           [--name <n>] [--mime <m>] [--allow-untracked] [--json]
#       the dispatcher's half of the hub-attachment route: put these bytes on the hub,
#       print the file_id, the sha12, the pointer line to paste and the meta.attachments
#       entry to dispatch with. 12 MiB is refused before anything goes on the wire; the
#       access string is read from ANET_TOKEN in the environment and is deliberately not
#       an option, because an argv value lands in ps and in shell history.
#
# segment convention (in the payload file):
#   ## seg-01 <title>
#   …steps, acceptance, anything long…
#   ## seg-02 <title>
# segment text = the anchor line through the line before the next anchor, with
# trailing blanks stripped; sha12 = first 12 hex chars of sha256(segment text).
#
# absolute path = a path a second machine cannot open: a leading `/` token, a `~/`
# token, a `X:\` drive path, or a `\\host\share` UNC path. Named generically, so no
# particular server's mount prefix is encoded in the rule. URLs are not paths here.
#
# options:
#   --project-root <dir>  repo that holds the payload file (default: $PWD)
#   --max <n>            body budget in characters (guard defaults: task 300, result 1200)
#   --kind task|result|brief|resend   guard: which text is audited
#       task   ≤300, ≤6 lines — the pointer body (§1.2)
#       brief  ≤1200, lines free, markup refused, `accept:` required — a formatted body with no payload file
#       result ≤1200, lines free, markup refused — the delivered result text
#       resend ≤340, `accept:` required — a body quoting an existing task id (quoting it costs 36 chars)
#   --summary-max <n>    first-line budget in characters (default 80)
#   --no-markup          guard only: refuse markup plain-text surfaces cannot render
#   --allow-dirty         do not refuse a file with uncommitted changes
#   --allow-untracked     do not refuse a file that is not in git
#   --force               compose even when a guard rejects the body
#   --hub <url>           upload: the hub to put the file on (default: $ANET_HUB)
#   --network <id>        upload: which network the file is attributed to
#   --name <name>         upload: the name the worker sees (default: the file name)
#   --mime <mime>         upload: the media type (default: application/octet-stream)
#   -h, --help            this text
#
# Needs bash + python3 (and curl for `upload`). It writes nothing to the working tree.
# `guard`/`compose`/`verify`/`list` never touch the hub, so they are not a commhub call
# and do not spend the round; `upload` is one HTTP call to the hub, not a commhub tool
# call — it does not move a task, so it does not spend a task round either.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }
# The exit code is the SECOND argument and must never reach the message: an earlier
# version used $*, so `die "no segment seg-09" 2` printed “no segment seg-09 2” and a
# log assertion written against the sentence never matched it.
die() { echo "$SCRIPT_NAME: $1" >&2; exit "${2:-2}"; }
warn() { echo "$SCRIPT_NAME: $*" >&2; }

# Character counts come from python, never from ${#var}: in a non-UTF-8 locale bash
# counts BYTES, and a CJK body then measures ~3x what the spec budgets.
nchars() { python3 -c 'import sys; print(len(sys.argv[1]))' "$1"; }

CMD="${1:-}"
[ -n "$CMD" ] || die "no command given (see --help)"
case "$CMD" in -h|--help|help) usage; exit 0 ;; esac
shift

FILE="" SEG="" SUMMARY="" ACCEPT="" DELIVER="" BRANCH="" MAX=""
KIND="task"
BODY_ARG="" SUMMARY_MAX="80" NO_MARKUP=0
HUB_ARG="" NETWORK="" FNAME="" MIME="application/octet-stream"
# The hub's own cap, measured in server/src/uploads.ts (MAX_UPLOAD_BYTES). It is stated
# as a number here so a 40 MB dataset is refused before a byte is put on the wire.
MAX_UPLOAD_BYTES=12582912
SHA12="" PROJECT="${ANET_PAYLOAD_PROJECT:-$PWD}"
JSON=0 PRINT_BODY=0 ALLOW_DIRTY=0 ALLOW_UNTRACKED=0 FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --seg) SEG="${2:-}"; shift 2 ;;
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    --accept) ACCEPT="${2:-}"; shift 2 ;;
    --deliver) DELIVER="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --max) MAX="${2:-}"; shift 2 ;;
    --summary-max) SUMMARY_MAX="${2:-}"; shift 2 ;;
    --no-markup) NO_MARKUP=1; shift ;;
    --kind) KIND="${2:-task}"; shift 2 ;;
    --body) BODY_ARG="${2:-}"; shift 2 ;;
    --sha12) SHA12="${2:-}"; shift 2 ;;
    --project-root) PROJECT="${2:-}"; shift 2 ;;
    --hub) HUB_ARG="${2:-}"; shift 2 ;;
    --network) NETWORK="${2:-}"; shift 2 ;;
    --name) FNAME="${2:-}"; shift 2 ;;
    --mime) MIME="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    --print-body) PRINT_BODY=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --allow-untracked) ALLOW_UNTRACKED=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ "$CMD" != "guard" ]; then
  [ -n "$FILE" ] || die "compose/verify/list need --file <relpath>"
  case "$FILE" in
    /*) die "the payload path must be relative (no absolute path in a task body): $FILE" ;;
    '~'*|*'/../'*|../*) die "the payload path must stay inside the working directory: $FILE" ;;
  esac
  case "$FILE" in *$'\n'*) die "the payload path cannot contain a newline" ;; esac
  FULL="$PROJECT/$FILE"
  [ -f "$FULL" ] || die "no such payload file: $FILE (relative to $PROJECT)"
fi
FULL="${FULL:-}"   # guard audits a body and never reads a payload file

py() {
python3 - "$FULL" "$SEG" "$SHA12" <<'PY'
import hashlib, json, re, sys

path, seg_arg, sha_arg = sys.argv[1:4]

def norm(s):
    s = (s or "").strip().lower().replace('_', '-').replace(' ', '-')
    m = re.match(r'^seg-?0*(\d{1,3})$', s)
    return 'seg-%02d' % int(m.group(1)) if m else s

raw = open(path, encoding='utf-8', errors='surrogateescape').read()
raw = raw.replace('\r\n', '\n').replace('\r', '\n')
lines = raw.split('\n')

ANCHOR = re.compile(r'^#{1,6}\s*\(?\s*(seg[-_]?\d{1,3})\b\s*(?:[—:|-]{1,2}\s*)?(.*)$', re.I)

anchors = []
for i, line in enumerate(lines):
    m = ANCHOR.match(line.strip())
    if m:
        anchors.append((i, norm(m.group(1)), m.group(2).strip()))

def segment(idx):
    start = anchors[idx][0]
    end = anchors[idx + 1][0] if idx + 1 < len(anchors) else len(lines)
    body = lines[start:end]
    while body and not body[-1].strip():
        body.pop()
    while body and not body[0].strip():
        body.pop(0)
    body = [l.rstrip() for l in body]
    return '\n'.join(body)

out = {'file_ok': True, 'segments': [{'seg': a[1], 'title': a[2], 'line': a[0] + 1} for a in anchors]}

# One task = one file. When no segment is named, the unit is the WHOLE file: its text, its
# character count, its sha12. The reason is a token cost, not aesthetics — a worker that pulls a
# file holding several tasks reads every other task's text on every run, and `sessions.task` only
# keeps 200 characters, so the pointer cannot tell it which part to skip.
whole = raw.rstrip('\n')
out['mode'] = 'file'
out['whole_chars'] = len(whole)
out['whole_sha12'] = hashlib.sha256(whole.encode('utf-8')).hexdigest()[:12]
if not seg_arg:
    out['body'] = whole
    out['chars'] = len(whole)
    out['sha12'] = out['whole_sha12']

if anchors:
    want = norm(seg_arg)
    hits = [i for i, a in enumerate(anchors) if a[1] == want]
    out['want'] = want
    if hits:
        text = segment(hits[0])
        out['seg'] = want
        out['body'] = text
        out['chars'] = len(text)
        out['sha12'] = hashlib.sha256(text.encode('utf-8')).hexdigest()[:12]
        out['duplicate_anchor'] = len(hits) > 1
    else:
        out['missing_seg'] = want
elif seg_arg:
    out['no_anchors'] = True

if sha_arg:
    out['sha_expected'] = sha_arg.strip().lower()
    out['sha_match'] = bool(out.get('sha12')) and out['sha12'] == out['sha_expected']
print(json.dumps(out, ensure_ascii=False))
PY
}

GIT_STATE=""
git_state() {
  GIT_STATE="$(python3 - "$PROJECT" "$FILE" <<'PY'
import json, os, subprocess, sys
root, rel = sys.argv[1:3]
def run(args):
    p = subprocess.run(args, cwd=root, capture_output=True, text=True)
    return p.returncode, (p.stdout or "").strip()
state = {"in_git": False}
rc, top = run(["git", "rev-parse", "--show-toplevel"])
if rc == 0 and top:
    state["in_git"] = True
    rc, relpath = run(["git", "rev-parse", "--show-prefix"])
    rc2, listed = run(["git", "ls-files", "--", rel])
    state["tracked"] = bool(listed.strip())
    rc3, dirty = run(["git", "status", "--porcelain", "--", rel])
    state["dirty"] = bool(dirty.strip())
    rc4, branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    state["branch"] = branch if rc4 == 0 else ""
    rc5, ahead = run(["git", "rev-list", "--count", "@{u}..HEAD"])
    state["unpushed"] = int(ahead) if rc5 == 0 and ahead.isdigit() else None
print(json.dumps(state))
PY
)"
}
git_get() { python3 -c "import json,sys;print(json.loads(sys.argv[1]).get(sys.argv[2],''))" "$GIT_STATE" "$1"; }

# ── segment facts (used by every command) ─────────────────────────────────
if [ "$CMD" = "guard" ]; then META="{}"; else META="$(py)" || die "could not read the payload file"; fi
SEG_JSON() { python3 -c "import json,sys;d=json.loads(sys.argv[1]);v=d.get(sys.argv[2],'');print(v if isinstance(v,str) else json.dumps(v,ensure_ascii=False))" "$META" "$1"; }

# ── the body-shape rule, shared by compose and guard ─────────────────────
# Prints one line per violation; empty output means the body passes.
body_violations() {
  python3 - "$1" "${MAX:-300}" "${SUMMARY_MAX:-80}" "${NO_MARKUP:-0}" "${KIND:-task}" <<'PY'
import re, sys
body = sys.argv[1]
max_chars, max_first, no_markup, kind = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
lines = body.split("\n")
violations = []
if len(body) > max_chars:
    violations.append(f"the body is {len(body)} chars (budget {max_chars}) — the long text belongs in the file, not in the parameter")
if len(lines) > 6 and kind not in ("result", "brief"):
    violations.append(f"the body is {len(lines)} lines (budget 6)")
# A body that names an existing task is a RESCHEDULE: it is the text the operator will accept against,
# so it must carry a requirement line. Trigger: a task id quoted in the body (hub ids are uuid4, which
# no file path, sha12, branch name or URL produces). Measured 2026-11-09: a timeout resend was
# dispatched with the quoted id and no acceptance line, and acceptance became a prose argument.
if re.search(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", body, re.I) or kind == "brief":
    if not re.search(r"(?i)\baccept(ance)?\b|验收", body):
        violations.append(
            "the body names an existing task id (a reschedule) or is a brief body, and carries no "
            "requirement line — the body must contain an `accept:` line naming what counts as done, "
            "otherwise acceptance has nothing to quote (measured 2026-11-09: a timeout resend without one)"
        )
if lines and len(lines[0]) > max_first:
    violations.append(f"line 1 is {len(lines[0])} chars (budget {max_first}): sessions.task keeps only the first 200 chars and cuts blindly")
if '```' in body:
    violations.append("the body contains a code block — code belongs in the payload file")
if no_markup or kind in ("result", "brief"):
    # Measured on the Dashboard: the node card (NodesView.tsx line-clamp-2), the node list rows
    # (truncate), the Tasks detail (TaskDetail.tsx, whitespace-pre-wrap) and the Messages page all
    # render PLAIN text; only the task pane (TaskChatPanel, react-markdown) renders markdown. So a
    # table/heading/bold/backtick is paid for by four plain surfaces, where it shows as its own
    # characters. The subset that reads well everywhere: blank lines, `- ` bullets, `key: value`.
    for pattern, label in [
        (r"(?m)^\s*\|.*\|\s*$", "a table row (`| … |`)"),
        (r"(?m)^\s*#{1,6}\s", "a `#` heading"),
        (r"\*\*[^*]+\*\*", "`**bold**` markup"),
        (r"`[^`]+`", "backticks"),
    ]:
        if re.search(pattern, body):
            violations.append(
                f"the text carries {label}: the node card, node list rows, the Tasks detail and the "
                "Messages page render plain text, so it appears there as its own characters — use "
                "blank lines, `- ` bullets and `key: value` fields"
            )
# Token classification, not a pattern that can catch the tail of a URL: a path counts
# when a whitespace-separated token — punctuation stripped — starts with `/` (POSIX
# absolute), `~/` (home-relative), `X:\` or `X:/` (Windows drive) or `\\host\` (UNC).
# Named by shape, so no particular server's mount prefix is encoded in the rule.
def classify(raw):
    token = raw.strip("()[]{}<>,;:'\"")
    if not token:
        return None
    if re.match(r"^[A-Za-z]:[\\/]", token):
        return "Windows drive path"
    if token.startswith("\\\\"):
        return "UNC path"
    if token.startswith("~/"):
        return "home-relative path (~/)"
    if token.startswith("//"):
        return None  # protocol-relative URL, not a path
    if token.startswith("/"):
        return "absolute path"
    return None

for raw in re.split(r"[\s;]+", body):
    label = classify(raw)
    if label:
        violations.append(
            "the parameter carries a path the other machine cannot open — "
            f"{label}: {raw.strip('()[]{}<>,;:\'"')} (§4 forbids absolute paths)"
        )

seen = set()
for item in violations:
    if item not in seen:
        seen.add(item)
        print(item)
PY
}

case "$CMD" in
  guard)
    [ -n "${BODY_ARG:-}" ] || die "guard needs --body \"<text>\""
    # The budget depends on which kind of text is audited. The hub accepts far more than the protocol
    # spends (measured in server/src): task 10 000, result stores 4000, send_reply 10 000.
    if [ -z "$MAX" ]; then
      case "$KIND" in
        result) MAX=1200 ;;
        brief) MAX=1200 ;;
        resend) MAX=340 ;;
        *) MAX=300 ;;
      esac
    fi
    PROBLEMS="$(body_violations "$BODY_ARG")" || die "guard could not audit the body"
    CHARS="$(nchars "$BODY_ARG")"
    LINES="$(printf '%s' "$BODY_ARG" | python3 -c 'import sys; print(len(sys.stdin.read().split("\n")))')"
    FIRST="$(printf '%s' "$BODY_ARG" | head -1 | python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))')"
    if [ "$JSON" = 1 ]; then
      python3 - "$CHARS" "$LINES" "$FIRST" "$MAX" "$SUMMARY_MAX" "$PROBLEMS" <<'PY'
import json, sys
chars, lines, first, max_chars, max_first, problems = sys.argv[1:7]
print(json.dumps({
    "ok": not problems,
    "chars": int(chars), "lines": int(lines), "first_line_chars": int(first),
    "max_chars": int(max_chars), "first_line_max": int(max_first),
    "violations": [line for line in problems.split("\n") if line],
}, ensure_ascii=False, indent=2))
PY
      [ -z "$PROBLEMS" ] && exit 0 || exit 2
    fi
    if [ -n "$PROBLEMS" ]; then
      printf '%s\n' "$PROBLEMS" | sed "s/^/$SCRIPT_NAME: /"
      exit 2
    fi
    echo "body ok: $CHARS chars, $LINES lines, $FIRST on line 1"
    exit 0
    ;;
  list)
    if [ "$JSON" = 1 ]; then echo "$META"; exit 0; fi
    N="$(SEG_JSON segments | python3 -c "import json,sys;print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
    if [ "${N:-0}" = 0 ]; then
      echo "no '## seg-NN' anchors in $FILE — split it into segments first"
      exit 1
    fi
    echo "segments in $FILE:"
    python3 - "$META" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for s in d['segments']:
    print(f"  {s['seg']}  line {s['line']}  {s['title']}")
PY
    exit 0
    ;;
  upload)
    # The dispatcher's half of the hub-attachment route: this file's bytes go through
    # the hub and come back as a file_id. Needs curl; the access string is taken from
    # the environment ONLY, because an argv value lands in `ps` output and in shell
    # history, and a task body must never carry one either.
    command -v curl >/dev/null 2>&1 || die "upload needs curl" 1
    HUB="${HUB_ARG:-${ANET_HUB:-}}"
    [ -n "$HUB" ] || die "upload needs the hub: --hub <url> or ANET_HUB (the same address the node config uses)" 1
    [ -n "${ANET_TOKEN:-}" ] || die "upload needs ANET_TOKEN in the environment (export ANET_TOKEN=…): the token is deliberately NOT a command-line option, because argv is readable in ps and in shell history" 1
    SIZE="$(python3 -c 'import os,sys;print(os.path.getsize(sys.argv[1]))' "$FULL")"
    [ "$SIZE" -le "$MAX_UPLOAD_BYTES" ] || die "the file is $SIZE bytes; the hub caps one upload at $MAX_UPLOAD_BYTES (12 MiB) — split it, or ship it on the branch" 3
    [ -n "$FNAME" ] || FNAME="$(basename "$FILE")"
    git_state
    if [ "$(git_get in_git)" = "True" ] && [ "$(git_get tracked)" != "True" ]; then
      [ "$ALLOW_UNTRACKED" = 1 ] || die "the file is not in git ($FILE): pass --allow-untracked to say you mean to ship these bytes through the hub rather than through the branch" 3
    fi
    # `dirty` is NOT refused here: on this route the bytes travel, and the sha12 pins
    # exactly which bytes travelled. (The git route refuses them — there the worker
    # pulls a branch, not your working tree.)
    URL="$HUB/api/upload"
    [ -n "$NETWORK" ] && URL="$URL?network_id=$NETWORK"
    # The secret goes to curl through a config file on stdin (-K -), never on argv.
    RAW="$(printf 'header = "Authorization: Bearer %s"\n' "$ANET_TOKEN" \
            | curl -sS -K - -w '\n%{http_code}' \
                  -F "file=@${FULL};type=${MIME};filename=${FNAME}" "$URL" 2>&1)"
    CODE="${RAW##*$'\n'}"
    OUT="${RAW%$'\n'*}"
    case "$CODE" in
      200|201) ;;
      429) die "the hub answered rate_limited (60 uploads per hour per caller): one file per round, not one per task" 4 ;;
      413) die "the hub answered file_too_large: one file is capped at 12 MiB" 4 ;;
      401|403) die "the hub refused the access string (HTTP $CODE): it must be a token valid for this hub, and the network the file lands in must be one its owner can use" 4 ;;
      *) die "upload failed: HTTP ${CODE:-no response} — $(printf '%s' "$OUT" | head -c 300)" 4 ;;
    esac
    FILE_ID="$(printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("file_id", ""))
except Exception:
    print("")' )"
    [ -n "$FILE_ID" ] || die "the hub answered HTTP $CODE without a file_id: $(printf '%s' "$OUT" | head -c 300)" 4
    FILESHA="$(python3 -c 'import hashlib,sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    for chunk in iter(lambda: fh.read(65536), b""):
        h.update(chunk)
print(h.hexdigest()[:12])' "$FULL")"
    if [ "$JSON" = 1 ]; then
      python3 - "$FILE" "$FILE_ID" "$FILESHA" "$SIZE" "$FNAME" "$MIME" "$NETWORK" <<'PY'
import json, sys
rel, fid, sha, size, name, mime, net = sys.argv[1:8]
print(json.dumps({
    "ok": True, "file": rel, "file_id": fid, "sha12": sha, "bytes": int(size),
    "name": name, "mime": mime, "network": net or None,
    "pointer_line": f"attachment: {fid}  sha12: {sha}",
    "meta": {"attachments": [{"type": "file", "file_id": fid, "name": name, "mime": mime, "size": int(size)}]},
}, ensure_ascii=False, indent=2))
PY
      exit 0
    fi
    echo "uploaded: $FILE ($SIZE bytes) -> file_id $FILE_ID"
    echo "sha12: $FILESHA"
    echo "put on the pointer line:  attachment: $FILE_ID  sha12: $FILESHA"
    echo "and in the dispatch:  meta.attachments = [{type: \"file\", file_id: \"$FILE_ID\", name: \"$FNAME\", mime: \"$MIME\", size: $SIZE}]"
    warn "the hub generates the file_id (^[A-Za-z0-9_-]{8,64}$) and strips any path beside it: your local path never travels"
    [ -n "$NETWORK" ] || warn "no --network given: with a user token the upload can land unattributed, and an unattributed file is refused (cross_network_file) for a node token — name the network the worker belongs to"
    exit 0
    ;;
  compose|verify) ;;
  *) die "unknown command: $CMD (see --help)" ;;
esac

if [ "$CMD" = "verify" ]; then
  # `--seg` is optional: with no segment named, the unit is the whole file (one task = one file).
  if [ -n "$SEG" ] && [ -n "$(SEG_JSON missing_seg)" ]; then
    die "the task points at $(SEG_JSON missing_seg), which the file does not contain — report the conflict, do not guess" 3
  fi
  if [ -n "$SEG" ] && [ -n "$(SEG_JSON no_anchors)" ]; then
    die "$FILE has no '## seg-NN' anchors — the pointer has nothing to point at" 3
  fi
  ACTUAL="$(SEG_JSON sha12)"
  EXPECT="${SHA12:-$(SEG_JSON sha_expected)}"
  if [ -n "$EXPECT" ] && [ -z "$ACTUAL" ]; then
    die "the file produced no sha to compare — pass --seg <seg-id> for a segment-level check" 3
  fi
  if [ "$JSON" = 1 ]; then
    if [ -n "$EXPECT" ] && [ "$EXPECT" != "$ACTUAL" ]; then echo "$META"; exit 3; fi
    echo "$META"; exit 0
  fi
  echo "file   : $FILE"
  if [ -n "$SEG" ]; then
    echo "segment: $(SEG_JSON seg)  ($(SEG_JSON chars) chars)"
  else
    echo "unit   : the whole file  ($(SEG_JSON chars) chars)"
  fi
  echo "sha12  : $ACTUAL${EXPECT:+  expected $EXPECT}"
  if [ -n "$EXPECT" ] && [ "$EXPECT" != "$ACTUAL" ]; then
    echo "MISMATCH — this file is not the revision the task pointed at."
    echo "Do NOT work on a guess: report the conflict in report_completion(result=…)."
    exit 3
  fi
  git_state
  [ "$(git_get in_git)" = "True" ] && {
    [ "$(git_get tracked)" = "True" ] || [ "$ALLOW_UNTRACKED" = 1 ] || die "the payload file is not in git ($FILE): the other machine cannot pull it — commit it, or pass --allow-untracked (then deliver it as a hub attachment)" 3
    [ "$(git_get dirty)" = "True" ] && [ "$ALLOW_DIRTY" = 0 ] && die "the payload file has uncommitted changes ($FILE): the worker cannot see them — commit and push, or pass --allow-dirty" 3
  }
  if [ "$PRINT_BODY" = 1 ]; then
    echo "--- segment body -------------------------------------------------"
    python3 - "$META" <<'PY'
import json, sys
print(json.loads(sys.argv[1])['body'])
PY
  fi
  exit 0
fi

# ── compose ───────────────────────────────────────────────────────────────
# No --seg = the unit is the WHOLE file. That is the default shape now: one task, one file, so the
# worker reads its own task and nobody else's text.
[ -n "$SUMMARY" ] || die "compose needs --summary \"<one line>\""
if [ -n "$SEG" ]; then
  if [ -n "$(SEG_JSON missing_seg)" ]; then die "the file has no segment $(SEG_JSON missing_seg)" 2; fi
  if [ -n "$(SEG_JSON no_anchors)" ]; then die "$FILE has no '## seg-NN' anchors — split it first" 2; fi
  if [ "$(SEG_JSON duplicate_anchor)" = "true" ]; then warn "segment $SEG appears more than once in $FILE — segment ids must be unique"; fi
fi

SEGSHA="$(SEG_JSON sha12)"
SEGCHARS="$(SEG_JSON chars)"
SUMCHARS="$(nchars "$SUMMARY")"
[ "$SUMCHARS" -le "$SUMMARY_MAX" ] || die "the summary line is $SUMCHARS chars (max $SUMMARY_MAX): sessions.task keeps only the first 200 chars and cuts blindly"

if [ -n "$SEG" ]; then
  ACCEPT="${ACCEPT:-accept: every item on the segment acceptance list}"
else
  ACCEPT="${ACCEPT:-accept: every item on the acceptance list in the file}"
fi
DELIVER="${DELIVER:-report_completion once, result <= 1200 chars}"
BRANCH_LINE=""
if [ -n "$BRANCH" ]; then BRANCH_LINE="branch $BRANCH (git pull first); "; fi

BODY="$(python3 - "$SUMMARY" "$FILE" "$META" "$SEGSHA" "$BRANCH_LINE" "$ACCEPT" "$DELIVER" <<'PY'
import json, sys
summary, rel, meta_json, sha, branch_line, accept, deliver = sys.argv[1:8]
meta = json.loads(meta_json)
seg = meta.get('seg', '')
# One task = one file: with no segment named, the pointer names the file and the file's sha12.
pointer = f"file: {rel}  seg: {seg}  sha12: {sha}" if seg else f"file: {rel}  sha12: {sha}"
lines = [
    summary.strip(),
    pointer,
    f"{branch_line}work it in your own working directory; {accept}",
    deliver.strip(),
]
print("\n".join(lines))
PY
)"

BODY_PROBLEMS="$(body_violations "$BODY")"
if [ -n "$BODY_PROBLEMS" ] && [ "$FORCE" != 1 ]; then
  printf '%s\n' "$BODY_PROBLEMS" >&2
  die "the composed body breaks the parameter budget (see the lines above; pass --force to override)"
fi

git_state
if [ "$(git_get in_git)" = "True" ]; then
  if [ "$(git_get tracked)" = "True" ]; then :; else
    [ "$ALLOW_UNTRACKED" = 1 ] || die "the payload file is not in git ($FILE) — commit and push it before dispatch, or deliver it as a hub attachment (meta.attachments file_id)"
  fi
  if [ "$(git_get dirty)" = "True" ] && [ "$ALLOW_DIRTY" = 0 ]; then
    die "the payload file has uncommitted changes ($FILE): the worker pulls the branch, so it cannot see them — commit and push, or pass --allow-dirty"
  fi
  UNPUSHED="$(git_get unpushed)"
  case "$UNPUSHED" in ''|0|None) : ;; *) warn "HEAD has $UNPUSHED unpushed commit(s): push before dispatch, the worker pulls the branch" ;; esac
fi

if [ "$JSON" = 1 ]; then
  python3 - "$BODY" "$FILE" "$META" "$SUMCHARS" <<'PY'
import json, sys
body, rel, meta_json, sumchars = sys.argv[1:5]
meta = json.loads(meta_json)
print(json.dumps({
    "body": body,
    "chars": len(body),
    "lines": len(body.split("\n")),
    "first_line_chars": int(sumchars),
    "file": rel,
    "seg": meta.get("seg", ""),
    "sha12": meta.get("sha12", ""),
    "segment_chars": meta.get("chars", 0),
    "note": "one commhub call this round; the body is what the worker must echo byte-for-byte",
}, ensure_ascii=False, indent=2))
PY
  exit 0
fi

printf '%s\n' "$BODY"
warn "body: $(nchars "$BODY") chars, ${SUMCHARS} on line 1 — one commhub call this round (SKILL.md §1.1)"
warn "worker side: anet_payload.sh verify --file $FILE${SEG:+ --seg $SEG} --sha12 $SEGSHA"
