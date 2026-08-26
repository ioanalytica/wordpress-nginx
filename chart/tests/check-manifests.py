"""Structural checks over a rendered Helm manifest stream read from stdin.

Verifies that what the workload mounts actually exists and matches:
  * every ConfigMap referenced by a pod volume is present in the same render
  * every volumeMount refers to a volume declared on the same pod
  * every subPath into a ConfigMap volume exists as a key in that ConfigMap

These are the failures that `helm lint` accepts and Kubernetes does not: a
mount pointing at a resource the templates never create leaves the pod stuck
in ContainerCreating.

Documents are parsed with a duplicate-key-rejecting loader. PyYAML silently
keeps the last value for a duplicated mapping key, but the strict YAML
parser in Flux's post-renderer refuses the manifest - a template edit that
introduces a second `defaultMode:` renders fine, passes helm lint, and
breaks every HelmRelease upgrade (seen with chart 7.1.0-9).
"""

import os
import sys

import yaml

WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that fails on duplicate mapping keys instead of last-wins."""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=True)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None,
                    f"duplicate mapping key {key!r}", key_node.start_mark
                )
            seen.add(key)
        return super().construct_mapping(node, deep)


def pod_specs(doc):
    kind = doc.get("kind")
    if kind == "CronJob":
        yield doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    elif kind in WORKLOADS:
        yield doc["spec"]["template"]["spec"]


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "manifests"
    raw = sys.stdin.read()
    try:
        docs = [d for d in yaml.load_all(raw, Loader=StrictLoader) if d]
    except yaml.YAMLError as err:
        print(f"FAIL: {label}")
        print(f"      rendered manifests are not strict YAML: {err}")
        return 1

    problems = []
    configmaps = {}
    for doc in docs:
        if doc.get("kind") != "ConfigMap":
            continue
        name = doc.get("metadata", {}).get("name")
        if not name:
            problems.append("a rendered ConfigMap has no metadata.name")
            continue
        configmaps[name] = set((doc.get("data") or {}).keys())
    secrets = {
        d.get("metadata", {}).get("name")
        for d in docs
        if d.get("kind") == "Secret"
    }

    for doc in docs:
        name = doc.get("metadata", {}).get("name", "?")
        for spec in pod_specs(doc):
            volumes = {}
            for vol in spec.get("volumes") or []:
                volumes[vol["name"]] = vol
                ref = (vol.get("configMap") or {}).get("name")
                if ref is not None and ref not in configmaps:
                    problems.append(
                        f"{doc['kind']}/{name}: volume {vol['name']!r} mounts "
                        f"ConfigMap {ref!r}, which is never rendered"
                    )
                sref = (vol.get("secret") or {}).get("secretName")
                if sref is not None and sref not in secrets:
                    # Secrets may legitimately be pre-existing (existingSecret
                    # values), so this is not an error on its own.
                    pass

            containers = (spec.get("containers") or []) + (
                spec.get("initContainers") or []
            )
            for container in containers:
                for mount in container.get("volumeMounts") or []:
                    vol = volumes.get(mount["name"])
                    if vol is None:
                        problems.append(
                            f"{doc['kind']}/{name}: container "
                            f"{container['name']!r} mounts volume "
                            f"{mount['name']!r}, which is not declared"
                        )
                        continue
                    ref = (vol.get("configMap") or {}).get("name")
                    sub = mount.get("subPath")
                    if ref and sub and ref in configmaps:
                        if sub not in configmaps[ref]:
                            problems.append(
                                f"{doc['kind']}/{name}: container "
                                f"{container['name']!r} mounts subPath "
                                f"{sub!r} from ConfigMap {ref!r}, which has no "
                                f"such key ({sorted(configmaps[ref]) or 'no keys'})"
                            )

    # A sentinel value passed in as a secret must end up in a Secret and
    # nowhere else. ConfigMaps are readable by anyone who can read ConfigMaps
    # in the namespace, so a password templated into one is a disclosure even
    # though it never looks like a mistake in the diff.
    sentinel = os.environ.get("MANIFEST_SENTINEL")
    if sentinel:
        for doc in docs:
            if doc.get("kind") == "Secret":
                continue
            if sentinel in yaml.safe_dump(doc):
                problems.append(
                    f"{doc.get('kind')}/{doc.get('metadata', {}).get('name', '?')}: "
                    f"contains the secret value in plain text"
                )

    if problems:
        print(f"FAIL: {label}")
        for problem in problems:
            print(f"      {problem}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
