#!/usr/bin/env python3
"""Tiered "close enough" scoring of a printed line against a row's expected lines
(a library for classify.py).

A returned line is judged against every expected column of its row; its level is
the strictest one it satisfies. Levels (strict -> loose), reported cumulatively:

  exact        identical string
  normalized   same tokens after: leading `sudo` dropped, quotes removed (shlex),
               whitespace collapsed; a <placeholder> token matches any one token
  cmd+flags    same command key and flag-set Jaccard >= 0.5 (both empty counts as 1)
  cmd          same command key (executable + subcommand), any arguments

Command key: first segment of a pipeline; executable (after sudo), plus the first
non-flag, non-placeholder argument for tools with subcommands (SUBCMD); `docker`
takes two words when the first is compose/system/container/image/volume/network.
Flags: `--long` names without `=value`; single-dash tokens of <= 5 letters are
split into letters (-tulpn -> t,u,l,p,n), longer ones kept whole.
"""
import re
import shlex

SUBCMD = {"git", "docker", "kubectl", "kind", "systemctl", "resolvectl", "journalctl_",
          "yay", "pacman", "just", "hint", "ip", "apt", "npm", "cargo", "helm", "gpg"}
DOCKER2 = {"compose", "system", "container", "image", "volume", "network"}
LEVELS = ["exact", "normalized", "cmd+flags", "cmd"]
PH = re.compile(r"<[^<>]+>")


def tokens(line):
    try:
        t = shlex.split(line)
    except ValueError:
        t = line.split()
    return t


def strip_sudo(t):
    while t and t[0] == "sudo":
        t = t[1:]
        while t and t[0].startswith("-") and t[0] != "--":   # sudo -E etc.
            t = t[1:]
    return t


def is_ph(tok):
    return bool(PH.search(tok))


def normalized(line):
    return strip_sudo(tokens(line.strip()))


def tok_eq(a, b):
    return a == b or is_ph(a) or is_ph(b)


def first_segment(line):
    return re.split(r"\s+\|\s+|\s*&&\s*|\s*;\s*", line.strip(), maxsplit=1)[0]


def key_and_flags(line):
    t = strip_sudo(tokens(first_segment(line)))
    if not t:
        return None, set()
    exe, rest = t[0], t[1:]
    key, flags, subs = [exe], set(), []
    for tok in rest:
        if tok.startswith("--") and len(tok) > 2:
            flags.add(tok.split("=")[0])
        elif tok.startswith("-") and len(tok) > 1 and not tok[1:].isdigit():
            body = tok[1:]
            if body.isalpha() and len(body) <= 5:
                flags.update("-" + c for c in body)
            else:
                flags.add(tok)
        elif not is_ph(tok):
            subs.append(tok)
    if exe in SUBCMD and subs:
        key.append(subs[0])
        if exe == "docker" and subs[0] in DOCKER2 and len(subs) > 1:
            key.append(subs[1])
    return tuple(key), flags


def jaccard(a, b):
    if not a and not b:
        return 1.0
    return len(a & b) / len(a | b)


def level(line, expected):
    """Index into LEVELS of the strictest level reached, or None."""
    best = None
    for e in expected:
        lv = None
        if line == e:
            lv = 0
        else:
            ln, en = normalized(line), normalized(e)
            if ln and len(ln) == len(en) and all(tok_eq(x, y) for x, y in zip(ln, en)):
                lv = 1
            else:
                lk, lf = key_and_flags(line)
                ek, ef = key_and_flags(e)
                if lk and lk == ek:
                    lv = 2 if jaccard(lf, ef) >= 0.5 else 3
        if lv is not None and (best is None or lv < best):
            best = lv
    return best


def best_of(lines, expected):
    lv = [level(l, expected) for l in lines]
    lv = [x for x in lv if x is not None]
    return min(lv) if lv else None
