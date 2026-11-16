#!/usr/bin/env python3
"""Run `hint` (the one on PATH) over every row of a query file.

    run_hint.py [--queries FILE] [--section X|all] [--model M] [--json OUT] [--cold]

For each row it records the command lines `hint` printed, its top-level `#`
comment lines ("see man", "not installed") and the model's raw guesses (from
the HINT_DEBUG block on stderr), and writes them to OUT (default
./last-run.json). See eval/README.md for the query file format.

hint reads your real index and history, so OUT contains your own commands:
keep it (and your query file) outside the repo.

--cold unloads the model from Ollama before every row (much slower; each row
starts cold). Even then, outputs are not fully repeatable: compare runs by
their bucket counts over 2 runs, not row by row.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load_section(path, section):
    rows, inside = [], section is None
    with open(path, encoding="utf-8") as f:
        for line in f.read().split("\n"):
            m = re.match(r"# ([A-Z])\. ", line)
            if m:
                inside = section is None or m.group(1) == section
                continue
            if not inside or not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            expected = [p.strip() for p in parts[1:] if p.strip()]
            if expected:
                rows.append((parts[0], expected))
    return rows


def candidate_lines(stdout):
    return [l.strip() for l in stdout.split("\n") if l.strip() and l[0] not in " \t#"]


def comment_lines(stdout):
    """Top-level `#` lines (not the indented status lines): see man, not installed."""
    return [l.rstrip() for l in stdout.split("\n") if l.startswith("#")]


def guesses_from(stderr):
    out, on = [], False
    for l in stderr.split("\n"):
        if l.startswith("hint: model guesses:"):
            on = True
            continue
        if on:
            if l.startswith("hintdb:") or l.startswith("hint:"):
                break
            if l.strip():
                out.append(l.strip())
    return out


def unload(model):
    """Ask Ollama to unload the model and wait until /api/ps no longer lists it."""
    host = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
    if not host.startswith("http"):
        host = "http://" + host
    req = urllib.request.Request(host + "/api/generate", method="POST",
                                 data=json.dumps({"model": model, "keep_alive": 0}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=30).read()
    for _ in range(100):
        ps = json.load(urllib.request.urlopen(host + "/api/ps", timeout=10))
        if not any(m.get("name") == model or m.get("model") == model for m in ps.get("models", [])):
            return
        time.sleep(0.1)
    raise SystemExit("run_hint: model %s did not unload" % model)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", default=os.path.join(HERE, "example-queries.tsv"))
    ap.add_argument("--section", default="all", help="a section letter, or all")
    ap.add_argument("--model", default="qwen2.5:3b")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--json", default="last-run.json")
    ap.add_argument("--cold", action="store_true", help="unload the model before each row")
    args = ap.parse_args()
    rows = [(q, e) for q, e in load_section(args.queries, None if args.section == "all" else args.section)
            if not e[0].startswith("intent:") and not e[0].startswith("hint ")]
    env = dict(os.environ, HINT_MODEL=args.model, HINT_DEBUG="1")
    res, times = [], []
    for q, exp in rows:
        if args.cold:
            unload(args.model)
        t0 = time.monotonic()
        try:
            p = subprocess.run(["hint"] + q.split(), env=env, cwd=os.path.expanduser("~"),
                               capture_output=True, text=True, timeout=args.timeout)
            out, err, rc = p.stdout, p.stderr, p.returncode
        except subprocess.TimeoutExpired:
            out, err, rc = "", "timeout", -1
        dt = time.monotonic() - t0
        times.append(dt)
        res.append({"query": q, "expected": exp, "lines": candidate_lines(out),
                    "comments": comment_lines(out), "guesses": guesses_from(err), "rc": rc, "t": dt})
    json.dump({"model": args.model, "queries": os.path.basename(args.queries),
               "section": args.section, "cold": args.cold, "rows": res}, open(args.json, "w"), indent=1)
    n = len(res)
    t1 = sum(1 for r in res if r["lines"] and r["lines"][0] in r["expected"])
    print("%d rows, model %s: top-1 exact %d/%d, median %.2f s -> %s"
          % (n, args.model, t1, n, statistics.median(times), args.json))


if __name__ == "__main__":
    main()
