#!/usr/bin/env python3
"""Best case for each row of a query file: could hint get this row right at all?

    best_case.py [--queries FILE] [--all]

Feeds each row's query and expected line to `hintdb find` as if the model had
guessed it exactly, and scores what hint would print. No model is called. A row that
fails here can never be a hit, whatever the model does: either the expected
command is not in your sources (history, notes, justfiles), or hint ranks or
displays your row so that it does not match the expected line. Rows that pass
can still fail in a real run (run_hint.py) when the model guesses badly.

An expected `not-installed: <command>` passes when hint lists the command
under `# found in <source>, but <tool> is not installed here:`.

Expected lines with placeholders (`<QUERY>`) are fed in as written, so a row
can fail here only because a placeholder is not a real value; check such rows
with a realistic guess. Uses your real index, so output contains your
commands: do not paste it into the repo.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import classify            # noqa: E402
import score_tiers as st   # noqa: E402
from run_hint import load_section   # noqa: E402


def find(query, guess):
    out = subprocess.run(["hintdb", "find", "--no-update", "--query=" + query, "--", guess],
                         capture_output=True, text=True).stdout
    lines = out.split("\n")
    printed = []   # (command, status line)
    for i, l in enumerate(lines):
        if l.strip() and l[0] not in " \t#":
            printed.append((l.strip(), lines[i + 1].strip() if i + 1 < len(lines) else ""))
    comments = [l.rstrip() for l in lines if l.startswith("#")]
    return printed, comments


def check(query, expected):
    """(ok, detail) for one row."""
    ni = [e[len(classify.NI):].strip() for e in expected if e.startswith(classify.NI)]
    if ni:
        _, comments = find(query, ni[0])
        listed = classify.listed_not_installed({"comments": comments})
        lv = classify.best(listed, ni)
        return lv is not None and lv <= 1, "listed as not installed: %s" % (" | ".join(listed) or "-")
    for e in expected:
        printed, _ = find(query, e)
        for cmd, status in printed:
            mine = "your history" in status or "your notes" in status
            lv = st.level(cmd, expected)
            if mine and lv is not None and lv <= 1:
                return True, "your row: %s" % cmd
    first = find(query, expected[0])[0]
    return False, "printed first: %s" % (first[0][0] if first else "-")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--queries", default=os.path.join(HERE, "example-queries.tsv"))
    ap.add_argument("--all", action="store_true", help="also list the rows that pass")
    args = ap.parse_args()
    rows = load_section(args.queries, None)
    fails = 0
    for q, exp in rows:
        ok, detail = check(q, exp)
        fails += not ok
        if args.all or not ok:
            print("%-4s %s\n       expected: %s\n       %s" % ("ok" if ok else "FAIL", q,
                  " | ".join(exp), detail))
    print("%d of %d rows can hit (best case)" % (len(rows) - fails, len(rows)))


if __name__ == "__main__":
    main()
