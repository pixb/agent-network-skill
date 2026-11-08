# A formatted body in the parameter is affordable; length costs the preview, not the lifecycle

Status: draft — not executable guidance.

## Finding

Measured on a live hub with a pi runtime node (2026-11-09): bodies of 117, 277 and 484 characters all went delivered -> running -> replied in about 20 seconds each. The working flip needs a byte-exact content match (UPDATE tasks SET status='running' WHERE to_name = ?1 AND status IN ('delivered','acked') AND content = ?2, server/src/tools.ts:1492-1493) and the node echoes the body it fetched from the hub, so length does not break it. What length costs is the 200-character preview the node card shows, and the worker's context on every round. So the protocol now allows a brief body of <=1200 characters with an accept: block and markdown-safe layout (guard --kind brief enforces it), and keeps the pointer body for specs that need a sha12 proof, review in git, or reuse across rounds.

## Evidence

- `raw/2026-11-08T183755Z-e838822eaed1.log`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
