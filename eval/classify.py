#!/usr/bin/env python3
"""Sort the misses of a run_hint.py result into guess problems and match problems.

    classify.py [last-run.json]      (default: ./last-run.json)

Levels come from score_tiers.py (0 exact, 1 normalized, 2 cmd+flags, 3 cmd).
Per row, g = best level among the model's guesses, lv = level of each printed line.
Buckets, first match wins:
  hit             first printed line is exact or normalized
  order           an exact/normalized line was printed, but not first
  match-lost      a guess was closer to the expected line than anything printed
  guess-no-tool   no guess has the expected command at all
  guess-args      the right tool was guessed (and printed), the arguments differ
  match-improved  the printed line is closer than the guess, still not exact
A row whose expected command is not installed here (and not marked not-installed:) is tagged [benchmark?].

An expected entry `not-installed: <command>` means the tool is not installed here: the row is a
hit when hint lists the command under `# found in ..., but <tool> is not installed here:` and
does not print it as a command.
"""
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_tiers as st

ORDER = ["hit", "order", "match-lost", "match-improved", "guess-args", "guess-no-tool"]
NAMES = ["cmd", "cmd+flags", "normalized", "exact"]


def best(lines, expected):
    v = [st.level(l, expected) for l in lines]
    v = [x for x in v if x is not None]
    return min(v) if v else None


NI = "not-installed:"


def listed_not_installed(r):
    """Commands hint listed as comments under a 'found in ..., but ... not installed' header."""
    out, on = [], False
    for c in r.get("comments", []):
        if c.startswith("# found in ") and c.endswith("is not installed here:"):
            on = True
        elif on and c.startswith("#   "):
            out.append(c[4:].strip())
        else:
            on = False
    return out


def classify(r):
    exp = r["expected"]
    ni = [e[len(NI):].strip() for e in exp if e.startswith(NI)]
    if ni:
        found = best(listed_not_installed(r), ni)
        printed = best(r["lines"], ni)
        if found is not None and found <= 1 and printed is None:
            return "hit"
        return "guess-no-tool" if best(r["guesses"], ni) is None else "guess-args"
    lv = [st.level(l, exp) for l in r["lines"]]
    g = best(r["guesses"], exp)
    f = min([x for x in lv if x is not None], default=None)
    if lv and lv[0] is not None and lv[0] <= 1:
        return "hit"
    if f is not None and f <= 1:
        return "order"
    if g is not None and (f is None or g < f):
        return "match-lost"
    if g is None and f is None:
        return "guess-no-tool"
    if f is not None and (g is None or f < g):
        return "match-improved"
    return "guess-args"


def suspect(r):
    exp = r["expected"][0]
    if exp.startswith(NI):
        return False
    t = st.strip_sudo(st.tokens(exp))
    return bool(t) and not shutil.which(t[0]) and subprocess.run(
        ["bash", "-c", "type -t -- %s" % t[0]], capture_output=True).returncode != 0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "last-run.json"
    d = json.load(open(path))
    rows = d["rows"]
    buckets = {b: [] for b in ORDER}
    for r in rows:
        buckets[classify(r)].append(r)
    print("%s: %d rows, model %s, queries %s section %s\n" % (os.path.basename(path), len(rows),
          d["model"], d["queries"], d["section"]))
    for b in ORDER:
        print("%-15s %2d" % (b, len(buckets[b])))
    print("%-15s %2d   (hit + order: expected line anywhere in the output)" % (
        "anywhere", len(buckets["hit"]) + len(buckets["order"])))
    for b in ORDER[1:]:
        if not buckets[b]:
            continue
        print("\n== %s (%d)" % (b, len(buckets[b])))
        for r in buckets[b]:
            print("  %s%s" % (r["query"], "  [benchmark?]" if suspect(r) else ""))
            print("      expected: %s" % " | ".join(r["expected"]))
            print("      guessed:  %s" % (" || ".join(r["guesses"]) or "(none)"))
            print("      printed:  %s" % (" || ".join(r["lines"]) or "(nothing)"))


if __name__ == "__main__":
    main()
