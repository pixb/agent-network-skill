# Skill impact ledger

Candidate changes are recorded here after validation. A rejected change is knowledge, not an active skill update.

## 2026-11-07T19:27:35Z — accepted

- Proposal: `call-discipline-v060`
- Target: `SKILL.md`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/commhub-call-discipline.md`

## 2026-11-07T19:49:59Z — accepted

- Proposal: `manager-identity-v060`
- Target: `SKILL.md`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/manager-node-identity.md`

## 2026-11-07T20:19:02Z — accepted

- Proposal: `generalize-parameter-discipline-v061`
- Target: `SKILL.md`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/portable-protocol-content.md`
## 2026-11-07T20:25:00Z — amendment to the two 2026-11-07 entries

The scores recorded for `call-discipline-v060` and `manager-identity-v060` (both `1.0000`) came from
`--validation-score`, a number the operator passes: the tool never computes it. Their cited evidence
(`raw/2026-11-07T192707Z-66718fafa7e2.json`) contains a single step, "validate the eval spec". Those
two entries therefore recorded "the spec is well-formed", not held-out behaviour. Behaviour for the
same rules is now recorded separately: 12 golden scenarios against throwaway hubs, 60 checks passed /
0 failed / 0 regressed, the holdout case included — see
`wiki/patterns/commhub-call-discipline.md` and `wiki/patterns/portable-protocol-content.md`.

Lesson for this ledger: a `--validation-score` is a claim, the `raw/` capture is the evidence, and an
entry must not cite evidence that does not contain the run it describes.

## 2026-11-08T02:14:14Z — accepted

- Proposal: `manual-node-attachment-route-v062`
- Target: `scripts/anet_manual_node.sh`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/hub-attachment-route-for-manual-nodes.md`

## 2026-11-08T02:45:56Z — accepted

- Proposal: `dispatcher-upload-command-v063`
- Target: `scripts/anet_payload.sh`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/hub-attachment-route-for-manual-nodes.md`

## 2026-11-08T02:45:56Z — accepted

- Proposal: `portability-proof-from-foreign-worktree`
- Target: `tests/manual_node_e2e.sh`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/portable-protocol-content.md`

## 2026-11-08T02:50:49Z — accepted

- Proposal: `drop-locale-criterion`
- Target: `evals/agent-network-skill.eval.md`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/portable-protocol-content.md`

## 2026-11-08T17:17:26Z — accepted

- Proposal: `one-task-one-file-v067`
- Target: `scripts/anet_payload.sh`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/one-task-one-payload-file.md`

## 2026-11-08T17:54:46Z — accepted

- Proposal: `budget-and-format-v068`
- Target: `scripts/anet_payload.sh`
- Held-out validation score: `1.0000`
- Pattern: `wiki/patterns/hub-budget-versus-protocol-budget.md`
