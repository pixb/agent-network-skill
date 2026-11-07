# A protocol skill must not embed one machine's paths or one project's domain

Status: draft — not executable guidance.
Applied: accepted — shipped in v0.6.1. (The draft marker is the wiki lifecycle state, not a claim that the rule is unverified.)


## Finding

Measured on v0.6.0: all 12 golden inputs pinned hub_source=/vol1/.../server, tests/manual_node_e2e.sh booted the hub from that same absolute path, the payload example text came from one content project's illustration round, and the absolute-path guard enumerated /vol1/ as if it were the rule. Consequence: the skill's gates pass only on the machine those paths describe, and the protocol's canonical examples teach one project's vocabulary. Fix that v0.6.1 applies: resolve the hub source from ANET_E2E_HUB_SRC or relative to the skill directory and put no path in a golden input; keep examples domain-neutral; define an absolute path by shape (leading /, ~/, X:\, \host\) so no mount prefix is encoded.

## Evidence

- `raw/2026-11-07T201812Z-bca66563c29c.json` — the pipeline report (spec validation + all 12 golden scenarios, exit 0)
- `raw/2026-11-07T201902Z-f26e338e0150.log` — that run narrated, ending `rollout: 60 passed, 0 failed, 0 errored, 0 regressed` / `RESULT: PASS`, with the holdout case (`case-3`, `split: "test"`) included

## Proposed next experiment

Run the suite from a clone whose source tree is **not** at the path this machine uses, on a machine
with no `ANET_E2E_HUB_SRC` set, and confirm the scenarios still resolve the hub source — that is the
part a single machine cannot prove by itself.
