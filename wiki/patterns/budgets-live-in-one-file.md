# A budget that lives in prose is a budget that drifts

Status: draft — not executable guidance.

## Finding

The budgets were typed where they were used: SKILL.md, guard, compose, the E2E and a golden baseline each carried their own copy, so a budget change touched five places and the missed ones surfaced as a scenario failure whose message was a number (compose accepted an 81-character summary line). scripts/budgets.json is now the single owner: anet_payload.sh reads every default from it (task 800 / no line cap, brief 1600, result 2400, resend 400, message 3000, context 400, line 1 100, layout line 120), the scenario runners compute their boundary probes from it (line1_max + 1 characters), and the criterion budgets-in-docs-match-the-script refuses a drift between the file, the script's budget lookups and the numbers SKILL.md quotes. Two rules stopped being optional in the same round: markup is refused by default (opt out with --allow-markup) and every body must carry an accept: line. A baseline pins identity, not quantity: case-13 keeps the sha12 and normalizes the character counts. The CJK character coefficient was NOT adopted — the hub counts characters, so Chinese is not cheaper; guard reports cjk share and est_tokens as a self-assessment instead.

## Evidence

- `raw/2026-11-09T051712Z-24dd8fdada22.log`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
