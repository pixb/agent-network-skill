# The hub's ceilings are not the protocol's budgets

Status: draft — not executable guidance.

## Finding

Measured (v0.6.8): send_task accepts 10 000 characters of task text (TASK_CONTENT_MAX), report_completion stores the first 4000 of result (result.slice(0,4000)), send_reply accepts 10 000. None of those is the binding constraint. What binds is (a) report_status(status=working) matching the stored body byte-for-byte with no task_id branch, so every extra character in the dispatch body is a character the worker must reproduce exactly; (b) sessions.task keeping the first 200 characters, cut blindly; (c) the Dashboard's task pane collapsing the delivery at 300px (about 12 lines). The protocol therefore spends 300 on the dispatch body, 1200 on the delivery text and 1500 on messages, and states the hub numbers next to them so an operator can tell discipline from limitation.

## Evidence

- `raw/2026-11-08T175434Z-404fb64fbd9b.log`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
