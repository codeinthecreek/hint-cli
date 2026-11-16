#!/usr/bin/env python3
"""Tiered "close enough" scoring of a printed line against a row's expected lines
(a library for classify.py).

A returned line is judged against every expected column of its row; its level is
the strictest one it satisfies. Levels (strict -> loose), reported cumulatively:

  exact        identical string
  normalized   same tokens after: leading `sudo` dropped, quotes removed (shlex),
               whitespace collapsed; a <placeholder> stands for one or more characters
               of one token (text around it must match), never for a flag; when
               both tokens have placeholders, never for text with a `:`. Flags
               (with or without a value) may be in any order; other words must
               be in the same order. Compared per `|`, `&&`, `;` segment.
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


def ph_match(pat, tok, any_char=".+"):
    """True if token `pat` (containing <placeholders>) matches token `tok`: the text
    around the placeholders must be equal, each placeholder stands for one or more
    characters, and a placeholder never stands for a flag (a leading `-`)."""
    if tok.startswith("-") and not pat.startswith("-"):
        return False
    rx = any_char.join(re.escape(p) for p in PH.split(pat))
    return re.fullmatch(rx, tok) is not None


def tok_eq(a, b):
    if a == b:
        return True
    if is_ph(a) and is_ph(b):
        # Both are placeholders: one never stands for text with a `:`, so
        # <PATH> is not <USER@HOST>:<PATH> (rsync/scp push vs pull).
        return ph_match(a, b, "[^:]+") or ph_match(b, a, "[^:]+")
    return (is_ph(a) and ph_match(a, b)) or (is_ph(b) and ph_match(b, a))


SEPS = {"|", "||", "&&", ";"}


def is_flag(tok):
    return tok.startswith("-") and len(tok) > 1


def segments(t):
    out = [[]]
    for tok in t:
        if tok in SEPS:
            out.append([])
        else:
            out[-1].append(tok)
    return out


def readings(seg):
    """Every way to read a command: each flag followed by a non-flag word either takes
    it as its value or takes nothing. Yields (other words in order, flag groups)."""
    end = seg.index("--") if "--" in seg else len(seg)
    can = [i for i in range(end - 1) if is_flag(seg[i]) and not is_flag(seg[i + 1])]
    if len(can) > 8:                       # keep the search small
        can = []
    for mask in range(1 << len(can)):
        takes = {can[j] for j in range(len(can)) if mask >> j & 1}
        pos, flags, i = [], [], 0
        while i < len(seg):
            tok = seg[i]
            if i < end and is_flag(tok):
                if i in takes:
                    flags.append((tok, seg[i + 1]))
                    i += 2
                    continue
                flags.append((tok,))
            else:
                pos.append(tok)
            i += 1
        yield pos, flags


def seq_eq(a, b):
    return len(a) == len(b) and all(tok_eq(x, y) for x, y in zip(a, b))


def bag_eq(a, b):
    if len(a) != len(b):
        return False
    if not a:
        return True
    for j, y in enumerate(b):
        if seq_eq(a[0], y) and bag_eq(a[1:], b[:j] + b[j + 1:]):
            return True
    return False


def seg_eq(x, y):
    ry = list(readings(y))
    return any(seq_eq(px, py) and bag_eq(fx, fy)
               for px, fx in readings(x) for py, fy in ry)


def same_args(line, e):
    """Same command after normalizing: other words in the same order, flags (with
    or without a value) in any order, compared per pipeline/list segment."""
    ln, en = normalized(line), normalized(e)
    if not ln:
        return False
    a, b = segments(ln), segments(en)
    return len(a) == len(b) and all(seg_eq(x, y) for x, y in zip(a, b))


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
            if same_args(line, e):
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
