#!/usr/bin/env python3
"""Builds the benchmark page (bench/results/benchmarks.html) from appbench JSON and mdbench output.

Usage: bench/report.py <appbench.json> <keystrokes.json> <machine.json> <template.html> <out.html> [large-rerun.json]
"""
import json
import statistics
import sys

app_path, keys_path, machine_path, template_path, out_path = sys.argv[1:6]
large_path = sys.argv[6] if len(sys.argv) > 6 else None
apps = json.load(open(app_path))
if large_path:
    # A separate re-run of the 1 MB note replaces the large-note runs of the apps it covers.
    rerun = {a["name"]: a for a in json.load(open(large_path))}
    for a in apps:
        if a["name"] in rerun and rerun[a["name"]]["large"]:
            a["large"] = rerun[a["name"]]["large"]
keys = json.load(open(keys_path))
machine = json.load(open(machine_path))

NOTES = {
    "Obsidian": "opens its own vault, not the file it was given",
}
SIZE_NOTES = {
    "TextEdit": "system app: its frameworks ship with macOS and are not counted",
}
NO_FILES = {"Obsidian", "Logseq"}


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def collect(key, runs_key="small", skip_no_files=False):
    rows = []
    for a in apps:
        if a.get("skipped"):
            rows.append({"app": a["name"], "value": None, "note": "was open during the run, not measured"})
            continue
        if skip_no_files and a["name"] in NO_FILES:
            rows.append({"app": a["name"], "value": None, "note": "can't open a standalone file"})
            continue
        # A window faster than 50 ms means the previous instance was still on screen: invalid run.
        runs = [r.get(key) for r in a[runs_key] if (r.get("window") or 0) >= 50]
        n = len([v for v in runs if v is not None])
        rows.append({"app": a["name"], "value": median(runs), "runs": n, "note": NOTES.get(a["name"])})
    return rows


metrics = [
    {
        "id": "launch", "title": "Cold launch → window on screen",
        "detail": "A 1 KB note opened from Finder while the app is closed",
        "unit": "ms", "digits": 0, "verb": "faster than", "anti": "slower than",
        "rows": collect("window"),
    },
    {
        "id": "painted", "title": "Cold launch → note painted",
        "detail": "Until the window stops changing: the frame after which nothing moves for 1.5 s",
        "unit": "ms", "digits": 0, "verb": "faster than", "anti": "slower than",
        "rows": collect("painted"),
    },
    {
        "id": "large", "title": "1 MB note: cold launch → painted",
        "detail": "The same measurement with a 1 MB, 30,000-line note",
        "unit": "ms", "digits": 0, "verb": "faster than", "anti": "slower than",
        "rows": collect("painted", "large", skip_no_files=True),
    },
    {
        "id": "memory", "title": "Memory with a note open",
        "detail": "phys_footprint of every process the app owns (helpers, renderers, WebKit), 5 s after launch",
        "unit": "MB", "digits": 0, "verb": "less memory than", "anti": "more memory than",
        "rows": collect("memoryMB"),
    },
    {
        "id": "cpu", "title": "Idle CPU",
        "detail": "Window in view, no input, 10 s; share of one core",
        "unit": "%", "digits": 2, "verb": "less CPU than", "anti": "more CPU than",
        "rows": collect("idleCPU"),
    },
    {
        "id": "wakeups", "title": "Idle wakeups",
        "detail": "Interrupts that wake the CPU, over the same 10 s",
        "unit": "/s", "digits": 1, "verb": "fewer wakeups than", "anti": "more wakeups than",
        "rows": collect("wakeups"),
    },
    {
        "id": "size", "title": "App size",
        "detail": "Disk space taken by the .app bundle",
        "unit": "MB", "digits": 0, "verb": "smaller than", "anti": "larger than",
        "rows": [{"app": a["name"], "value": a["sizeMB"], "runs": 1, "note": SIZE_NOTES.get(a["name"])} for a in apps],
    },
]

data = {
    "metrics": metrics,
    "apps": [{"name": a["name"], "version": a["version"], "skipped": a.get("skipped")} for a in apps],
    "runs": {"small": max((len(a["small"]) for a in apps), default=0),
             "idle": max((len([r for r in a["small"] if r.get("memoryMB") is not None]) for a in apps), default=0),
             "large": max((len(a["large"]) for a in apps), default=0)},
    "keys": keys,
    "machine": machine,
}

template = open(template_path).read()
open(out_path, "w").write(template.replace("/*DATA*/null", json.dumps(data, ensure_ascii=False)))
print("wrote", out_path)
