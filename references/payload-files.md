# Payload files: the long text lives here, the parameter carries a pointer

Companion to `SKILL.md` §1.2. The rule in one line: a commhub **parameter is a pointer**, the
**payload file is the document**. This file is the full specification of that split — the budgets,
the segment format, the guards, the handoff routes, and the failure modes.

## Why the split exists

Three hub behaviours make a long parameter actively dangerous:

1. **`sessions.task` keeps the first 200 characters and cuts them blindly** — no sentence awareness,
   no newline awareness. The dashboard node card, `get_all_status` and `/api/status` all read that
   column, so a pasted spec appears there as a mangled half sentence.
2. **`report_status(status="working", task=X)` matches `to_name = alias AND content = X` byte for
   byte.** To move `acked → running`, the worker has to reproduce the whole body. A 2000-character
   body is reproduced by a language model and copied through an MCP argument; a single drifted
   newline, space, or "tidied" quote ends the match and the task rots in `acked`. A 4-line pointer
   round-trips.
3. **The body is paid for twice** — the dispatcher writes it, the worker echoes it. Long bodies are
   output tokens on both machines, and they are where truncation and copy drift begin.

The file side is strictly better: a payload file is versioned, reviewable, diff-able, reviewable in
the repo, and the same pointer keeps working after `retry_task`.

## Budgets

| argument | budget | hub ceiling (measured) |
|---|---|---|
| `send_task(task=…)` (pointer body) | ≤ 800 characters, **no line cap**, line 1 ≤ 100 **plain text** | 10 000 (`TASK_CONTENT_MAX`) |
| `send_task(task=…)` (brief body, §1.2a) | ≤ 1600 characters, line 1 ≤ 100 plain, `accept:` required, markdown from line 2 | 10 000 (`TASK_CONTENT_MAX`) |
| `send_task(context=…)` | ≤ 400 characters, one line (project + branch + "in your working directory") | 10 000; **no Dashboard surface renders `context`** — its cost is only the worker's context (§1.2) |
| `send_message` / `broadcast` / `send_reply` | ≤ 3000 characters, line 1 ≤ 100 | 10 000 (`send_reply` text) |
| `report_completion(result=…)` | ≤ 2400 characters, line 1 ≤ 100 | accepts 50 000, **stores the first 4000** (`tools.ts:1592`, `:1605`) — 2400 keeps a full 1600-character margin |
| resend body (quotes an existing `task_id`) | ≤ 400 characters, line 1 ≤ 100, **`accept:` required** | quoting a hub task id costs 36 characters; the resend body is what acceptance quotes |

The budgets are **discipline, not limits**: the dispatch body has to be echoed byte-for-byte by the
worker, and a node card shows only a blind 200-character slice, so a longer body buys no display and
adds drift. The delivery body is capped at 2400: the task pane collapses at ≈12 lines **behind a '展开全文 ⌄' button** (`TaskChatPanel.tsx:601`, `:634`), so text past line 12 is one click away, not lost — and the hub's hard cliff is the first 4000 characters stored (`tools.ts:1592`, `:1605`) ("What
renders where" below).

Every number in this table is read from **`scripts/budgets.json`** by `anet_payload.sh`; SKILL.md quotes
the same file, and `budgets-in-docs-match-the-script` refuses a drift. Two hard constraints the file also
carries: the `result` budget stays under the hub's storage cliff (the first **4000** characters stored,
`tools.ts:1592`, `:1605`), and the delivery's line 1 plus the next ≈340 characters are what the task pane
shows before '展开全文 ⌄' (`TaskChatPanel.tsx:601`, `:634`) — conclusion there, item-by-item acceptance after.
TTL discipline is machine-checked at compose time (`--ttl`/`--node-idle`), because the hub does not check it.

## What renders where (measured on the Dashboard, 2026-11-09)
The same text lands on surfaces with **different renderers**, so the format rule is written for the
worst surface, not the best one:

