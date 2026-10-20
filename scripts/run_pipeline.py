#!/usr/bin/env python3
"""Run this skill's whole verification chain in one command.

The skill is a protocol plus a script, so its correctness is behavioural: the
checks here boot throwaway hubs and drive real tasks through the real manual-node
script. This orchestrator runs those steps in order and wires their output into
the next step, so nobody has to sequence them by hand:

    1. validate   — the eval spec is well-formed (scripts/run_evals.py --validate)
    2. scenarios  — each golden case runs against a throwaway hub
    3. report     — the results are written as JSON, and a non-zero exit means
                    at least one scenario failed

Usage:
    python3 scripts/run_pipeline.py                 # run everything
    python3 scripts/run_pipeline.py --case case-1   # one case
    python3 scripts/run_pipeline.py --output out.json
    python3 scripts/run_pipeline.py --skip-scenarios # only check the spec shape
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
EVAL_RUNNER = SKILL_DIR / "scripts" / "run_evals.py"
SCENARIO = SKILL_DIR / "tests" / "manual_node_scenario.sh"
DEFAULT_OUTPUT = SKILL_DIR / "evals" / "pipeline-report.json"


def run(cmd: list[str], label: str) -> dict:
    """Run one step and capture its outcome."""
    print(f"== {label}", flush=True)
    proc = subprocess.run(cmd, cwd=SKILL_DIR, capture_output=True, text=True, check=False)
    for line in (proc.stdout or "").splitlines():
        print("   " + line, flush=True)
    if proc.returncode != 0 and proc.stderr:
        for line in proc.stderr.splitlines()[-10:]:
            print("   ! " + line, flush=True)
    return {"step": label, "exit_code": proc.returncode, "ok": proc.returncode == 0}


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the agent-network-skill verification chain.")
    parser.add_argument("--case", help="run only this golden case id")
    parser.add_argument("--output", help=f"where to write the JSON report (default {DEFAULT_OUTPUT})")
    parser.add_argument("--skip-scenarios", action="store_true", help="only validate the eval spec")
    args = parser.parse_args()

    if not EVAL_RUNNER.is_file():
        print(f"missing eval runner: {EVAL_RUNNER}", file=sys.stderr)
        return 2
    if not args.skip_scenarios and not SCENARIO.is_file():
        print(f"missing scenario runner: {SCENARIO}", file=sys.stderr)
        return 2

    steps: list[dict] = []
    steps.append(
        run([sys.executable, str(EVAL_RUNNER), "--validate"], "validate the eval spec")
    )

    if not args.skip_scenarios:
        cmd = [sys.executable, str(EVAL_RUNNER), "--rollout", "--include-holdout"]
        if args.case:
            cmd += ["--case", args.case]
        steps.append(run(cmd, "run the scenarios"))

    report = {
        "skill": "agent-network-skill",
        "ok": all(step["ok"] for step in steps),
        "steps": steps,
    }
    output = Path(args.output) if args.output else DEFAULT_OUTPUT
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"== report: {output}")
    print("RESULT: " + ("PASS" if report["ok"] else "FAIL"))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
