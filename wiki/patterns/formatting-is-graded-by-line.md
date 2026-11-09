# A dispatch body is a summary: plain line 1, markdown below it

Status: draft — not executable guidance.

## Finding

Ban-the-markup was the wrong instrument. Measured: only the task pane renders markdown (TaskChatPanel.tsx:492-493, :561, :1725, :1769); the node card clamps at 2 lines, node list rows truncate, the Tasks detail and Messages are plain whitespace-pre-wrap, and sessions.task hands the previews a blind 200-character slice. That means the previews show line 1 and nothing else — so the rule that follows from the surfaces is graded, not global: line 1 plain and self-sufficient, lines 2+ free to use headings/bold/bullets/numbering/quotes/inline code, tables refused at every line because a table shatters worst on the plain pages. task_lines_max went to 0 for the same reason: with the detail in the payload file, the parameter is a summary, and a summary is allowed to be several blocks. E2E (raw evidence) proves a 15-line markdown body round-trips acked->running->replied, markup on line 1 is refused, a table row is refused, and a 26-line body is accepted (no cap).

## Evidence

- `raw/2026-11-09T065129Z-0f3b6c52ad9b.log`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
