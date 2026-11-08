# A protocol skill must not embed one machine's paths or one project's domain

Status: draft — not executable guidance.
Applied: accepted — shipped in v0.6.1. (The draft marker is the wiki lifecycle state, not a claim that the rule is unverified.)


## Finding

Measured on v0.6.0: all 12 golden inputs pinned hub_source=/vol1/.../server, tests/manual_node_e2e.sh booted the hub from that same absolute path, the payload example text came from one content project's illustration round, and the absolute-path guard enumerated /vol1/ as if it were the rule. Consequence: the skill's gates pass only on the machine those paths describe, and the protocol's canonical examples teach one project's vocabulary. Fix that v0.6.1 applies: resolve the hub source from ANET_E2E_HUB_SRC or relative to the skill directory and put no path in a golden input; keep examples domain-neutral; define an absolute path by shape (leading /, ~/, X:\, \host\) so no mount prefix is encoded.

## Evidence

- `raw/2026-11-07T201812Z-bca66563c29c.json` — the pipeline report (spec validation + all 12 golden scenarios, exit 0)
- `raw/2026-11-07T201902Z-f26e338e0150.log` — that run narrated, ending `rollout: 60 passed, 0 failed, 0 errored, 0 regressed` / `RESULT: PASS`, with the holdout case (`case-3`, `split: "test"`) included

## Executed next experiment (measured 2026-11-08)

The suite was run from `git worktree add /tmp/anet-portable/anet pixb` — a tree at a path no
golden input, test or scenario names — with `ANET_E2E_HUB_SRC` removed from the environment
(`env -u ANET_E2E_HUB_SRC`). Result: `run_pipeline.py` → `RESULT: PASS`, 60 checks, 0 failed;
`tests/manual_node_e2e.sh` → `ALL E2E ASSERTIONS PASSED`, including the attachment block. The
hub source was resolved from the skill directory (`<repo>/.agents/skills/agent-network-skill`
→ `../../../server`), so the resolution rule is proven, not asserted. Only the dependency step
is host-specific: `server/node_modules` was symlinked from the main checkout, which is a runtime
prerequisite, not a path baked into the skill.

## Evidence

- `raw/2026-11-08T024525Z-95b0b4febf6b.log` — pipeline run from the foreign worktree, no hub-source env
- `raw/2026-11-08T024525Z-2afae00d5256.log` — manual-node E2E from the same foreign worktree, ending `ALL E2E ASSERTIONS PASSED`

## The criterion that failed, and why it belongs in the script

`guard-counts-characters-not-bytes` was added as a command criterion to lock v0.6.1's
"count characters, not bytes" fix. It ran green under `scripts/run_pipeline.py` (84 checks, 0
failed) and red under the verification runner's rollout (11 checks, 11 failed), so the gate
contradicted itself. Cause: the criterion compared a **python decode default** — the CJK body was
re-decoded by a `python3 -c` pipe whose text encoding depends on the ambient locale, and the
verification runner runs with a stripped environment. It measured the host, not the script.

It was removed (v0.6.3). The honest way to gate this rule is for `guard` to report the facts
itself — `--json` carrying the byte length next to the character length — so the criterion is an
arithmetic comparison inside one program, with no locale-dependent pipe in it. That is the next
change; a gate that measures the runner's environment is worse than no gate, because it fails
loudly for a reason the protocol does not control.