| surface | renderer | visible | measured at |
|---|---|---|---|
| node card (current task) | plain text | `line-clamp-2` → 2 lines, of a **blind 200-character** hub slice | `app/nodes/NodesView.tsx:803` |
| node list row / compact grid | plain text | `truncate` → 1 line (`title` carries the rest) | `NodesView.tsx:872`, `:927` |
| node rail | plain text | 1 line; a draft preview takes 40 characters | `app/components/NodeList.tsx:230`, `:225` |
| **task pane opened from a node** | **markdown** (`react-markdown` + `remark-gfm`, per-element classes, image lightbox) | collapsed at 300px ≈ 12 lines, expandable | `app/components/TaskChatPanel.tsx:492-493`, `:561`, `m.result :1725`, `m.content :1769`, `COLLAPSE_MAX_PX :601` |
| Tasks page, task detail | plain text `whitespace-pre-wrap` | `max-h-64` scroll box | `app/components/TaskDetail.tsx:329`, `:345` |
| Messages page / inbox | plain text `whitespace-pre-wrap` | — | `app/messages/page.tsx:443`, `:488`, `app/messages/inbox/page.tsx:187` |

What follows from that table:

- **Line 1 must be self-sufficient**: list rows show only line 1, a card shows 2 lines, and the hub
  hands the card a blind slice with no notion of where a line ends.
- **Line 1 stays plain, lines 2+ may be markdown.** The task pane renders markdown, so headings,
  `**bold**`, `- ` bullets, `1.` numbering, `>` quotes and inline code read as structure there;
  `guard` enforces exactly that (`line 1 carries …` is a refusal, the same markup from line 2 is not).
- **Use the subset that also reads well as plain text where it matters**: a blank line between blocks,
  `- ` bullets, `key: value` fields (`verdict:` / `tests:` / `report:` / `commit:`).
