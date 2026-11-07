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

| argument | budget |
|---|---|
| `send_task(task=…)` | ≤ 300 characters, ≤ 6 lines, line 1 ≤ 80 chars |
| `send_task(context=…)` | ≤ 200 characters, one line (project + branch + "in your working directory") |
| `send_message(message=…)` / `broadcast(message=…)` | ≤ 200 characters |
| `report_completion(result=…)` | ≤ 400 characters (the row stores 4000; do not use them all) |

Never inside a parameter: a markdown spec, a code block, a log, a diff, a table, the content of a
file, an absolute path (`/home/…`, `C:\…`, `~/…`).

## Payload file and segment format

Default location (any project-relative directory works; name it in the body):

    commhub_tasks/<round-id>/spec.md

Split it into segments with an anchor heading:

```markdown
# 第 7 轮配图任务

## seg-01 头三段配图
生成 3 张暖金调佛像特写，提示词写回本段"产出"小节。
验收: 3 张图 + 5 条提示词入库。

## seg-02 中段配图
生成 5 张中景，同样写回"产出"小节。
验收: 5 张图入库。
```

Rules the tooling depends on:

- **One segment = one task** (SKILL.md §1, "one task, one deliverable").
- Segment ids are `seg-NN`, zero-padded, unique inside the file. `seg-2` is accepted and normalized
  to `seg-02`.
- The anchor is a markdown heading (`#`…`######`) whose first token is the segment id; the rest of
  the line is the title.
- **Segment text** = the anchor line through the line before the next anchor, leading/trailing blank
  lines dropped, each line right-stripped, LF newlines.
- **sha12** = the first 12 hex characters of `sha256(segment text)`. It is the revision fingerprint:
  it proves the worker is reading the exact file revision the dispatcher meant.

## The pointer body (four lines)

```text
第7轮 seg-01：头三段配图，3 张暖金佛像特写入库
file: commhub_tasks/r07/spec.md  seg: seg-01  sha12: 54b3cd5aa536
branch main (git pull first); work it in your own working directory; accept: every item on the segment acceptance list
report_completion once, result <= 400 chars
```

Line 1 is the one-line summary (≤80 chars, a complete sentence, and the first 200 characters of the
body therefore read as a sentence — the dashboard card shows exactly that).

A pointer is **not** an excuse for a vague task: the goal, the steps and the acceptance criteria all
live **inside the named segment**, and the body names the file, the segment, and the acceptance line.

## Building it: `scripts/anet_payload.sh`

Run it (bash + python3; it is local, so it does not spend the round):

```bash
# planner — prints the exact text to pass as send_task(task=…)
bash scripts/anet_payload.sh compose \
    --file commhub_tasks/r07/spec.md --seg seg-01 \
    --summary "第7轮 seg-01：头三段配图，3 张暖金佛像特写入库" \
    --branch main

# worker — proves the pointer before touching anything (non-zero exit = conflict)
bash scripts/anet_payload.sh verify \
    --file commhub_tasks/r07/spec.md --seg seg-01 --sha12 54b3cd5aa536 --print-body

# both — what is in the file
bash scripts/anet_payload.sh list --file commhub_tasks/r07/spec.md
```

`--json` gives `{body, chars, lines, first_line_chars, file, seg, sha12, segment_chars}`.

### Guards that refuse a bad dispatch

`compose` refuses, and says why:

- a summary line over 80 characters;
- a composed body over `--max` (default 300);
- a body containing a code block (the code belongs in the file);
- an absolute path, a `~/` path, or a path escaping the working directory;
- a payload file that is **not in git** (the other machine pulls the branch — it cannot read your
  disk); pass `--allow-untracked` only when you will ship it as a hub attachment;
- a payload file with **uncommitted changes** (`--allow-dirty` to override);
- and it warns when `HEAD` has unpushed commits: **push before dispatch**.

`verify` refuses (exit 3) when the file is missing, the segment anchor is missing, or the sha12 does
not match. Exit 3 is the signal to **report the conflict**, never to work on the revision you happen
to have.

## Handoff routes (cross-machine)

The payload file travels the same two routes as any delivery (SKILL.md §4):

| route | how | body says |
|---|---|---|
| git (normal) | commit the file, **push the branch**, the worker pulls | `file: <relpath>  seg: seg-NN  sha12: <sha12>` + the branch name |
| hub attachment | `POST /api/upload` → `file_id`; put it in `meta.attachments: [{type:"file", file_id}]` | `attachment: <file_id>  sha12: <sha12>` |

A file that exists only on the dispatcher's disk is worse than no file at all — and naming its
absolute path is forbidden in any case.

## Worker side, in order

1. `git pull` (or download the attachment).
2. Run `bash scripts/anet_payload.sh verify --file … --seg … --sha12 … --print-body`.
3. If it refuses: take the task anyway (`ack` → `working`) and state the conflict in
   `report_completion(result=…)`; do not work on a guess and do not widen the change.
4. Work the printed segment. Write the deliverable and the long report into the segment's 产出
   section, commit, push.
5. `report_completion` once, with a ≤400-character `result`: conclusion, what you ran to verify it,
   and the path of the long report.

## Failure modes

| symptom | cause | fix |
|---|---|---|
| Dashboard card shows a half sentence | body longer than 200 chars, cut blindly | pointer body, summary on line 1 |
| Task stuck in `acked` after `working` | the echoed body drifted from the stored one (long bodies drift) | cancel + retry with a short pointer body |
| Worker reports "file not found" | file untracked / unpushed at dispatch time | commit + push, or ship as an attachment |
| Worker reports sha12 mismatch | the file changed after dispatch | re-dispatch the current segment (cancel + retry) |
| Two tasks point at the same segment | one segment must be one task | split the segment, re-dispatch |
| `duplicate_send` | the same body re-sent within 5 minutes | don't re-send; `get_task` first (one call, one round) |
