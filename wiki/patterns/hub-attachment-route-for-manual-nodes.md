# A manual node has no runtime, so the hub attachment route needs two hand commands

Status: draft — not executable guidance.
Applied: accepted — shipped in v0.6.2. (The draft marker is the wiki lifecycle state, not a claim that the rule is unverified.)

## Finding

Measured: a runtime node auto-fetches attachments (agent-node/src/runtime/fetch-attachment.ts), and the hub enforces type=file + server-generated file_id, 20 per task, 12 MiB per file, 60 uploads/hour per caller, network-scoped download rights answered with 404 (never 403). The manual-node script had no attachment surface at all (grep attachment|file_id|/api/files = 0 hits), so a human worker on a task carrying a spec file had no in-protocol way to see it, let alone prove its revision. v0.6.2 adds files <task_id> and fetch <file_id> --out --sha12, the sha12 check runs BEFORE the write so a refused revision leaves no file, and the e2e drives the whole route on a throwaway hub.

## Evidence

- `raw/2026-11-08T021405Z-03f98b5e7219.log` — the narrated run whose last line is `ALL E2E ASSERTIONS PASSED`; its attachment block uploads a file, dispatches a task carrying it, asserts `bad_attachments` for a malformed entry, runs `files`, fetches the bytes (117B) with a matching sha12, refuses a wrong sha12 with exit 3 and leaves no file, and reports an unknown id as 404.
- `raw/2026-11-08T021404Z-bca66563c29c.json` — the 12-scenario pipeline report (60 checks, 0 failed) run in the same session

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
