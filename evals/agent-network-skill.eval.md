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

`case-3` is the holdout (`split: "test"`): it is never fed to an optimization loop.

## Running them

```bash
python3 scripts/run_evals.py            # run every command criterion
python3 scripts/run_evals.py --validate # check the spec shape only
bash tests/manual_node_e2e.sh           # the same scenarios, narrated end to end
```

The scenarios need the commhub-server source tree to boot a throwaway hub from.
Point `ANET_E2E_HUB_SRC` at it, or put the path in each scenario file's
`hub_source` field.

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
    {"id": "no-parallel-work", "text": "The scenario never had two tasks running on one node at the same time", "type": "command", "cmd": "python3 -c \"import json,sys;d=json.load(open('{output}'));s=[t.split(':',1)[1] for t in d['transitions'] if t.startswith('status:')];sys.exit(0 if s.count('running')<=1 else 1)\""}
  ],
  "golden": [
    {"id": "case-1", "input": "golden/case-1/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-2", "input": "golden/case-2/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-3", "input": "golden/case-3/input.json", "expected": null, "split": "test", "expected_status": "pending-first-green"},
    {"id": "case-4", "input": "golden/case-4/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-5", "input": "golden/case-5/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-6", "input": "golden/case-6/input.json", "expected": null, "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-7", "input": "golden/case-7/input.json", "expected": "golden/case-7/expected.json", "split": "val", "expected_status": "pending-first-green"},
    {"id": "case-8", "input": "golden/case-8/input.json", "expected": "golden/case-8/expected.json", "split": "val", "expected_status": "pending-first-green"}
  ]
}
```
