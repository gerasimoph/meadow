#!/usr/bin/env python3
"""Builds the benchmark page (bench/results/benchmarks.html) from appbench JSON and mdbench output.

Usage: bench/report.py <appbench.json> <keystrokes.json> <machine.json> <out.html>
"""
import json
import statistics
import sys

app_path, keys_path, machine_path, out_path = sys.argv[1:5]
apps = json.load(open(app_path))
keys = json.load(open(keys_path))
machine = json.load(open(machine_path))

NOTES = {
    "Obsidian": "открывает своё хранилище, а не переданный файл",
    "Logseq": "открывает свой граф, а не переданный файл",
}
NO_FILES = {"Obsidian", "Logseq"}


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def collect(key, runs_key="small", skip_no_files=False):
    rows = []
    for a in apps:
        if a.get("skipped"):
            rows.append({"app": a["name"], "value": None, "note": "был открыт у пользователя, пропущен"})
            continue
        if skip_no_files and a["name"] in NO_FILES:
            rows.append({"app": a["name"], "value": None, "note": "не открывает отдельные файлы"})
            continue
        runs = [r.get(key) for r in a[runs_key]]
        n = len([v for v in runs if v is not None])
        rows.append({"app": a["name"], "value": median(runs), "runs": n, "note": NOTES.get(a["name"])})
    return rows


metrics = [
    {
        "id": "launch",
        "title": "Холодный запуск → окно на экране",
        "detail": "Заметка 1 КБ открывается из Finder при закрытом приложении",
        "unit": "мс", "lower": True, "digits": 0, "verb": "быстрее", "anti": "медленнее",
        "rows": collect("window"),
    },
    {
        "id": "painted",
        "title": "Холодный запуск → заметка отрисована",
        "detail": "До последнего изменения окна: после этого кадра картинка стоит 1,5 с",
        "unit": "мс", "lower": True, "digits": 0, "verb": "быстрее", "anti": "медленнее",
        "rows": collect("painted"),
    },
    {
        "id": "large",
        "title": "Файл 1 МБ: запуск → отрисовано",
        "detail": "Заметка на 1 МБ и 30 тысяч строк, тот же замер",
        "unit": "мс", "lower": True, "digits": 0, "verb": "быстрее", "anti": "медленнее",
        "rows": collect("painted", "large", skip_no_files=True),
    },
    {
        "id": "memory",
        "title": "Память с открытой заметкой",
        "detail": "phys_footprint всех процессов приложения (хелперы, WebKit), через 5 с после запуска",
        "unit": "МБ", "lower": True, "digits": 0, "verb": "меньше памяти", "anti": "больше памяти",
        "rows": collect("memoryMB"),
    },
    {
        "id": "cpu",
        "title": "Процессор в простое",
        "detail": "Окно на экране, никакого ввода, 10 с; доля одного ядра",
        "unit": "%", "lower": True, "digits": 2, "verb": "меньше CPU", "anti": "больше CPU",
        "rows": collect("idleCPU"),
    },
    {
        "id": "wakeups",
        "title": "Пробуждения в простое",
        "detail": "Прерывания, будящие процессор, за те же 10 с",
        "unit": "/с", "lower": True, "digits": 1, "verb": "меньше пробуждений", "anti": "больше пробуждений",
        "rows": collect("wakeups"),
    },
    {
        "id": "size",
        "title": "Размер приложения",
        "detail": "Место на диске, которое занимает .app",
        "unit": "МБ", "lower": True, "digits": 0, "verb": "меньше", "anti": "больше",
        "rows": [{"app": a["name"], "value": a["sizeMB"], "runs": 1} for a in apps],
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

template = open(__file__.replace("report.py", "template.html")).read()
open(out_path, "w").write(template.replace("/*DATA*/null", json.dumps(data, ensure_ascii=False)))
print("wrote", out_path)
