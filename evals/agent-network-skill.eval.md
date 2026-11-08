# Evals — agent-network-skill

The skill's behaviour is only as good as the protocol it drives, so the checks are
**behavioural**: they boot a throwaway hub, dispatch a real task to a real manual
node, and assert what the hub actually stored. Nothing here reads prose and calls
it a pass.

## The scenarios

| Case | What it proves |
|---|---|
| `case-1` (`full-lifecycle`) | register → dispatch → ack → working → reply moves the task `delivered → acked → running → replied`, and the result text lands on the task row |
| `case-2` (`stuck-delivered`) | a task nobody touched stays `delivered`, and `check` says so in words — the "online but not working" diagnosis that this skill exists to prevent |
| `case-3` (`terminal-refused`) | a second `reply` on a closed task is refused instead of silently re-opening it |
| `case-4` (`acked-by-other`) | another node `send_ack`s the task; the manual node **refuses** to take it and `check` names it — nobody works a task twice |
| `case-5` (`reassigned-away`) | the task is reassigned to somebody else; `check` names it as **left behind** instead of letting it vanish silently |
| `case-6` (`two-tasks`) | two tasks at once: the second is **refused** (one node, one session slot) and `check` shows which task holds the slot |
| `case-7` (`skipped-working`) | the task is closed **without** `working` — the hub accepts the jump to `replied`, and `reply` **warns** that the run was invisible (no `acked`, no `running`) |
| `case-8` (`chat-and-finished`) | the inbox holds a **chat message** (no task id) and a **finished task** (its row outlives the task) — `inbox` tells the two apart, `reply`/`say` point at `dm`, and `dm` reaches the human |
| `case-9` (`dm-visible-to-manager`) | a mid-task question sent with `dm` is readable in the manager's **own inbox** (`?scope=user`), is **not** in the alias messages the Messages page reads, leaves the task `running`, and the follow-up task still arrives — the asking channel stays open |
| `case-10` (`ask-by-reply-strands`) | the same question written as a plain `reply` (default = `report_completion`) lands only in `completions` + `tasks.result`: absent from the alias messages, absent from the inbox, **no unread for the human**, and the task is terminal so a second reply is refused |
| `case-11` (`ask-by-send-reply-visible`) | one flag apart (`--via send_reply`): the text **is** in the alias messages the Messages page reads (and in the task result), and the task is still closed — which is why a question must not be written as a reply |
| `case-12` (`short-pointer-payload`) | the dispatched body is a **4-line pointer** at a payload-file segment (§1.2): the hub stores it **within the 300-character budget**, line 1 within 80, with **no absolute path**; `scripts/anet_payload.sh verify` accepts the sha12 it names, **refuses a wrong sha12**, and `compose` **refuses an over-long summary**; the short body then round-trips byte-exactly through `acked → running → replied` |
| `case-13` (`whole-file-pointer`) | **one task = one file** (§1.2): composed with no `--seg`, the pointer names **the task's own file** and carries **no `seg:` field**; its `sha12` equals an **independently computed `sha256(file)[:12]`**, `verify` accepts it and **refuses a wrong one** (exit 3, naming the mismatch), the file carries **no other task's text** (zero segment anchors), and the pointer round-trips `acked → running → replied` |
`case-3` is the holdout (`split: "test"`): it is never fed to an optimization loop.

## Running them

```bash
python3 scripts/run_evals.py            # run every command criterion
python3 scripts/run_evals.py --validate # check the spec shape only
bash tests/manual_node_e2e.sh           # the same scenarios, narrated end to end
```

The scenarios need the commhub-server source tree to boot a throwaway hub from. Point
`ANET_E2E_HUB_SRC` at it (the `server/` directory, or the repo root that contains it). When this skill
sits where it ships — `<repo>/.agents/skills/agent-network-skill` — the tree is found relative to the
skill directory, so **golden inputs carry no paths** and the suite runs on any clone on any machine.

## Criteria

Each criterion is a shell command that must exit 0. They are written to hold for
every scenario, and the scenario-specific facts live in the scenario's own
`checks` map (each one verified against the hub, never against the script's
say-so):

- **the scenario ran cleanly** — no error, and the hub was really contacted
- **the scenario's own checks hold** — the facts that scenario verified are true
- **the hub row is the source of truth** — the final status was read back from
  the hub task row and matches the last observed transition