- **Never** tables: the task pane renders them, every plain surface shows `|---|`. The dashboard had to
  add a markdown component for comments precisely because `## 归因更正`, `**错误**` and backticks were
  being shown **as their own characters** (`app/components/CommentMarkdown.tsx`, issue #1831) — that is
  also why line 1, the only line the previews show, must stay plain.
- **Delivery text ≤2400 characters; line 1 = the conclusion and lines 2–12 (the ≈340 characters the task pane shows before '展开全文 ⌄') = the evidence** — that is where the task pane
  collapses. The long report stays in a file.

Never inside a parameter: a markdown spec, a code block, a log, a diff, a table, the content of a
file, or a path the other machine cannot open — by shape: a leading `/` (POSIX absolute), `~/`, a
drive path `X:\` / `X:/`, or a UNC share `\\host\share`. `scripts/anet_payload.sh guard` names them
by shape, so the rule never encodes one machine's mount prefix.

## Brief body: the task in the parameter, formatted (SKILL.md §1.2a)

Not every task needs a file. A read-only probe, a one-shot fix, a question with a definition of done —
that fits in the body, and the body can be shaped so the task pane renders it as a list:

```text
demo: report this node's branch, commit and runtime version, read-only
purpose: a formatted body the task pane renders as a list

steps:
- pwd
- git rev-parse --abbrev-ref HEAD
- node --version, and say so if it is unavailable

accept:
- the result names the branch, the commit sha and the node version
- the result lists each command you ran, in the order you ran it

deliverable: the result text only, nothing written to disk
report_completion once, result <= 2400 chars, line 1 is the conclusion
```

Audited with `bash scripts/anet_payload.sh guard --body "…" --kind brief`: ≤1600 characters, line 1 ≤100,
the `accept:` block present, markup refused.

**Why length is affordable here** (measured on a live hub with a pi runtime node, 2026-11-09): bodies of
117, 277 and 484 characters all went `delivered → running → replied` in about 20 seconds each. The
`working` flip needs a byte-exact match (`UPDATE tasks SET status='running' … WHERE to_name = ?1 AND
status IN ('delivered','acked') AND content = ?2`, `server/src/tools.ts:1492-1493`), and the node echoes
the body it fetched from the hub — so length costs nothing there. What length does cost: the 200-character
preview on the node card (so line 1 must stand alone), and the worker's context, which pays for every
character of the body on every round.

**Use the pointer shape instead** when the spec exceeds a parameter, needs a `sha12` proof, needs review in
git, or is reused across rounds.

## Payload file: one file per task

Default location (any project-relative directory works; name it in the body) — **one task, one file,
named after the task**, not one file per round:

    commhub_tasks/<round-id>/<task-slug>.md

Why a file per task, in measured terms: the worker `git pull`s and reads the file the pointer names.
A file holding six tasks costs it six tasks' text on every run — five of them are tokens spent on
somebody else's work — and a task body of ≤800 characters cannot tell it where to stop. One file per
task makes the read cost equal to the task. It also makes the fingerprint trivially unambiguous: the
pointer names a file, and the hash is the file's.

File shape (plain markdown, the acceptance list at the bottom):

```markdown
# 导出模块：单元测试

为 exportRows() 补 3 个用例，覆盖空输入、单行、超长行。
把新增用例挂在现有测试目录的导出测试模块下。

验收: 3 个用例全绿，失败时报错指向具体行号。
```

Rules the tooling depends on:

- **One file = one task** (SKILL.md §1, "one task, one deliverable").
- **sha12 = first 12 hex of `sha256(file text)`** — trailing newlines dropped, LF newlines. It is the
  Verify it with `anet_payload.sh verify --file <relpath> --sha12 <the one in your body>`, **never by hand**:
  a `sha1sum` prefix and `git hash-object` are different functions — measured 2026-11-09 a worker
  reported `sha12 50bf273c7813` as mismatched because it compared against `sha1sum` (`566e85ca4e4c`)
  and the git blob (`cc757e1bf91c`); the pointer was right and `verify` confirms it in one call.
  revision fingerprint: it proves the worker is reading the revision the dispatcher meant.
- `anet_payload.sh compose` with no `--seg` emits `file: …  sha12: <file hash>`; `verify` with no
  `--seg` compares the file hash.

## Segment pointers (the supported second shape)

A task that is one section of a document you must not split — a spec chapter, a runbook, a report with
shared preamble — keeps the segment form. Split the file with an anchor heading:

```markdown
# 第 7 轮：导出模块

## seg-01 给导出函数补单元测试
为 exportRows() 补 3 个用例，覆盖空输入、单行、超长行。
验收: 3 个用例全绿，失败时报错指向具体行号。

## seg-02 更新使用文档
把 exportRows() 的参数与默认值写进 docs/guide.md。
验收: 文档构建通过，示例可复制运行。
```

- Segment ids are `seg-NN`, zero-padded, unique inside the file. `seg-2` is accepted and normalized
  to `seg-02`.
- The anchor is a markdown heading (`#`…`######`) whose first token is the segment id; the rest of the
  line is the title.
- **Segment text** = the anchor line through the line before the next anchor, leading/trailing blank
  lines dropped, each line right-stripped, LF newlines.
- **sha12 = first 12 hex of `sha256(segment text)`** — the SEGMENT's hash, never the whole file's.
  (A node that reports a whole-file hash against a segment pointer is using the wrong measure: re-run
  `verify --seg` and quote its output line.)
- Cost, stated plainly: every other segment in that file is read too. Use this shape when the
  document's unity is worth more than the worker's context.

## The pointer body (four lines)

Whole-file pointer (the default):

```text
第7轮 导出测试：给导出函数补单元测试，3 个用例全绿
file: commhub_tasks/r07/export-tests.md  sha12: 756d1c7db68e
branch main (git pull first); work it in your own working directory; accept: every item on the acceptance list in the file
report_completion once, result <= 2400 chars
```

Segment pointer (when the task is one section of a document):

```text
第7轮 seg-01：给导出函数补单元测试，3 个用例全绿
file: commhub_tasks/r07/spec.md  seg: seg-01  sha12: 3f7c64c57fb6
branch main (git pull first); work it in your own working directory; accept: every item on the segment acceptance list
report_completion once, result <= 2400 chars
```

Line 1 is the one-line summary (≤80 chars, a complete sentence). Both bodies are 240–280 characters,
so `sessions.task` — which keeps the first 200, cut blindly — shows line 1, the whole
`file:`/`sha12:` line (it ends near character 95) and the head of line 3: the part a reader needs is
inside the cut, and the tail is not.

A pointer is **not** an excuse for a vague task: the goal, the steps and the acceptance criteria all
live **inside the named file** (or segment), and the body names the file and the acceptance line.

## Building it: `scripts/anet_payload.sh`

Run it (bash + python3; it is local, so it does not spend the round):

```bash
# planner — prints the exact text to pass as send_task(task=…). No --seg = the file is the unit.
bash scripts/anet_payload.sh compose \
    --file commhub_tasks/r07/export-tests.md \
    --summary "第7轮 导出测试：给导出函数补单元测试，3 个用例全绿" \
    --branch main

# worker — proves the pointer before touching anything (non-zero exit = conflict)
bash scripts/anet_payload.sh verify \
    --file commhub_tasks/r07/export-tests.md --sha12 756d1c7db68e --print-body

# both — what is in the file (segments, when a file has them)
bash scripts/anet_payload.sh list --file commhub_tasks/r07/export-tests.md

# anyone — audit a body you already have (a hub row, a draft) against the same rule
bash scripts/anet_payload.sh guard --body "$(printf '%s' "$TASK_BODY")"
```

`--json` on `compose` gives `{body, chars, lines, first_line_chars, file, seg, sha12,
segment_chars}`; on `guard` it gives `{ok, chars, lines, first_line_chars, max_chars,
first_line_max, violations}`. Every count is made in python, so a C locale — which counts bytes and
would read a 90-character Chinese body as 270 — cannot change the verdict.

`--json` gives `{body, chars, lines, first_line_chars, file, seg, sha12, segment_chars}`.

### Guards that refuse a bad dispatch

`compose` refuses, and says why:

- a summary line over 80 characters (`--summary-max`);
- a composed body over `--max` (default 300) or over 6 lines;
- a body containing a code block (the code belongs in the file);
- a path the other machine cannot open: a leading `/`, a `~/` path, a `X:\` drive path, a
  `\\host\share` UNC path, or a payload path that escapes the working directory;
- a payload file that is **not in git** (the other machine pulls the branch — it cannot read your
  disk); pass `--allow-untracked` only when you will ship it as a hub attachment;
- a payload file with **uncommitted changes** (`--allow-dirty` to override);
- and it warns when `HEAD` has unpushed commits: **push before dispatch**.

`verify` refuses (exit 3) when the file is missing, the segment anchor is missing, or the sha12 does
not match. Exit 3 is the signal to **report the conflict**, never to work on the revision you happen
to have. `guard` exits 2 when a body breaks the budget, and `compose` refuses the same list, so the
tests and the humans read the rule from one place.

## Handoff routes (cross-machine)

The payload file travels the same two routes as any delivery (SKILL.md §4):

| route | how | body says |
|---|---|---|
| git (normal) | commit the file, **push the branch**, the worker pulls | `file: <relpath>  seg: seg-NN  sha12: <sha12>` + the branch name |
| hub attachment | `POST /api/upload` (multipart field `file`, Bearer) → `file_id`; name it in `send_task(meta.attachments=[{type:"file", file_id, name, mime, size}])`, or top-level `attachments` on REST `/api/task` | `attachment: <file_id>  sha12: <sha12>` |

A file that exists only on the dispatcher's disk is worse than no file at all — and naming its
absolute path is forbidden in any case.

### The hub-attachment route, exactly

Measured limits (`server/src/uploads.ts`, `server/src/server.ts`), because every one of them is a
failure you will hit in a long run:

| limit | value | what you see |
|---|---|---|
| one file | **12 MiB** | `file_too_large` (checked twice: Content-Length, then the parsed file) |
| per task | **20 attachments** | `too many attachments (max 20)` |
| per token | **60 uploads/hour** | 429 `rate_limited` — do not re-upload one file per task in a busy round |
| entry shape | `type: "file"` + server-generated `file_id` | `bad_attachments` at dispatch, never a silent drop |
| `path` in an entry | stripped by the hub when `file_id` is present | the worker never sees your disk path (by design) |
| who may download | network-scoped: the node's `ntok_` must be bound to the upload's network | **404, never 403** (measured across two networks in `tests/manual_node_e2e.sh`) |

```bash
# dispatcher: the payload script's own command. The hub address comes from --hub/$ANET_HUB,
# the access string from ANET_TOKEN in the environment — deliberately NOT an option, because
# an argv value lands in `ps` output and in shell history. 12 MiB is refused here, before a
# byte goes on the wire, and an untracked file needs --allow-untracked (say you mean to ship
# bytes through the hub, not through the branch).
ANET_TOKEN=… bash scripts/anet_payload.sh upload --file commhub_tasks/r07/spec.md \
    --hub "$COMMHUB_URL" --network <network_id> --name spec.md --mime text/markdown \
    --allow-untracked
#   uploaded: commhub_tasks/r07/spec.md (5123 bytes) -> file_id 3c63099f0bf34bf398708698da2decaf
#   sha12: 54b3cd5aa536
#   put on the pointer line:  attachment: 3c63099f…  sha12: 54b3cd5aa536
#   and in the dispatch:  meta.attachments = [{type: "file", file_id: "3c63099f…", …}]
bash scripts/anet_payload.sh compose --file commhub_tasks/r07/export-tests.md \
    --summary "第7轮 导出测试：给导出函数补单元测试，3 个用例全绿" --allow-untracked
# then send_task(alias=…, task=<the pointer, with `attachment: <file_id>` added>,
#                meta={attachments: [{type: "file", file_id: "<file_id>"}]})
# Underneath, `upload` is one multipart POST — this is the shape it sends, for when you
# must debug it by hand:
#   curl -sS -K - -F "file=@commhub_tasks/r07/export-tests.md;type=text/markdown" "$COMMHUB_URL/api/upload"
#   (the config on stdin carries the Authorization header, so the secret stays off argv)

# worker (runtime node): fetch-attachment.ts pulls it automatically and hands the
# model a local path (text/markdown, txt, json, csv, pdf, docx and images are on
# the allow-list; the prompt block states the content is untrusted input).
# worker (manual node): the same step by hand, with the node's own token —
./anet_manual_node.sh files <task_id>
./anet_manual_node.sh fetch <file_id> --out spec.md --sha12 <12 hex>
```

`--allow-untracked` is the flag for the attachment route: the file is not in git, the hub carries it,
and `compose` says so in the same breath ("…or deliver it as a hub attachment").

## Worker side, in order

1. `git pull` (or `anet_manual_node.sh fetch <file_id> --out … --sha12 …` for an attachment).
2. Run `bash scripts/anet_payload.sh verify --file … --sha12 … --print-body` (add `--seg …` when the
   pointer names a segment).
3. If it refuses: take the task anyway (`ack` → `working`) and state the conflict in
   `report_completion(result=…)`; do not work on a guess and do not widen the change.
4. Work the file the pointer names. Write the deliverable and the long report where the task asks for
    it, commit, push.
5. `report_completion` once, with a ≤2400-character `result` (**line 1 plain = the conclusion**): what you ran
   to verify it, and the path of the long report. From line 2 format it for the task pane — headings,
   bold, `- ` bullets, `key: value` fields, inline code; **tables stay refused** ("What renders where" below).

## Failure modes

| symptom | cause | fix |
|---|---|---|
| Dashboard card shows a half sentence | body longer than 200 chars, cut blindly | pointer body, summary on line 1 |
| Task stuck in `acked` after `working` | the echoed body drifted from the stored one (long bodies drift) | cancel + retry with a short pointer body |
| Worker reports "file not found" | file untracked / unpushed at dispatch time | commit + push, or ship as an attachment |
| Worker reports sha12 mismatch | the file changed after dispatch | re-dispatch the current segment (cancel + retry) |
| `fetch` prints "no such file for this node" | the id is unknown, gone, or uploaded in another network (the hub answers 404, never 403) | `files <task_id>` for the ids the task carries; upload in the node's network |
| 429 `rate_limited` on an upload | 60/hour per caller | one file per round, not one per task; put the segments in one file |
| Two tasks point at the same segment | one segment must be one task | split the segment, re-dispatch |
| `duplicate_send` | the same body re-sent within 5 minutes | don't re-send; `get_task` first (one call, one round) |
