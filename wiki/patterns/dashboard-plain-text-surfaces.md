# Four Dashboard surfaces render plain text; only the task pane renders markdown

Status: draft — not executable guidance.

## Finding

Measured on the dashboard source: the node card (line-clamp-2), node list rows (truncate), the Tasks detail (whitespace-pre-wrap) and the Messages pages (whitespace-pre-wrap) all display task content and result as plain text, while TaskChatPanel renders them through react-markdown + remark-gfm. So markdown markup costs more than it buys: a table renders in one surface and appears as raw pipe characters in four. The protocol's delivery format is the subset that reads well everywhere - self-sufficient line 1, blank-line blocks, '- ' bullets, key: value fields - and guard --kind result refuses tables, # headings, bold markers and backticks.

## Evidence

- `raw/2026-11-08T175434Z-404fb64fbd9b.log`

## Proposed next experiment

Define one atomic candidate change and validate it on held-out cases.
