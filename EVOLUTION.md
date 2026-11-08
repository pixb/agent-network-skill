# Evolution log

Appended automatically by scripts/run_evals.py (and scripts/evolve.py) when a check fails. Each entry is the raw evidence for a fix/regenerate step.

## 2026-10-20T07:06:13Z — run_evals --rollout FAILED

- counts: passed=5, failed=5, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "stuck-task-is-diagnosed",
    "status": "fail"
  },
  {
    "case": "case-1",
    "criterion": "terminal-task-refuses-second-reply",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "task-reaches-replied",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "transitions-observed",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "terminal-task-refuses-second-reply",
    "status": "fail"
  }
]
```

## 2026-10-20T07:07:03Z — run_evals --rollout FAILED

- counts: passed=0, failed=0, errors=2, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "<run>",
    "status": "error"
  },
  {
    "case": "case-2",
    "criterion": "<run>",
    "status": "error"
  }
]
```

## 2026-10-20T08:23:33Z — run_evals --rollout FAILED

- counts: passed=22, failed=2, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-6",
    "criterion": "hub-row-is-the-source-of-truth",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "transitions-follow-the-protocol",
    "status": "fail"
  }
]
```

## 2026-10-20T08:26:05Z — run_evals --rollout FAILED

- counts: passed=29, failed=1, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-6",
    "criterion": "transitions-follow-the-protocol",
    "status": "fail"
  }
]
```

## 2026-11-04T07:00:08Z — run_evals --rollout FAILED

- counts: passed=55, failed=0, errors=0, regressions=1, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-9",
    "criterion": "<baseline>",
    "status": "regression"
  }
]
```

## 2026-11-08T17:47:42Z — run_evals --rollout FAILED

- counts: passed=104, failed=0, errors=0, regressions=1, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-13",
    "criterion": "<baseline>",
    "status": "regression"
  }
]
```

## 2026-11-08T17:49:24Z — run_evals --rollout FAILED

- counts: passed=8, failed=0, errors=0, regressions=1, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-13",
    "criterion": "<baseline>",
    "status": "regression"
  }
]
```

## 2026-11-08T17:55:40Z — run_evals --rollout FAILED

- counts: passed=72, failed=24, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-1",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  }
]
```

## 2026-11-08T17:57:42Z — run_evals --rollout FAILED

- counts: passed=72, failed=24, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-1",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  }
]
```

## 2026-11-08T17:58:23Z — run_evals --rollout FAILED

- counts: passed=72, failed=24, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-1",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  }
]
```

## 2026-11-08T17:59:20Z — run_evals --rollout FAILED

- counts: passed=72, failed=24, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-1",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  }
]
```

## 2026-11-08T17:59:47Z — run_evals --rollout FAILED

- counts: passed=78, failed=26, errors=0, regressions=0, judge_failed=0
- failing checks (raw):

```json
[
  {
    "case": "case-1",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-1",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-2",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-3",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-3",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-4",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-5",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-6",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-7",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-8",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-9",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-10",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-11",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-12",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-enforces-the-delivery-budget",
    "status": "fail"
  },
  {
    "case": "case-13",
    "criterion": "guard-refuses-markup-the-plain-surfaces-cannot-render",
    "status": "fail"
  }
]
```

