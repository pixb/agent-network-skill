# A payload file is the worker's read cost: one task per file

Status: draft — not executable guidance.

## Finding

Measured on v0.6.7 with a 300-character parameter budget: a worker reads the payload file the pointer names, and a body of <=300 characters cannot tell it where to stop reading. A file holding six tasks therefore costs six tasks of tokens on every run, five of them other tasks' text. Making the file the unit of one task makes the read cost equal to the task, and removes the fingerprint ambiguity: the pointer names a file, the sha12 is the file's. Segment pointers stay supported (a task that is one section of a document you must not split), and there the sha12 is the segment's, not the file's - a node that reports a whole-file hash against a segment pointer is using the wrong measure.

## Evidence

- `raw/2026-11-08T172122Z-cc1976648995.log` — the 13-scenario pipeline (78 checks, 0 failed) including
  the new `case-13` (`whole-file-pointer`): pointer names the task's own file, has no `seg:` field, its
  sha12 equals an independently computed `sha256(file)[:12]`, `verify` accepts it and refuses a wrong one
  with exit 3, the file carries zero segment anchors, and the body round-trips `acked → running → replied`
- `raw/2026-11-08T172122Z-ee608bb69fd4.log` — the manual-node E2E, `ALL E2E ASSERTIONS PASSED`, whose
  per-task block prints `whole-file pointer (no seg:), sha12 47b44ac24710 matches an independent sha256`
  and `0 segment anchors`

## Proposed next experiment

Measure the token difference on a real pair: dispatch N tasks as one multi-segment file and as N
per-task files, and count the characters each worker actually reads. The rule is stated from the
mechanism (a pointer cannot bound a read), not from a measured ratio — that ratio is the missing number.
