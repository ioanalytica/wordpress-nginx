"""Checks that chart/values.schema.json keeps step with chart/values.yaml.

    check-schema.py CHART_DIR

Helm checks the values of every install, upgrade, template and lint against
the schema, and Artifact Hub shows it as the chart's values reference. Nothing
generates it, so nothing but this check notices a parameter added to
values.yaml and not to the schema, a schema entry whose value is gone, or a
default changed in one file only.

Prints one line per problem and exits 1 if there is any.
"""

import glob
import json
import re
import sys

import yaml

# Entries of these two lists are single rules with a fixed shape, and a
# misspelled key in one would silently turn into another rule (an `action`
# that falls back to deny, a plugin that is never activated). Their item
# schemas name the keys an entry may have and the one it must have. Nowhere
# else does the schema require a key or refuse one it does not list.
STRICT_ITEMS = {"nginx.deniedPaths", "wordpressPreinstallPlugins"}

# The only enums: modes of which the chart or the image knows a fixed set.
# A mode the schema does not list would be refused before the chart could
# say what it accepts, so a new mode has to be added in both places.
ENUMS = {
    "phpExecutionAllowlist.mode": ["enforce", "report", "off"],
    "restApiHardening.mode": ["off", "enforce", "report"],
    "nginx.htaccessPolicy": ["warn", "fail"],
    "nginx.deniedPaths[].action": ["deny", "honeypot"],
}


def types(node):
    t = node.get("type")
    return t if isinstance(t, list) else [t]


def walk(node, path=()):
    """Every property of the schema as (path, node), sections included."""
    for key, child in (node.get("properties") or {}).items():
        yield path + (key,), child
        yield from walk(child, path + (key,))


def lookup(mapping, path):
    """The value at path, or KeyError."""
    for key in path:
        if not isinstance(mapping, dict) or key not in mapping:
            raise KeyError(path)
        mapping = mapping[key]
    return mapping


def schema_node(schema, path):
    node = schema
    for key in path:
        node = (node.get("properties") or {}).get(key)
        if node is None:
            return None
    return node


def main():
    chart = sys.argv[1]
    text = open(f"{chart}/values.yaml").read()
    values = yaml.safe_load(text)
    schema = json.load(open(f"{chart}/values.schema.json"))
    templates = "".join(open(f).read() for f in sorted(glob.glob(f"{chart}/templates/*")))
    problems = []

    if schema.get("$schema") != "http://json-schema.org/draft-07/schema#":
        problems.append(f"$schema is {schema.get('$schema')!r}, expected draft-07")

    # Every documented parameter is in the schema.
    params = re.findall(r"^\s*## @param (\S+)", text, re.M)
    if len(params) < 300:
        problems.append(f"only {len(params)} @param lines found in values.yaml")
    for param in params:
        if schema_node(schema, param.split(".")) is None:
            problems.append(f"documented in values.yaml, not in the schema: {param}")

    props = list(walk(schema))
    for path, node in props:
        name = ".".join(path)
        # Every key of the schema is a key of values.yaml ...
        try:
            default = lookup(values, path)
        except KeyError:
            problems.append(f"in the schema, not in values.yaml: {name}")
            continue
        # ... says what it is ...
        if "type" not in node or not (node.get("description") or node.get("title")):
            problems.append(f"no type, or neither description nor title: {name}")
        # ... and, unless it is a section, carries the default of values.yaml.
        if "properties" in node:
            if not isinstance(default, dict):
                problems.append(f"a section in the schema, a single value in values.yaml: {name}")
            continue
        if "default" not in node:
            problems.append(f"no default in the schema: {name}")
        elif node["default"] != default or type(node["default"]) is not type(default):
            problems.append(
                f"default differs: {name} is {default!r} in values.yaml, {node['default']!r} in the schema"
            )

    # Every key of values.yaml is in the schema. A map the schema treats as
    # one value (resources, annotations) is not descended into.
    def uncovered(mapping, path=()):
        for key, value in mapping.items():
            node = schema_node(schema, path + (key,))
            if node is None:
                problems.append(f"in values.yaml, not in the schema: {'.'.join(path + (key,))}")
            elif "properties" in node and isinstance(value, dict):
                uncovered(value, path + (key,))

    uncovered(values)

    # Permissive: no key is required and none refused for not being listed,
    # the two lists of rules excepted.
    def strictness(node, where, inside_strict_items=False):
        if isinstance(node, dict):
            if not inside_strict_items and ("required" in node or node.get("additionalProperties") is False):
                problems.append(f"required or additionalProperties: false at {where or 'the top level'}")
            for key, child in node.items():
                if key == "properties" and isinstance(child, dict):
                    for prop, sub in child.items():
                        strictness(sub, f"{where}.{prop}" if where else prop, inside_strict_items)
                elif key == "items":
                    strictness(child, f"{where}[]", inside_strict_items or where in STRICT_ITEMS)

    strictness(schema, "")

    # Enums: exactly the listed modes.
    found = {}

    def enums(node, where):
        if isinstance(node, dict):
            if "enum" in node:
                found[where] = node["enum"]
            for prop, sub in (node.get("properties") or {}).items():
                enums(sub, f"{where}.{prop}" if where else prop)
            if "items" in node:
                enums(node["items"], f"{where}[]")

    enums(schema, "")
    if found != ENUMS:
        problems.append(f"enums are {found}, expected {ENUMS}")

    # Text is a form the chart reads for every value it renders through
    # common.tplvalues.render or merges with common.tplvalues.merge, so the
    # schema may not limit such a value to a list, a map or an empty text.
    rendered = set(re.findall(r'tplvalues\.render" *\( *dict "value" \.Values\.([A-Za-z0-9.]+)', templates))
    for merged in re.findall(r'tplvalues\.merge" *\( *dict "values" *\( *list ([^)]*)\)', templates):
        rendered.update(re.findall(r"\.Values\.([A-Za-z0-9.]+)", merged))
    if len(rendered) < 30:
        problems.append(f"only {len(rendered)} values rendered as templates found")
    for name in sorted(rendered):
        node = schema_node(schema, name.split("."))
        if node is None:
            problems.append(f"rendered as a template, not in the schema: {name}")
        elif "string" not in types(node) or "maxLength" in node:
            problems.append(f"rendered as a template by the chart, refused as text by the schema: {name}")

    for problem in problems:
        print(problem)
    print(f"{len(params)} documented parameters, {len(props)} schema entries, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
