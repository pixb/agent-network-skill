# A body that quotes a task id is a reschedule, and a reschedule must be acceptable

Status: draft — not executable guidance.

## Finding

Measured 2026-11-09: a timeout resend was dispatched as 'resend seg-01: task <uuid> expired, work it again' with no acceptance line, and acceptance had to be argued in prose. The mechanical trigger is the task id itself: hub ids are uuid4, which no file path, sha12, branch name or URL produces, so 'quotes a task id' is decidable from the body text alone. Such a body is what acceptance quotes against, so a requirement line is mandatory, and its budget is 340 rather than 300 because quoting a hub task id costs 36 characters (the measured resend body is 308). Scripts enforce it: guard --kind resend accepts the body with accept: and refuses the same body with the line removed.

## Evidence

- `raw/2026-11-08T181552Z-3956d39161e3.log`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
