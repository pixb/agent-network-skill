#!/usr/bin/env bash
# anet_payload.sh — compose and verify SHORT commhub task bodies that point at a
# segment of a payload file (SKILL.md §1.2, "short params, long text on disk").
#
# The rule this script enforces:
#   · the `task` / `message` argument of a commhub call stays short (<= 300 chars,
#     <= 6 lines, first line <= 80 chars);
#   · the long text (spec, steps, acceptance list, code, tables) lives in a file
#     inside the project working tree, split into `## seg-NN` segments;
#   · the parameter carries only: relative path + segment id + sha12 + acceptance.
#
# Why the sha12 is not decoration: `report_status(status="working", task=…)`
# matches the stored body byte-for-byte, and `sessions.task` keeps only the first
# 200 characters (cut blindly). A short body is what makes the exact match
# survive the round-trip; the sha12 is what makes the pointer verifiable, so a
# worker never works on the wrong revision of the file.
#
# usage:
#   anet_payload.sh compose --file <relpath> --seg <seg-id> --summary "<=80 chars>"
#                           [--accept "<one line>"] [--deliver "<one line>"]
#                           [--branch <name>] [--max 300] [--json]
#       prints the exact text to pass as send_task(task=…)
#   anet_payload.sh verify  --file <relpath> --seg <seg-id> [--sha12 <expected>]
#                           [--print-body] [--json]
#       worker side: proves the file, the segment and the revision are the ones
#       the task pointed at; exits non-zero when they are not
#   anet_payload.sh list    --file <relpath> [--json]
#       segment ids, titles and character counts
#
# segment convention (in the payload file):
#   ## seg-01 <title>
#   …steps, acceptance, anything long…
#   ## seg-02 <title>
# segment text = the anchor line through the line before the next anchor, with
# trailing blanks stripped; sha12 = first 12 hex chars of sha256(segment text).
#
# options:
#   --project-root <dir>  repo that holds the payload file (default: $PWD)
#   --allow-dirty         do not refuse a file with uncommitted changes
#   --allow-untracked     do not refuse a file that is not in git
#   --force               compose even when a guard rejects the body
#   -h, --help            this text
#
# Needs bash + python3. Writes nothing except --print-body output; it never
# touches the hub, so it is not a commhub call and does not spend the round.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "$SCRIPT_NAME: $*" >&2; exit "${2:-2}"; }
warn() { echo "$SCRIPT_NAME: $*" >&2; }

CMD="${1:-}"
[ -n "$CMD" ] || die "no command given (see --help)"
case "$CMD" in -h|--help|help) usage; exit 0 ;; esac
shift

FILE="" SEG="" SUMMARY="" ACCEPT="" DELIVER="" BRANCH="" MAX="300"
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
    --sha12) SHA12="${2:-}"; shift 2 ;;
    --project-root) PROJECT="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    --print-body) PRINT_BODY=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --allow-untracked) ALLOW_UNTRACKED=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$FILE" ] || die "compose/verify/list need --file <relpath>"
case "$FILE" in
  /*) die "the payload path must be relative (no absolute path in a task body): $FILE" ;;
  '~'*|*'/../'*|../*) die "the payload path must stay inside the working directory: $FILE" ;;
esac
case "$FILE" in *$'\n'*) die "the payload path cannot contain a newline" ;; esac
FULL="$PROJECT/$FILE"
[ -f "$FULL" ] || die "no such payload file: $FILE (relative to $PROJECT)"

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
META="$(py)" || die "could not read the payload file"
SEG_JSON() { python3 -c "import json,sys;d=json.loads(sys.argv[1]);v=d.get(sys.argv[2],'');print(v if isinstance(v,str) else json.dumps(v,ensure_ascii=False))" "$META" "$1"; }

case "$CMD" in
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
  compose|verify) ;;
  *) die "unknown command: $CMD (see --help)" ;;
esac

if [ "$CMD" = "verify" ]; then
  [ -n "$SEG" ] || die "verify needs --seg <seg-id>"
  if [ -n "$(SEG_JSON missing_seg)" ]; then
    die "the task points at $(SEG_JSON missing_seg), which the file does not contain — report the conflict, do not guess" 3
  fi
  if [ -n "$(SEG_JSON no_anchors)" ]; then
    die "$FILE has no '## seg-NN' anchors — the pointer has nothing to point at" 3
  fi
  ACTUAL="$(SEG_JSON sha12)"
  EXPECT="${SHA12:-$(SEG_JSON sha_expected)}"
  if [ "$JSON" = 1 ]; then
    if [ -n "$EXPECT" ] && [ "$EXPECT" != "$ACTUAL" ]; then echo "$META"; exit 3; fi
    echo "$META"; exit 0
  fi
  echo "file   : $FILE"
  echo "segment: $(SEG_JSON seg)  ($(SEG_JSON chars) chars)"
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
[ -n "$SEG" ] || die "compose needs --seg <seg-id>"
[ -n "$SUMMARY" ] || die "compose needs --summary \"<one line>\""
if [ -n "$(SEG_JSON missing_seg)" ]; then die "the file has no segment $(SEG_JSON missing_seg)" 2; fi
if [ -n "$(SEG_JSON no_anchors)" ]; then die "$FILE has no '## seg-NN' anchors — split it first" 2; fi
if [ "$(SEG_JSON duplicate_anchor)" = "true" ]; then warn "segment $SEG appears more than once in $FILE — segment ids must be unique"; fi

SEGSHA="$(SEG_JSON sha12)"
SEGCHARS="$(SEG_JSON chars)"
SUMCHARS="${#SUMMARY}"
[ "$SUMCHARS" -le 80 ] || die "the summary line is $SUMCHARS chars (max 80): sessions.task keeps only the first 200 chars and cuts blindly"

ACCEPT="${ACCEPT:-accept: every item on the segment acceptance list}"
DELIVER="${DELIVER:-report_completion once, result <= 400 chars}"
BRANCH_LINE=""
if [ -n "$BRANCH" ]; then BRANCH_LINE="branch $BRANCH (git pull first); "; fi

BODY="$(python3 - "$SUMMARY" "$FILE" "$META" "$SEGSHA" "$BRANCH_LINE" "$ACCEPT" "$DELIVER" <<'PY'
import json, sys
summary, rel, meta_json, sha, branch_line, accept, deliver = sys.argv[1:8]
meta = json.loads(meta_json)
seg = meta.get('seg', '')
lines = [
    summary.strip(),
    f"file: {rel}  seg: {seg}  sha12: {sha}",
    f"{branch_line}work it in your own working directory; {accept}",
    deliver.strip(),
]
print("\n".join(lines))
PY
)"

[ ${#BODY} -le "$MAX" ] || die "the composed body is ${#BODY} chars (max $MAX) — the long text belongs in the file, not in the parameter${FORCE:+; pass --force to override}"
case "$BODY" in
  *'```'*) die "the body contains a code block — code belongs in the payload file" ;;
  */home/*|*'/vol1/'*|*'~/'*|*'C:\'*) die "the body contains an absolute path (§4 forbids it)" ;;
esac

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
warn "body: ${#BODY} chars, ${SUMCHARS} on line 1 — one commhub call this round (SKILL.md §1.1)"
warn "worker side: anet_payload.sh verify --file $FILE --seg $SEG --sha12 $SEGSHA"
