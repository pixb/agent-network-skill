# Long commhub parameters and batched calls stall the protocol

Status: draft — not executable guidance.

## Finding

Dispatched bodies that carry the whole spec break three hub facts at once: sessions.task keeps only the first 200 chars (blind cut), report_status(status=working) matches the body byte-for-byte (a long body drifts, the task rots in acked), and a batch of commhub calls in one turn overwrites the node's single session slot and leaves the operator unable to tell which transition landed. Fix: one commhub call per round, plus a 4-line pointer body (file + seg + sha12) with the long text in a payload-file segment.

## Evidence

- `raw/2026-11-07T192707Z-66718fafa7e2.json`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
