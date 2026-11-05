#!/usr/bin/env python3
"""Check the order and the rights of the release workflow's jobs.

    check-release-workflow.py RELEASE_YML BUILD_IMAGE_YML

One line per broken rule, exit status 1 if there is any:

- sign is the one job with an OIDC token, and build-image.yml asks for none:
  every certificate of a release names release.yml
- sign waits for both images and the chart, tag for sign, release for sign
  and tag, try-locally for tag, and nothing waits for try-locally
- every job sits downstream of the gate
- release is the one job that can write to the repository
- nothing but the tag job sets a tag: the builds push by digest
- no build argument carries a secret: provenance records build arguments
"""

import sys, yaml
release = yaml.safe_load(open(sys.argv[1]))["jobs"]
build_text = open(sys.argv[2]).read()
build = yaml.safe_load(build_text)["jobs"]
problems = []
def needs(job):
    n = release[job].get("needs", [])
    return {n} if isinstance(n, str) else set(n)
def upstream(job, seen=None):
    seen = seen if seen is not None else set()
    for n in needs(job):
        if n not in seen:
            seen.add(n)
            upstream(n, seen)
    return seen
oidc = [name for name, job in release.items() if (job.get("permissions") or {}).get("id-token") == "write"]
if oidc != ["sign"]:
    problems.append(f"the jobs with an OIDC token are {oidc}, not sign alone")
for job in build.values():
    if (job.get("permissions") or {}).get("id-token"):
        problems.append("build-image.yml asks for an OIDC token; its certificates would name another workflow")
for job in ("wordpress", "idx", "chart"):
    if job not in needs("sign"):
        problems.append(f"sign does not wait for {job}")
if "sign" not in needs("tag"):
    problems.append("tag does not wait for sign")
if not {"sign", "tag"} <= needs("release"):
    problems.append("release does not wait for sign and tag")
if "tag" not in needs("try-locally"):
    problems.append("try-locally does not wait for tag")
for name in release:
    if name not in ("gate",) and "gate" not in upstream(name):
        problems.append(f"{name} does not sit downstream of the gate")
    if "try-locally" in needs(name):
        problems.append(f"{name} waits for try-locally")
writers = [name for name, job in release.items() if (job.get("permissions") or {}).get("contents") == "write"]
if writers != ["release"]:
    problems.append(f"the jobs that can write to the repository are {writers}, not release alone")
# Nothing but the tag job sets a tag: the builds push by digest, the chart
# goes through the runner's registry, and oras tag and oras push with a tag
# stand in that job or in the scripts it runs.
if "push-by-digest=true" not in build_text or "oras manifest push" not in build_text:
    problems.append("build-image.yml does not push by digest")
for name, job in list(release.items()) + list(build.items()):
    for step in job.get("steps") or []:
        run = str(step.get("run", ""))
        if name != "tag" and ("oras tag" in run or "release-tag-" in run or ":artifacthub.io" in run):
            problems.append(f"job {name} sets a tag outside the tag job")
        if "secrets." in str((step.get("with") or {}).get("build-args", "")):
            problems.append(f"job {name} passes a secret as a build argument; provenance records build arguments")
for job in ("wordpress", "idx"):
    if "secrets." in str((release[job].get("with") or {}).get("build-args", "")):
        problems.append(f"job {job} passes a secret as a build argument; provenance records build arguments")
if "sbom: true" not in build_text or "provenance: mode=max" not in build_text:
    problems.append("build-image.yml does not ask for an SBOM and provenance")
print("\n".join(problems))
sys.exit(1 if problems else 0)
