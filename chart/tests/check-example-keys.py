"""Print the keys of an example values file that the chart's values.yaml lacks.

    check-example-keys.py <chart values.yaml> <example values.yaml>

One dotted path per line; no output means every key is known. Helm ignores
unknown keys, so an example that still sets a key the chart has renamed or
dropped renders, installs and silently does something else than its page
says.

A key whose value in the chart's values is an empty map is free-form
(fim.baseline, podLabels): nothing below it is checked. A map where the
chart has a single value or a list is reported as well: its keys are not the
chart's either.
"""

import sys

import yaml


def walk(example, chart, path):
    """Print each key of `example` below `path` that `chart` does not have.

    Descends where both sides hold a map, stops at a free-form (empty) map of
    the chart, and reports a map given where the chart has none.
    """
    for key, value in example.items():
        here = path + [str(key)]
        if not isinstance(chart, dict) or key not in chart:
            print(".".join(here))
        elif isinstance(value, dict):
            if not isinstance(chart[key], dict):
                print(".".join(here) + " (a map, where the chart has none)")
            elif chart[key]:
                walk(value, chart[key], here)


def main():
    """Compare the example values (second argument) with the chart's (first)."""
    with open(sys.argv[1]) as f:
        chart = yaml.safe_load(f)
    with open(sys.argv[2]) as f:
        example = yaml.safe_load(f) or {}
    walk(example, chart, [])


if __name__ == "__main__":
    main()