- **the transitions follow the protocol** — the observed sequence is a path the **hub
  actually permits** (`delivered → delivered/acked → …/running → …/replied`, and also
  the shortcuts `delivered → replied` / `delivered → acked → replied`, which
  `report_completion` allows because it matches `status IN
  ('delivered','acked','running')`), never a jump the hub would reject. Whether a
  scenario *should* have taken the long way is asserted by that scenario's own
  checks, not by this one.
- **no parallel work** — the scenario never had two tasks running on one node
- **`guard` refuses absolute paths by shape** — a body carrying `/etc/x`, `~/x`, `C:\x` or
  `\\host\share` is refused, on any machine, with no mount prefix listed anywhere in the script
  *(the matching locale-independence criterion was tried here and removed: it measured a python
  decode default, not the script's counting, and failed under the verification runner — see
  `wiki/patterns/portable-protocol-content.md`)*
  at once (a node has a single slot; the second task must wait)

```json
{
  "skill": "agent-network-skill",
  "run": "bash tests/manual_node_scenario.sh --input {input} --output {output}",
  "criteria": [
    {"id": "scenario-ran-cleanly", "text": "The scenario ran to completion against a real hub without error", "type": "command", "cmd": "python3 -c \"import json,sys;d=json.load(open('{output}'));sys.exit(0 if d['ok'] and not d['error'] else 1)\""},
    {"id": "scenario-checks-hold", "text": "Every fact the scenario verified against the hub holds", "type": "command", "cmd": "python3 -c \"import json,sys;d=json.load(open('{output}'));c=d['checks'];sys.exit(0 if all(v for v in c.values() if v) and any(c.values()) else 1)\""},
    {"id": "hub-row-is-the-source-of-truth", "text": "The final status was read back from the hub task row and matches the last observed transition", "type": "command", "cmd": "python3 -c \"import json,sys;d=json.load(open('{output}'));s=[t.split(':',1)[1] for t in d['transitions'] if t.startswith('status:')];sys.exit(0 if s and d['final_status']==s[-1] else 1)\""},
    {"id": "transitions-follow-the-protocol", "text": "The observed status sequence is a legal path through the task lifecycle", "type": "command", "cmd": "python3 -c \"import json,sys;d=json.load(open('{output}'));s=[t.split(':',1)[1] for t in d['transitions'] if t.startswith('status:')];legal=[['delivered'],['delivered','acked'],['delivered','acked','running'],['delivered','acked','running','replied'],['delivered','replied'],['delivered','acked','replied']];sys.exit(0 if s in legal else 1)\""},
    {"id": "no-parallel-work", "text": "The scenario never had two tasks running on one node at the same time", "type": "command", "cmd": "python3 -c \"import json,sys;d=json.load(open('{output}'));s=[t.split(':',1)[1] for t in d['transitions'] if t.startswith('status:')];sys.exit(0 if s.count('running')<=1 else 1)\""},
    {"id": "guard-refuses-absolute-path", "text": "scripts/anet_payload.sh guard refuses a body carrying a path a second machine cannot open (POSIX and Windows shapes)", "type": "command", "cmd": "bash scripts/anet_payload.sh guard --body \"读 /etc/passwd 与 C:\\\\proj\\\\x.md\" >/dev/null 2>&1; test $? -ne 0"},
    {"id": "guard-enforces-the-delivery-budget", "text": "scripts/anet_payload.sh guard --kind result accepts a 1200-character delivered result and refuses 1201 (the comparison is arithmetic inside one program, not a locale effect)", "type": "command", "cmd": "python3 -c \"import subprocess;unit='- evidence line with some text to fill the budget out\\n';body='verdict: 3 tests green\\n\\n'+unit*25;a=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',body[:1200],'--kind','result'],capture_output=True);b=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',(body+'x')[:1201],'--kind','result'],capture_output=True);raise SystemExit(0 if (a.returncode==0 and b.returncode!=0) else 1)\""},
    {"id": "guard-refuses-markup-the-plain-surfaces-cannot-render", "text": "scripts/anet_payload.sh guard --kind result refuses a delivery text carrying a table row, a # heading, bold markers or backticks (the Dashboard renders the node card, node list rows, the Tasks detail and Messages as plain text) and accepts the same text written with bullets and key: value fields", "type": "command", "cmd": "python3 -c \"import subprocess;clean='verdict: 3 tests green\\n\\n- unit: empty file returns an empty row set\\n- unit: duplicate header is refused with the row number\\nreport: docs/tests/report-export-tests.txt\\ncommit: abc1234';markup=clean+'\\n## Summary\\n| case | result |\\n|---|---|\\n**all green** in '+chr(96)+'report.txt'+chr(96);a=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',clean,'--kind','result'],capture_output=True);b=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',markup,'--kind','result'],capture_output=True);raise SystemExit(0 if (a.returncode==0 and b.returncode!=0) else 1)\""},
    {"id": "guard-requires-a-requirement-line-in-a-resend-body", "text": "scripts/anet_payload.sh guard --kind resend accepts a timeout-resend body that quotes the expired task id together with an accept: requirement line (budget 340, because quoting a hub task id costs 36 characters) and refuses the same body with the requirement line removed", "type": "command", "cmd": "python3 -c \"import subprocess;resend='resend seg-01: task 8f2f5a85-b120-4b5e-a558-f8bd76a4931f expired, work it again\\nfile: commhub_tasks/r07/export-tests.md  sha12: 756d1c7db68e\\nbranch main (git pull first); accept: every item on the acceptance list in the file\\nreport_completion once, result <= 1200 chars';stripped=resend.replace('accept: every item on the acceptance list in the file','work it in your own working directory');a=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',resend,'--kind','resend'],capture_output=True);b=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',stripped,'--kind','resend'],capture_output=True);raise SystemExit(0 if (a.returncode==0 and b.returncode!=0) else 1)\""},
    {"id": "guard-enforces-the-brief-body-budget", "text": "scripts/anet_payload.sh guard --kind brief accepts a 1200-character brief body and refuses 1201, with the line-count cap lifted (a brief body is formatted in blocks, not in six lines)", "type": "command", "cmd": "python3 -c \"import subprocess;clean='demo: report this node branch and commit, read-only\\n\\nsteps:\\n- git rev-parse --abbrev-ref HEAD\\n- git rev-parse --short HEAD\\n\\naccept:\\n- the result names the branch and the commit sha\\n- the result lists each command you ran\\n\\nreport_completion once, result <= 1200 chars';unit='\\n- evidence bullet line with text to fill the budget out to a realistic length';big=clean+unit*24;a=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',big[:1200],'--kind','brief'],capture_output=True);b=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',(big+'x')[:1201],'--kind','brief'],capture_output=True);raise SystemExit(0 if (a.returncode==0 and b.returncode!=0) else 1)\""},
    {"id": "guard-requires-the-accept-block-in-a-brief-body", "text": "scripts/anet_payload.sh guard --kind brief accepts a brief body whose accept: block names what counts as done and refuses the same body with the accept block removed", "type": "command", "cmd": "python3 -c \"import subprocess;clean='demo: report this node branch and commit, read-only\\n\\nsteps:\\n- git rev-parse --abbrev-ref HEAD\\n- git rev-parse --short HEAD\\n\\naccept:\\n- the result names the branch and the commit sha\\n- the result lists each command you ran\\n\\nreport_completion once, result <= 1200 chars';noacc=clean.replace('accept:\\n- the result names the branch and the commit sha\\n- the result lists each command you ran\\n\\n','');a=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',clean,'--kind','brief'],capture_output=True);b=subprocess.run(['bash','scripts/anet_payload.sh','guard','--body',noacc,'--kind','brief'],capture_output=True);raise SystemExit(0 if (a.returncode==0 and b.returncode!=0) else 1)\""}
  ],
  "golden": [
    {"id": "case-1", "input": "golden/case-1/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-2", "input": "golden/case-2/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-3", "input": "golden/case-3/input.json", "expected": null, "split": "test", "expected_status": "pending-first-green"},
    {"id": "case-4", "input": "golden/case-4/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-5", "input": "golden/case-5/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-6", "input": "golden/case-6/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-7", "input": "golden/case-7/input.json", "expected": "golden/case-7/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-8", "input": "golden/case-8/input.json", "expected": "golden/case-8/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-9", "input": "golden/case-9/input.json", "expected": "golden/case-9/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-10", "input": "golden/case-10/input.json", "expected": "golden/case-10/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-11", "input": "golden/case-11/input.json", "expected": "golden/case-11/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-12", "input": "golden/case-12/input.json", "expected": "golden/case-12/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-13", "input": "golden/case-13/input.json", "expected": "golden/case-13/expected.json", "split": "val", "expected_status": "pending-first-green"}
  ]
}
```
