"""Checks of the file-integrity watcher over a rendered manifest stream on stdin.

  * The wp-config.php digest the chart pins in the watcher configuration
    matches the bytes the init container writes. The init script is read
    from the rendered Deployment and its quoted heredoc is replayed exactly
    as the shell runs it, so a template edit that changes the file without
    going through wordpress.wpConfigPhp - or the other way round - fails
    here instead of firing baseline-modified on every site after the upgrade.
  * No Service that selects the WordPress pod also selects the watcher pod:
    a watcher carrying the WordPress selector labels would receive web
    traffic.
  * In sidecar mode the watcher has no readiness probe, so a watcher that is
    not ready can never take WordPress out of its Service.

  check-fim.py <label> <deployment|sidecar>
"""

import hashlib
import json
import re
import sys

import yaml

HEREDOC = re.compile(r"cat <<'EOF' >>? /wordpress/wp-config\.php$")


def written_wp_config(script):
    lines = script.split("\n")
    out, i = [], 0
    while i < len(lines):
        if HEREDOC.match(lines[i]):
            i += 1
            while lines[i] != "EOF":
                out.append(lines[i] + "\n")
                i += 1
        i += 1
    return "".join(out)


def selects(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


def main():
    label, mode = sys.argv[1], sys.argv[2]
    docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
    problems = []

    config = None
    for d in docs:
        if d["kind"] == "ConfigMap" and "config.json" in (d.get("data") or {}):
            config = json.loads(d["data"]["config.json"])
    if config is None:
        print(f"FAIL: {label}\n      no watcher configuration rendered")
        return 1

    pods = {}
    wordpress = None
    for d in docs:
        if d["kind"] != "Deployment":
            continue
        tpl = d["spec"]["template"]
        pods[d["metadata"]["name"]] = tpl["metadata"].get("labels") or {}
        init = [c for c in tpl["spec"].get("initContainers") or [] if c["name"] == "prepare-base-dir"]
        if init:
            wordpress = d
            written = written_wp_config(init[0]["args"][-1])
            want = hashlib.sha256(written.encode()).hexdigest()
            have = config["baseline"].get("wp-config.php")
            if not written:
                problems.append("no wp-config.php heredoc found in the init script")
            elif have != [want]:
                problems.append(f"pinned wp-config.php digest {have} != written {want}")

    if wordpress is None:
        problems.append("no WordPress Deployment rendered")
    else:
        wp_name = wordpress["metadata"]["name"]
        containers = wordpress["spec"]["template"]["spec"]["containers"]
        fim = [c for c in containers if c["name"] == "fim"]
        if mode == "sidecar":
            if not fim:
                problems.append("sidecar mode renders no fim container in the WordPress pod")
            elif "readinessProbe" in fim[0]:
                problems.append("the fim sidecar has a readiness probe")
        elif fim:
            problems.append("deployment mode also renders a fim sidecar")

        for d in docs:
            if d["kind"] != "Service":
                continue
            sel = d["spec"].get("selector") or {}
            if not selects(sel, pods[wp_name]):
                continue
            for name, labels in pods.items():
                if name != wp_name and selects(sel, labels):
                    problems.append(
                        f"Service/{d['metadata']['name']} selects the WordPress pod and also Deployment/{name}"
                    )

    if problems:
        print(f"FAIL: {label}")
        for p in problems:
            print(f"      {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
