#!/usr/bin/env python3
"""Check the rules every workflow under .github/workflows/ follows.

    check-workflows.py [REPO_ROOT]

One line per broken rule, exit status 1 if there is any:

- an action is pinned by its commit SHA, with the version as a comment
- a job has a time limit, unless it calls a reusable workflow, whose jobs
  have their own
- a job runs on a pinned runner image, not on a `-latest` label
- the workflow's own permissions are none or read-only; a job that writes
  asks for it itself
- at most one job of the repository can get an OIDC token (id-token: write)
  besides the Pages deployment
- a run script contains no ${{ }} expression: a value reaches it through
  env, where the shell cannot read it as code
- a checkout leaves no token in .git/config, unless a later step of the job
  pushes with it (create-pull-request)
- a tool version in an env *_VERSION has a `# renovate:` line above it
"""

import pathlib
import re
import sys

import yaml

USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$")
PINNED = re.compile(r"^[\w.-]+/[\w.-]+(?:/[\w./-]+)?@[0-9a-f]{40}$")
VERSION_COMMENT = re.compile(r"^\s+# v\d+(\.\d+){0,2}\s*$")
RUNNER = re.compile(r"^ubuntu-\d+\.\d+(-arm)?$")
VERSION_PIN = re.compile(r"^\s*\w+_VERSION:\s*v?\d[\w.-]*\s*$")
RENOVATE_LINE = re.compile(r"^\s*# renovate: datasource=\S+ depName=\S+\s*$")
READ_ONLY = {"read", "none"}


def runners(job):
    """The runner labels a job can run on, with a matrix expression resolved."""
    runs_on = job.get("runs-on")
    if isinstance(runs_on, str) and runs_on.startswith("${{"):
        key = re.fullmatch(r"\$\{\{\s*matrix\.([\w-]+)\s*\}\}", runs_on)
        if not key:
            return [runs_on]
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        values = list(matrix.get(key.group(1), []))
        values += [row.get(key.group(1)) for row in matrix.get("include", []) if key.group(1) in row]
        return values or [runs_on]
    return runs_on if isinstance(runs_on, list) else [runs_on]


def check(path, problems, oidc_jobs):
    """Append the broken rules of one workflow file to problems."""
    text = path.read_text()
    lines = text.splitlines()
    name = path.name

    for number, line in enumerate(lines, 1):
        match = USES.match(line)
        if match and not match.group(1).startswith("./"):
            if not PINNED.match(match.group(1)):
                problems.append(f"{name}:{number}: {match.group(1)} is not pinned by a commit SHA")
            elif not VERSION_COMMENT.match(match.group(2)):
                problems.append(f"{name}:{number}: {match.group(1)} has no '# vX.Y.Z' comment")
        if VERSION_PIN.match(line):
            above = lines[number - 2] if number >= 2 else ""
            if not RENOVATE_LINE.match(above):
                problems.append(f"{name}:{number}: a *_VERSION pin without a '# renovate:' line above it")

    workflow = yaml.safe_load(text)
    top = workflow.get("permissions")
    if top is None:
        problems.append(f"{name}: no permissions at the top of the workflow")
    elif isinstance(top, str):
        if top not in ("read-all", "{}"):
            problems.append(f"{name}: the workflow's permissions are '{top}'")
    else:
        for scope, level in top.items():
            if level not in READ_ONLY:
                problems.append(f"{name}: {scope}: {level} for every job; a job that writes asks for it itself")

    for job_name, job in (workflow.get("jobs") or {}).items():
        where = f"{name}: job {job_name}"
        if "uses" in job:
            continue
        if "timeout-minutes" not in job:
            problems.append(f"{where} has no timeout-minutes")
        for runner in runners(job):
            if not isinstance(runner, str) or not RUNNER.match(runner):
                problems.append(f"{where} runs on '{runner}', not on a pinned runner image")
        permissions = job.get("permissions") or {}
        if isinstance(permissions, dict) and permissions.get("id-token") == "write" and "pages" not in permissions:
            oidc_jobs.append(where)
        steps = job.get("steps") or []
        pushes = any("create-pull-request" in str(step.get("uses", "")) for step in steps)
        for step in steps:
            label = step.get("name") or step.get("id") or step.get("uses") or "a step"
            if "${{" in str(step.get("run", "")):
                problems.append(f"{where}, {label}: a ${{{{ }}}} expression inside the run script; pass it through env")
            if str(step.get("uses", "")).startswith("actions/checkout@") and not pushes:
                if (step.get("with") or {}).get("persist-credentials") is not False:
                    problems.append(f"{where}: the checkout keeps its token (persist-credentials: false is missing)")


def main():
    """Check every workflow of the repository and report."""
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted((root / ".github" / "workflows").glob("*.y*ml"))
    if not files:
        print(f"no workflows under {root}/.github/workflows")
        return 1
    problems, oidc_jobs = [], []
    for path in files:
        check(path, problems, oidc_jobs)
    if len(oidc_jobs) > 1:
        problems.append("more than one job can get an OIDC token: " + "; ".join(oidc_jobs))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
