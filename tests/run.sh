#!/usr/bin/env bash
# Tests for hint and hintdb. Run from anywhere:
#
#   tests/run.sh
#
# Uses only the synthetic fixtures in tests/fixtures and a stub Ollama server
# (tests/stub_ollama.py); never touches the real index, history or Ollama.
# Requires: python3 (with sqlite3 FTS5), curl, jq.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
fix="$here/fixtures"

tmp=$(mktemp -d)
stub_pid=
cleanup() { [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf -- "${tmp:?}"; }
trap cleanup EXIT

# Run the repo's hint/hintdb, not installed copies.
mkdir -p "$tmp/bin"
ln -s "$root/hint" "$tmp/bin/hint"
ln -s "$root/hintdb" "$tmp/bin/hintdb"
# Stub tools the fixtures use, so they count as installed here.
for t in fakedock fakedock-compose FakeVM xrandr fakess; do
  printf '#!/bin/sh\n' > "$tmp/bin/$t"; chmod +x "$tmp/bin/$t"
done
export PATH="$tmp/bin:$PATH"

# Isolated index and sources.
export HINTDB_DB="$tmp/hint.db" HINTDB_MANDB="$tmp/man.db"
export HINTDB_SOURCES="$tmp/sources" HISTFILE="$fix/history"
export HINTDB_LOG="$tmp/queries.jsonl" HINTDB_ANSWERS="$tmp/answers" HINTDB_WRONG="$tmp/wrong"
export HINTDB_APROPOS="cat $fix/apropos.txt"
unset HINTDB_IGNORE HINTDB_NO_MAN HINT_DEBUG HINT_MODEL HINT_KEEP_ALIVE HINT_OLLAMA_OPTIONS HINT_TIMEOUT HINT_THINK

pass=0 fail=0

ok()   { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /'; }

# has NAME OUTPUT FIXED_STRING      output contains the string
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "$2"; fi; }
# lacks NAME OUTPUT FIXED_STRING    output does not contain the string
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "$2"; else ok "$1"; fi; }
# line NAME OUTPUT N EXPECTED       line N of output equals EXPECTED
line() {
  local got; got=$(sed -n "${3}p" <<<"$2")
  if [ "$got" = "$4" ]; then ok "$1"; else bad "$1" "expected line $3: $4
got:
$2"; fi
}
# status NAME EXPECTED ACTUAL
status() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "exit status $3, expected $2"; fi; }

echo "== syntax"
python3 -m py_compile "$root/hintdb" && ok "hintdb compiles" || bad "hintdb compiles"
bash -n "$root/hint" && ok "hint parses" || bad "hint parses"
for f in hint hintdb; do
  [ -x "$root/$f" ] && ok "$f is executable" || bad "$f is executable" "chmod +x $f"
done
for f in "$root"/eval/*.py; do
  python3 -m py_compile "$f" && ok "$(basename "$f") compiles" || bad "$(basename "$f") compiles"
done
if grep -nP '[^\x00-\x7F]' "$root/hint" "$root/hintdb" "$here"/*.sh "$here"/*.py "$root"/eval/*.* >/dev/null; then
  bad "code is ASCII only" "$(grep -nP '[^\x00-\x7F]' "$root/hint" "$root/hintdb" "$here"/*.sh "$here"/*.py "$root"/eval/*.*)"
else
  ok "code is ASCII only"
fi

echo "== eval scoring"
# A <placeholder> stands for a value: the text around it must match, and it
# never stands for a flag. When both tokens have placeholders, it never stands
# for text with a `:` (push vs pull). Flags, with or without a value, may be in
# any order; other words must keep their order. Prints each case that scores wrong.
out=$(python3 - "$root/eval" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import score_tiers as st
cases = [  # printed line, expected line, hit (normalized level or better)?
    ("ssh root@example.org", "ssh <user>@<host>", True),
    ("ssh root@example.org", "ssh user@<host>", False),
    ("ping -c 3 192.0.2.1", "ping -c <n> <host>", True),
    ("tar -xf <FILE> -C <PATH>", "tar -xf <archive> -C <dir>", True),
    ("unzip <FILE> -d <PATH>", "unzip -d <PATH> <ARCHIVE>", True),
    ("tar -xf <FILE> -C <PATH>", "tar -C <dir> -xf <archive>", True),
    ("cp -r a b", "cp a -r b", True),
    ("cp a b", "cp b a", False),
    ("rsync -av --delete <PATH> <USER@HOST>:<PATH>", "rsync --delete -av <PATH> <USER@HOST>:<PATH>", True),
    ("rsync -av --delete <PATH> <USER@HOST>:<PATH>", "rsync --delete -av <USER@HOST>:<PATH> <PATH>", False),
    ("ls -l | grep x", "ls | grep -l x", False),
    ("kubectl delete pods --all", "kubectl delete pods <name>", False),
    ("rsync -av <PATH> <USER@HOST>:<PATH>", "rsync -av <USER@HOST>:<PATH> <PATH>", False),
    ("scp <FILE> <USER@HOST>:<PATH>", "scp <USER@HOST>:<PATH> <FILE>", False),
    ("ssh <USER@HOST>", "ssh <USER>@<HOST>", True),
    ("glow -p <PATH>", "glow -p <FILE>.md", True),
    ("curl https://example.org/api", "curl <url>", True),
]
for line, exp, want in cases:
    lv = st.level(line, [exp])
    if (lv is not None and lv <= 1) != want:
        print(f"{line!r} vs {exp!r}: level {lv}, want hit={want}")
EOF
)
if [ -z "$out" ]; then ok "eval scoring: placeholders and flag order"; else bad "eval scoring: placeholders and flag order" "$out"; fi

echo "== index"
out=$(hintdb add "$fix/notes" 2>&1)
has "build from history and notes" "$out" "entries"
idx=$(python3 - "$HINTDB_DB" <<'EOF'
import sqlite3, sys
for display, dnote, count in sqlite3.connect(sys.argv[1]).execute(
        "SELECT display, dnote, count FROM entries"):
    print(f"{display}\t{dnote}\tx{count}")
EOF
)
lacks "trivial commands dropped" "$idx" "cd /etc"
lacks "probable typo dropped" "$idx" "gerpx"
lacks "secret dropped" "$idx" "GITHUB_TOKEN"
lacks "hint lookups not indexed" "$idx" "dns lookup"
lacks "hintdb lookups not indexed" "$idx" "hintdb"
has "hosts, IPs and quoting merge into one row" "$idx" \
  "ssh-keygen -f '/home/user/.ssh/known_hosts' -R <HOST>	remove offending ECDSA key	x4"
has "varying paths keep their common directory" "$idx" "tail -f /var/log/<PATH>		x3"
has "file names become <FILE>" "$idx" "tar -czf <FILE> docs		x2"
has "varying quoted strings become <STR>, not bare words" "$idx" \
  "ssh-keygen -t ed25519 -f ~/.ssh/<PATH> -C <STR>		x2"
has "python -m module name is not a host" "$idx" "python3 -m http.server 8000		x2"
has "flags kept as written: +short is its own row" "$idx" "dig +short <HOST>		x3"
has "note on a minority variant stays off the row" "$idx" "mkdir <PATH>		x6"
has "trailing / kept in a merged row" "$idx" \
  "rsync -e \"ssh -i ~/.ssh/id_ed25519.lab -o IdentitiesOnly=yes\" --archive --delete <USER@HOST>:<PATH>/ /home/user/backup/<PATH>/	trailing / on source copies its contents	x2"
has "path with trailing / is its own row" "$idx" "du -sh /srv/current/		x1"
has "same path without trailing / is its own row" "$idx" "du -sh /srv/current		x1"
has "note on a single-variant row is shown" "$idx" \
  "ssh -N -L 5432:localhost:5432 db.example.org	tunnel to postgres	x1"
has "markdown: heading and comment become the note" "$idx" \
  "kubectl cordon node1	Cordon and drain; Mark node unschedulable then evict pods.; cordon first"
has "markdown: continuation lines joined" "$idx" "kubectl drain node1 --ignore-daemonsets"
has "markdown: console block takes \$ lines only" "$idx" "kubectl get nodes"
lacks "markdown: console output skipped" "$idx" "node1 Ready"
lacks "markdown: non-shell fence skipped" "$idx" "apiVersion"
has "justfile: recipe name and doc comment as note" "$idx" \
  "terraform destroy -auto-approve	just rebuild; rebuild the cluster from scratch"

src=$(python3 - "$HINTDB_DB" <<'EOF2'
import json, os, sqlite3, sys
for display, sources in sqlite3.connect(sys.argv[1]).execute(
        "SELECT display, sources FROM entries"):
    print(display + "\t" + " ".join(os.path.basename(p) for p in json.loads(sources)))
EOF2
)
has "source: a notes row records its notes file" "$src" "kubectl cordon node1	k8s.md"
has "source: a history row records the history file" "$src" "dig +short <HOST>	history"
has "source: a row from history and notes records both" "$src" "kubectl get nodes	history k8s.md"

out=$(hintdb update)
has "no rebuild when nothing changed" "$out" "entries up to date"

out=$(hintdb stats)
has "man index skips non-command and POSIX pages" "$out" "man	7 pages"
out=$(HOME=/nonexistent hintdb stats)
has "stats per source: history" "$out" "$fix/history	32 entries, 31 only from this source"
has "stats per source: a source sharing a row with history" "$out" \
  "$fix/notes/k8s.md	3 entries, 2 only from this source"
has "stats per source: one entry" "$out" "$fix/notes/cluster.md	1 entry, 1 only from this source"
if [ "$(grep -A99 '^man' <<<"$out" | grep -c ' only from this source')" = 4 ]; then
  ok "stats per source: one line per source file, after the kind and man lines"
else bad "stats per source: one line per source file, after the kind and man lines" "$out"; fi
line "stats per source: most entries first" "$(grep -A1 "^man" <<<"$out")" 2 "$fix/history	32 entries, 31 only from this source"
has "stats per source: home shown as ~" "$(HOME="$root" hintdb stats)" \
  "~/tests/fixtures/history	32 entries"

out=$(HOME=/nonexistent hintdb stats --source "$fix/notes/k8s.md")
line "stats --source: most uses first, other sources named" "$out" 1 \
  "kubectl get nodes  [x2]  # Cordon and drain; Mark node unschedulable then evict pods.; also in $fix/history"
if [ "$(wc -l <<<"$out")" = 3 ]; then ok "stats --source: one line per entry from the file"
else bad "stats --source: one line per entry from the file" "$out"; fi
out=$(hintdb stats --source "$fix/notes")
has "stats --source: a directory lists its files' entries" "$out" "terraform destroy -auto-approve  [x1]  # just rebuild"
out=$(hintdb stats --source "$fix/nonexistent" 2>&1)
status "stats --source: unknown source fails" 1 $?
has "stats --source: unknown source says so" "$out" "no entries from"

echo "== recipe files (Makefiles, justfiles)"
# A separate index, so the counts above stay as they are. Its history
# only uses bash aliases from the fixture (not on PATH).
printf '%s\n' 'hless' 'hgrep ssh-keygen' > "$tmp/recipes_history"
out=$(HINTDB_DB="$tmp/recipes.db" HINTDB_SOURCES="$tmp/recipes_sources" \
  HISTFILE="$tmp/recipes_history" hintdb add "$fix/recipes" 2>&1)
has "recipes: directory walk finds Makefile, *.mk and justfile" "$out" "entries"
rec=$(python3 - "$tmp/recipes.db" <<'EOF'
import sqlite3, sys
for display, dnote in sqlite3.connect(sys.argv[1]).execute(
        "SELECT display, dnote FROM entries"):
    print(f"{display}\t{dnote}")
EOF
)
has "make: \\ lines joined, @ stripped, ## doc on the target line" "$rec" \
  "docker run -d --restart=always --name registry -p 5000:5000 registry:2	make registry; start the local registry"
lacks "make: a section divider is not the next recipe's note" "$rec" "Cluster"
has "make: comment above the target as doc, - stripped, \$\$ -> \$" "$rec" \
  "docker network inspect kind --format \"\$X\"	make net; create the cluster network"
lacks "make: if-block joined and dropped whole" "$rec" "docker network create"
lacks "make: no shell fragments" "$rec" "fi	"
has "make: \$(VAR) kept, trailing comment as note" "$rec" \
  "kubectl --context kind-\$(CLUSTER) get nodes -o wide	make nodes; all of them"
lacks "make: && chain dropped" "$rec" "kubectl get pods"
lacks "make: pattern rules skipped" "$rec" "cc -c"
has "make: *.mk detected" "$rec" "shellcheck --severity=warning *.sh	make lint"
has "just: \\ lines joined, continuation keeps its dashes" "$rec" \
  "docker compose up -d --remove-orphans	just up"
lacks "just: for loop dropped" "$rec" "kubectl apply"
lacks "recipes: @echo lines dropped" "$rec" "packing docs"
lacks "recipes: plain echo lines dropped" "$rec" "echo unpacking"
rdb() { HINTDB_DB="$tmp/recipes.db" HINTDB_SOURCES="$tmp/recipes_sources" \
  HISTFILE="$tmp/recipes_history" hintdb "$@"; }
out=$(rdb find -q "pack the docs folder" 2>&1)
has "make: status label says your Makefile" "$out" \
  "  # your Makefile: make backup; pack the docs folder"
out=$(rdb find -q "unpack the docs backup" 2>&1)
has "just: status label says your justfile" "$out" \
  "  # your justfile: just restore; unpack the docs backup"
has "stats: Makefile and justfile entries counted per kind" "$(rdb stats)" "make	5 entries"
out=$(python3 - "$root/hintdb" <<'EOF'
import importlib.machinery, sys
h = importlib.machinery.SourceFileLoader("h", sys.argv[1]).load_module()
for line in ("  # your Makefile: make up", "  # your justfile: just up",
             "  # your git aliases: sync", "  # your aliases: rm -i"):
    print(repr(h.status_note(line)))
EOF
)
if [ "$out" = "'make up'
'just up'
'sync'
'rm -i'" ]; then ok "search: Makefile, justfile and alias labels do not match"
else bad "search: Makefile, justfile and alias labels do not match" "$out"; fi

has "git: .git_aliases found in a directory walk, only [alias] read" "$(rdb stats)" "git	7 entries"
lacks "git: other sections skipped" "$rec" "Example User"
has "git: row is git <alias>, #--- heading as note, then the body" "$rec" \
  "git st	repo status; status -s"
has "git: a #--- heading applies to every alias under it" "$rec" \
  "git sto	repo status; status -uno"
lacks "git: a heading ends at the next [section]" "$rec" "git co	fork"
has "git: a second [alias] section is read too" "$rec" "git co	checkout"
has "git: comment lines above joined, ! body as written, quotes removed" "$rec" \
  "git sync	sync default branch: fetch + ff-only merge and push, safe to run any time; fork/upstream workflow; !f() { D=\$(git default); git switch \$D && git fetch origin --prune; }; f"
has "git: the value's trailing comment after the body" "$rec" \
  "git lf	fork/upstream workflow; log --follow --; path/to/filename"
has "git: \\ continues a value" "$rec" \
  "git pretty	fork/upstream workflow; log --pretty=format:'%h %s' --date=short"
has "git: escaped quotes in a value" "$rec" "git shout	fork/upstream workflow; !echo \"done\""
has "alias: .bash_aliases found in a directory walk" "$(rdb stats)" "alias	6 entries"
has "alias: row is the alias name, block comment as note, then the body" "$rec" \
  "rmi	safety aliases; rm -i"
has "alias: a block comment covers every alias in the block" "$rec" "mvi	safety aliases; mv -i"
lacks "alias: commented-out alias skipped" "$rec" "cpi"
lacks "alias: wrapper adding options to its own command skipped" "$rec" "ls --color"
has "alias: several aliases on one line, ; kept in the body" "$rec" \
  "hless	history aliases; history | less"
has "alias: after && and with a trailing comment; a blank line ends a block" "$rec" \
  "del	/usr/bin/trash; move to the trash, not rm"
has "alias: double quotes removed" "$rec" "tarls	tar -tzf"
out=$(rdb find -q "page through history with less" 2>&1)
line "alias: also typed in history, shown (alias names count as installed)" "$out" 1 "hless"
has "alias: ... labelled with the history count" "$out" "  # your history x2: history aliases; history | less"
has "alias: a one-off history line using an alias is kept" "$(rdb stats --source "$tmp/recipes_history")" \
  "hgrep ssh-keygen  [x1]"
out=$(rdb find -q "move a file to the trash" 2>&1)
has "alias: shown though the alias is not on PATH, labelled your aliases" "$out" \
  "  # your aliases: /usr/bin/trash; move to the trash, not rm"
out=$(rdb find -q "sync the default branch" 2>&1)
has "git: status label says your git aliases" "$out" \
  "  # your git aliases: sync default branch"

echo "== query (keyword search, debugging only)"
out=$(hintdb query DNS lookup)
has "man NAME lines matching the words are listed" "$out" "man    dig(1): DNS lookup utility"
line "the user's rows come first, with find's score" "$out" 1 " 1.01  resolvectl dns  [x2]"
out=$(hintdb query -n 3 tunnel to postgres)
line "query ranks like find on the words alone (history comment found)" "$out" 1 \
  " 1.00  ssh -N -L 5432:localhost:5432 db.example.org  # tunnel to postgres"

echo "== find"
out=$(hintdb find -q "short dns lookup" "dig +short example.com" 2>&1)
line "guess with the same shape as a row: the user's row" "$out" 1 "dig +short <HOST>"
has "row status: history count and example" "$out" "# your history x3; e.g. dig +short web"
lacks "guess with the same shape as a printed row is not printed" "$out" "example.com"

out=$(hintdb find -q "remove offending key" "rm ~/.ssh/known_hosts" 2>&1)
line "history comment found by the question's words, wrong tool guessed" "$out" 1 \
  "ssh-keygen -f '/home/user/.ssh/known_hosts' -R <HOST>"
line "the user's row leads: the model's guess comes second" "$out" 3 "rm ~/.ssh/known_hosts"
line "the model's guess second is labelled model suggestion" "$out" 4 "  # model suggestion"

out=$(hintdb find -q "tunnels to postgres" 2>&1)
line "words match by stem (tunnels -> tunnel), no guesses needed" "$out" 1 \
  "ssh -N -L 5432:localhost:5432 db.example.org"

out=$(hintdb find -q "post" 2>&1)
lacks "words do not match by prefix (post -> postgres)" "$out" "5432"

out=$(hintdb find -q "nginx logs" 2>&1)
lacks "values are not searched unless a path is mentioned" "$out" "tail -f"
out=$(hintdb find -q "nginx log directory" 2>&1)
line "values are searched when a path is mentioned" "$out" 1 "tail -f /var/log/<PATH>"

out=$(hintdb find -q "look up mail exchanger records" "dig mx example.org" 2>&1)
line "best row holds few of the question's words: the model's guess leads" "$out" 1 \
  "dig mx example.org"
line "a leading guess is the most likely" "$out" 2 "  # most likely (model suggestion)"
has "the user's rows for the guessed tool follow" "$out" "dig +short <HOST>"
has "see man for a suggested tool, with section and summary" "$out" \
  "# see man dig(1): DNS lookup utility"

out=$(hintdb find -q "query name servers" "nslookup example.com" "nslookup -type=mx example.com" 2>&1)
line "no rows: first guess" "$out" 1 "nslookup example.com"
line "no rows: first guess is the most likely" "$out" 2 "  # most likely (model suggestion)"
line "no rows: later guesses are alternatives" "$out" 4 "  # alternative (model suggestion)"
if [ "$(grep -c '^# see man nslookup' <<<"$out")" = 1 ]; then
  ok "see man once per tool"
else
  bad "see man once per tool" "$out"
fi

out=$(hintdb find -q "forget a known host" "ssh-keygen -R example.org" 2>&1)
if [ "$(grep -c '^ssh-keygen .*-R <HOST>\|^ssh-keygen -R web2' <<<"$out")" = 1 ]; then
  ok "rows that differ only in values and flag order shown once"
else
  bad "rows that differ only in values and flag order shown once" "$out"
fi
has "several rows of the tool are shown" "$out" "ssh-keygen -l -f /home/user/.ssh/<PATH>"

out=$(hintdb find -q "disk usage of directory contents" "du -sh /tmp/x/" 2>&1)
if [ "$(grep -c '^du -sh /srv/current/\?$' <<<"$out")" = 2 ]; then
  ok "trailing / is not collapsed as a value"
else
  bad "trailing / is not collapsed as a value" "$out"
fi
first=$(grep -m1 '^du ' <<<"$out")
if [ "$first" = "du -sh /srv/current/" ]; then ok "equal scores: the row whose trailing / matches the guess first"
else bad "equal scores: the row whose trailing / matches the guess first" "$out"; fi
out=$(hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" 2>&1)
first=$(grep -m1 '^du ' <<<"$out")
if [ "$first" = "du -sh /srv/current" ]; then ok "equal scores: the row without trailing / first for a guess without"
else bad "equal scores: the row without trailing / first for a guess without" "$out"; fi

out=$(hintdb find -q "dns" "dig +short a.example.org" "dig +short b.example.org" 2>&1)
if [ "$(grep -c '^dig +short <HOST>$' <<<"$out")" = 1 ]; then
  ok "same row for two guesses printed once"
else
  bad "same row for two guesses printed once" "$out"
fi

out=$(hintdb find -q "zzqq frobnicate" 2>&1)
if [ -z "$out" ]; then ok "nothing found, no guesses: prints nothing"; else bad "nothing found, no guesses: prints nothing" "$out"; fi

err=$(hintdb find --debug -q "ssh tunnel" "ssh -L 8080:localhost:80 user@remote_host" 2>&1 >/dev/null)
has "--debug shows the words" "$err" "words: ['ssh', 'tunnel']"
has "--debug shows the guessed tools" "$err" "guessed tools: ['ssh']"
has "--debug shows the score table" "$err" "score   bm25 tool flags gwords  uses   command"
has "--debug shows who leads" "$err" "of the question's words ->"

out=$(hintdb find -q "create an ssh tunnel to postgres" "ssh -L 5433:localhost:5432 user@postgres-server" 2>&1)
n=$(grep -cE '^ssh (user@<HOST>|buildhost|webhost)$' <<<"$out")
if [ "$n" = 1 ]; then ok "tool-only rows (nothing but the tool matches) shown once"
else bad "tool-only rows (nothing but the tool matches) shown once" "$out"; fi
has "rows with a shared flag are not tool-only" "$out" "ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>"
n=$(grep -c '^ssh' <<<"$out")
if [ "$n" -le 5 ]; then ok "a skipped tool-only row is not replaced by another row"
else bad "a skipped tool-only row is not replaced by another row" "$out"; fi

out=$(hintdb find -q "stop the containers" "fakedock-compose down" 2>&1)
line "guessed a-b tool read as the user's 'a b' form: their row found" "$out" 3 "fakedock compose down"
err=$(hintdb find --debug -q "log in" "ssh user@remote_host" 2>&1 >/dev/null)
has "a guess without flags or plain words gives no flag credit" "$err" \
  "1.0  0.00   1.00  x6      ssh user@<HOST>"
err=$(hintdb find --debug -q "stop the containers" "fakedock-compose down" 2>&1 >/dev/null)
has "a guess without flags: its plain words count as the flag overlap" "$err" \
  "1.00   1.00  x1      fakedock compose down"
has "--debug shows the a-b reading" "$err" "guessed tool fakedock-compose also read as 'fakedock compose'"

err=$(hintdb find --debug -q "search ignoring case" "grep -ri todo src" 2>&1 >/dev/null)
has "bundled short flags compared letter by letter (-ri as -r -i)" "$err" \
  "1.0  1.00   0.26  x1      grep -r -i TODO src"
err=$(hintdb find --debug -q "list files by name" "find . -name x.log -mtime +7" 2>&1 >/dev/null)
has "find -name stays whole; +N values are not flags (2 of 3 flags)" "$err" \
  "1.0  0.67   0.00  x1      find . -name \"*.log\" -mtime +30 -delete"
err=$(hintdb find --debug -q "dns" "dig +short example.com" 2>&1 >/dev/null)
has "dig-style +opt still counts as a flag" "$err" "1.0  1.00   1.00  x3      dig +short <HOST>"

echo "== installed only"
out=$(hintdb find -q "zzqq" "foozz --bar" 2>&1)
line "uninstalled guess, nothing else: says so" "$out" 1 \
  "# no installed command found; the model suggested the following:"
line "uninstalled guess shown as a comment only" "$out" 2 "#   foozz --bar"

out=$(hintdb find -q "short dns" "foozz --bar" "dig +short example.com" 2>&1)
line "uninstalled guess omitted when an installed command is shown" "$out" 1 "dig +short <HOST>"
lacks "uninstalled guess not mentioned then" "$out" "foozz"

out=$(hintdb find -q "list jobs" "fakesched -Nel" 2>&1)
has "user's rows for an uninstalled tool: named source" "$out" \
  "# found in cluster.md, but fakesched is not installed here:"
has "user's rows for an uninstalled tool: as comments" "$out" "#   fakesched -Nel"
if grep -q '^fakesched' <<<"$out"; then
  bad "uninstalled tool never printed as a command" "$out"
else
  ok "uninstalled tool never printed as a command"
fi
lacks "uninstalled guess with rows not repeated in the model block" "$out" "no installed command found"

out=$(hintdb find -q "show history" "history 10" 2>&1)
line "shell builtins count as installed (history)" "$out" 1 "history 10"
out=$(hintdb find -q "history without numbers" "fc -ln -10" 2>&1)
line "shell builtins count as installed (fc, user's row)" "$out" 1 "fc -ln -10"
has "shell builtins count as installed (fc, user's row)" "$out" "# your history x1"

echo "== query log"
log="$HINTDB_LOG"
: > "$log"
out=$(hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" 2>/dev/null)
has "log: one line per lookup" "$(wc -l <"$log")" "1"
rec=$(tail -n1 "$log")
has "log: the query" "$(jq -r .query <<<"$rec")" "disk usage of directory contents"
has "log: the guesses as given" "$(jq -r '.guesses | join("|")' <<<"$rec")" "du -sh /tmp/x"
if [ "$(jq -r '.printed[]' <<<"$rec")" = "$out" ]; then ok "log: printed lines exactly as shown"
else bad "log: printed lines exactly as shown" "$rec"; fi
has "log: time stamp" "$(jq -r .time <<<"$rec")" "T"
has "log: each printed row with its source file" \
  "$(jq -r '.rows[] | select(.line == "du -sh /srv/current") | .sources[]' <<<"$rec")" "$fix/history"
lacks "log: model guesses have no row entry" "$(jq -r '.rows[].line' <<<"$rec")" "/tmp/x"

hintdb find -q "zzqq frobnicate" >/dev/null 2>&1
has "log: a lookup that printed nothing is logged too" "$(wc -l <"$log")" "2"
has "log: nothing printed" "$(tail -n1 "$log" | jq -c .printed)" "[]"

hintdb find -q "list jobs" "fakesched -Nel" >/dev/null 2>&1
rec=$(tail -n1 "$log")
has "log: uninstalled rows logged with their source" \
  "$(jq -r '.rows[] | select(.line | startswith("fakesched")) | .sources[]' <<<"$rec")" "cluster.md"

out=$(HINTDB_LOG="$tmp/newdir/sub/queries.jsonl" hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" 2>/dev/null)
has "log: missing directory is created" "$(cat "$tmp/newdir/sub/queries.jsonl" 2>/dev/null | wc -l)" "1"
mkdir -p "$tmp/ro"; chmod 500 "$tmp/ro"
out=$(HINTDB_LOG="$tmp/ro/queries.jsonl" hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" 2>"$tmp/err")
status "log: unwritable log does not fail the lookup" 0 $?
has "log: unwritable log: answer still printed" "$out" "du -sh /srv/current"
has "log: unwritable log: warning" "$(cat "$tmp/err")" "hintdb: cannot write query log"
chmod 700 "$tmp/ro"

echo "== hint (stub Ollama)"
reply="$tmp/reply"
export STUB_REPLY_FILE="$reply" STUB_THINKING_FILE="$tmp/thinking"
: > "$reply"
python3 "$here/stub_ollama.py" "$tmp/port" "$tmp/request" &
stub_pid=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
export OLLAMA_HOST="127.0.0.1:$(cat "$tmp/port")"

hint >/dev/null 2>&1
status "no arguments: usage, exit 2" 2 $?
out=$(hint help 2>&1)
status "help alone: exit 2" 2 $?
has "help alone: usage" "$out" "usage: hint"
out=$(hint -h dns lookup 2>&1)
status "-h with more words: usage, exit 2" 2 $?
out=$(hint --help 2>&1)
status "--help: usage, exit 2" 2 $?

printf '%s\n' 'du -sh /tmp/x' > "$reply"
out=$(hint help me find large files 2>&1)
status "help followed by words is a question: exit 0" 0 $?
lacks "help followed by words: no usage" "$out" "usage: hint"
has "help followed by words: whole line sent as the query" \
  "$(jq -r '.messages[-1].content' <"$tmp/request")" "help me find large files"
has "hint lookups are logged with the whole question" \
  "$(tail -n1 "$HINTDB_LOG" | jq -r .query)" "help me find large files"

printf '%s\n' '```bash' '1. dig +short example.com' '' '$ ssh -L 8080:localhost:80 user@remote_host' \
  '- nslookup example.com' 'host example.com' '```' > "$reply"
out=$(hint short dns lookup 2>&1)
status "messy reply: exit 0" 0 $?
lacks "fences stripped" "$out" '```'
has "numbering stripped" "$out" "dig +short <HOST>"
has "\$ prompt stripped" "$out" "ssh -L 8080:localhost:80 user@remote_host"
has "bullet stripped" "$out" "nslookup example.com"
lacks "at most 3 guesses used" "$out" "host example.com"

req=$(cat "$tmp/request")
has "request: model default" "$(jq -r .model <<<"$req")" "qwen2.5-coder:3b"
has "request: temperature 0" "$(jq -r .options.temperature <<<"$req")" "0"
has "request: not streamed" "$(jq -r .stream <<<"$req")" "false"
has "request: system, example exchange, then the query" \
  "$(jq -r '[.messages[].role] | join(",")' <<<"$req")" "system,user,assistant,user"
has "request: system asks for different tools when unsure" \
  "$(jq -r '.messages[0].content' <<<"$req")" "If you are not sure which tool fits, use a different tool on each line."
has "request: last message is the query" \
  "$(jq -r '.messages[-1].content' <<<"$req")" "short dns lookup"
has "request: no keep_alive unless HINT_KEEP_ALIVE is set" "$(jq -r 'has("keep_alive")' <<<"$req")" "false"
has "request: think false by default" "$(jq -c .think <<<"$req")" "false"

# Model settings: HINT_KEEP_ALIVE, HINT_OLLAMA_OPTIONS, HINT_TIMEOUT.
printf '%s\n' 'dig +short example.org' > "$reply"
HINT_KEEP_ALIVE=2h hint dns lookup >/dev/null 2>&1
has "HINT_KEEP_ALIVE=2h: sent as a string" "$(jq -c .keep_alive <"$tmp/request")" '"2h"'
HINT_KEEP_ALIVE=-1 hint dns lookup >/dev/null 2>&1
has "HINT_KEEP_ALIVE=-1: sent as a number" "$(jq -c .keep_alive <"$tmp/request")" '-1'
HINT_OLLAMA_OPTIONS='{"num_gpu": 12, "num_predict": 60}' hint dns lookup >/dev/null 2>&1
req=$(cat "$tmp/request")
has "HINT_OLLAMA_OPTIONS: new option added" "$(jq -c .options.num_gpu <<<"$req")" "12"
has "HINT_OLLAMA_OPTIONS: overrides hint's own" "$(jq -c .options.num_predict <<<"$req")" "60"
has "HINT_OLLAMA_OPTIONS: hint's other options kept" "$(jq -c .options.temperature <<<"$req")" "0"
for bad_opts in 'num_gpu=12' '[1,2]' '{"a":1} {"b":2}' '"x"'; do
  : > "$tmp/request"
  out=$(HINT_OLLAMA_OPTIONS="$bad_opts" hint dns lookup 2>&1)
  status "HINT_OLLAMA_OPTIONS=$bad_opts: exit 1" 1 $?
  has "HINT_OLLAMA_OPTIONS=$bad_opts: says it must be a JSON object" "$out" \
    "hint: HINT_OLLAMA_OPTIONS must be one JSON object"
  [ -s "$tmp/request" ] && bad "HINT_OLLAMA_OPTIONS=$bad_opts: nothing sent" || ok "HINT_OLLAMA_OPTIONS=$bad_opts: nothing sent"
done
err=$(HINT_DEBUG=1 HINT_KEEP_ALIVE=30m HINT_OLLAMA_OPTIONS='{"num_gpu": 12}' hint dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: request settings shown" "$err" \
  'hint: request: model qwen2.5-coder:3b, keep_alive 30m, think false, timeout 60 s, options {"temperature":0,"num_predict":120,"num_gpu":12}'
err=$(HINT_DEBUG=1 hint dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: unset keep_alive shown as the server default" "$err" "keep_alive server default"
HINT_THINK=true hint dns lookup >/dev/null 2>&1
has "HINT_THINK=true: sent as a boolean" "$(jq -c .think <"$tmp/request")" "true"
HINT_THINK=false hint dns lookup >/dev/null 2>&1
has "HINT_THINK=false: sent as a boolean" "$(jq -c .think <"$tmp/request")" "false"
HINT_THINK=low hint dns lookup >/dev/null 2>&1
has "HINT_THINK=low: sent as a string" "$(jq -c .think <"$tmp/request")" '"low"'
printf '%s\n' 'The user wants a DNS lookup.' > "$tmp/thinking"
err=$(HINT_DEBUG=1 HINT_THINK=true hint dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: the model's thinking shown" "$err" "hint: model thinking:"
has "HINT_DEBUG: the thinking text" "$err" "The user wants a DNS lookup."
out=$(HINT_THINK=true hint dns lookup 2>&1)
lacks "thinking is not shown without HINT_DEBUG" "$out" "The user wants a DNS lookup."
rm -f "$tmp/thinking"
printf '%s\n' '!error "qwen2.5-coder:3b" does not support thinking' > "$reply"
out=$(HINT_THINK=true hint dns lookup 2>&1)
status "HINT_THINK=true, model cannot think: exit 1" 1 $?
has "HINT_THINK=true, model cannot think: Ollama's message shown" "$out" "does not support thinking"
printf '%s\n' 'dig +short example.org' > "$reply"
for bad_t in 0 abc 1.5; do
  out=$(HINT_TIMEOUT=$bad_t hint dns lookup 2>&1)
  status "HINT_TIMEOUT=$bad_t: exit 1" 1 $?
  has "HINT_TIMEOUT=$bad_t: says it must be whole seconds" "$out" "hint: HINT_TIMEOUT must be a whole number of seconds"
done
printf '%s\n' '!sleep 3' > "$reply"
out=$(HINT_TIMEOUT=1 hint dns lookup 2>&1)
status "HINT_TIMEOUT=1, slow model: exit 1" 1 $?
has "HINT_TIMEOUT=1, slow model: names the limit and the variable" "$out" \
  "did not answer within 1 s (model qwen2.5-coder:3b); loading a model can take longer: raise HINT_TIMEOUT"
: > "$reply"

printf '%s\n' 'dig +short example.com' > "$reply"
err=$(HINT_DEBUG=1 hint dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: model guesses" "$err" "hint: model guesses:"
has "HINT_DEBUG: find scores" "$err" "score   bm25 tool flags gwords  uses   command"

: > "$reply"
out=$(hint short dns lookup 2>&1)
status "empty reply: the question's own words are still looked up (exit 0)" 0 $?
has "empty reply: the user's row found by the question's words" "$out" "dig +short <HOST>"

# The guess bridges the question's words and the user's: no question word is
# on the user's xrandr row, so only the guessed tool finds it.
out=$(hint how do I set the screen resolution 2>&1)
lacks "no guess: a row with none of the question's words is not found" "$out" "xrandr"
printf '%s\n' 'xrandr -s 1920x1080' > "$reply"
out=$(hint how do I set the screen resolution 2>&1)
has "guessed tool finds the user's row with none of the question's words" "$out" \
  "xrandr --output HDMI-1 --mode 2560x1440"
has "the guess is shown as a model suggestion" "$out" "xrandr -s 1920x1080"
: > "$reply"

out=$(hint zzqq frobnicate 2>&1)
status "empty reply, nothing found: exit 1" 1 $?
has "empty reply, nothing found: asks to rephrase" "$out" \
  "Sorry, I didn't understand your question, can you rephrase it?"

printf '%s\n' "I'm sorry, but I can't assist with that request." > "$reply"
out=$(hint zzqq frobnicate 2>&1)
has "prose-only reply: asks to rephrase" "$out" \
  "Sorry, I didn't understand your question, can you rephrase it?"
lacks "prose-only reply: prose not shown as a model suggestion" "$out" "assist"

printf '%s\n' 'Alternatively, you can use:' '**Option 1:**' '# replace the host' \
  'dig +short example.com' 'FakeVM list vms' 'Unfortunately, that needs root.' \
  'nslookup example.com' 'host example.com' > "$reply"
out=$(hint short dns lookup 2>&1)
has "prose, bold and comment lines dropped: first command kept" "$out" "dig +short <HOST>"
lacks "prose line dropped" "$out" "Alternatively"
lacks "bold line dropped" "$out" "Option 1"
lacks "comment line dropped" "$out" "replace the host"
has "installed command starting with a capital kept" "$out" "FakeVM list vms"
has "prose does not use up guess slots (third command kept)" "$out" "nslookup example.com"
lacks "still at most 3 guesses" "$out" "host example.com"
err=$(HINT_DEBUG=1 hint short dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: dropped prose shown" "$err" "hint: not a command, dropped: Alternatively, you can use:"

printf '%s\n' '```' '```' > "$reply"
out=$(hint zzqq frobnicate 2>&1)
has "nothing left after cleaning: asks to rephrase" "$out" \
  "Sorry, I didn't understand your question, can you rephrase it?"

out=$(OLLAMA_HOST=127.0.0.1:1 hint dns lookup 2>&1)
status "Ollama unreachable: exit 1" 1 $?
has "Ollama unreachable: says it cannot connect" "$out" \
  "hint: cannot connect to Ollama at http://127.0.0.1:1 (is it running?)"
lacks "Ollama unreachable: no rephrase message" "$out" "rephrase"

printf '%s\n' '!error model "nosuch" not found, try pulling it first' > "$reply"
out=$(HINT_MODEL=nosuch hint dns lookup 2>&1)
status "Ollama error: exit 1" 1 $?
has "Ollama error: shows Ollama's message" "$out" \
  "returned an error (model nosuch): model \"nosuch\" not found, try pulling it first"

echo "== hint history and hint grep (query log)"
flog="$fix/queries.jsonl"   # 12 synthetic entries on lines 1-3, 5-13; line 4 is damaged
H() { HINTDB_LOG="$flog" OLLAMA_HOST=127.0.0.1:1 hint "$@"; }   # no model reachable

# history: lists, like bash history.
out=$(H history 2>&1)
status "history alone: exit 0" 0 $?
has "history alone: the last 10 lookups, like bash history" "$(wc -l <<<"$out")" "10"
line "history alone: newest last" "$out" 10 "   13  2026-11-12 09:00  remove old host key"
lacks "history alone: damaged log line skipped" "$out" "not json"
out=$(H history 2 2>&1)
status "history N: exit 0" 0 $?
has "history N: last N lookups" "$(wc -l <<<"$out")" "2"
line "history N: oldest first, newest last" "$out" 2 "   13  2026-11-12 09:00  remove old host key"
has "history N: more than there are" "$(H history 50 2>&1 | wc -l)" "12"
out=$(H history ssh 2>&1)
status "history WORD: not a search, exit 2" 2 $?
has "history WORD: points to grep" "$out" 'hint: history takes a number; to find past lookups with "ssh":  hint grep ssh'
for a in "-n 3" "-c" "--last 3" "--bogus"; do
  H history $a >/dev/null 2>&1
  status "history with an option it does not take ($a): exit 2" 2 $?
done
out=$(HINTDB_LOG="$tmp/none.jsonl" hint history 2>&1)
status "history, no log yet: exit 1" 1 $?
has "history, no log yet: says so" "$out" "hint: no past lookups yet"
out=$(H help 2>&1)
has "usage: history" "$out" "hint history [N]"
has "usage: --show" "$out" "hint history --show NUM"
has "usage: --delete" "$out" "hint history --delete NUM[,NUM|NUM-NUM]..."
has "usage: grep" "$out" "hint grep [-c] WORD"
has "usage: how to give several words" "$out" 'For several words, quote them:  hint grep "ssh key"'
has "usage: says a second unquoted word makes a question" "$out" \
  "Unquoted, a second word makes the line a question for the model instead:"
lacks "usage: no search form" "$out" "hint search"
lacks "usage: no -n option" "$out" "--last"

# grep: the lookups whose question or printed commands contain the word.
out=$(H grep registry 2>&1)
status "grep WORD: exit 0 without a model" 0 $?
line "grep WORD: number, time, question" "$out" 1 "    1  2026-11-01 09:00  start the local registry"
out=$(H grep ssh 2>&1)
has "grep: case-insensitive" "$out" "    2  2026-11-02 09:00  SSH tunnel to postgres"
has "grep: numbers skip the damaged line" "$out" "   12  2026-11-11 09:00  ssh with a key"
has "grep: a lookup found by a command it printed" "$out" "   13  2026-11-12 09:00  remove old host key"
has "grep: the matching command shown under its lookup" "$out" \
  "$(printf '%s\n' '   13  2026-11-12 09:00  remove old host key' '         ssh-keygen -R oldhost.example.org')"
has "grep: three lookups, each with its matching command" "$(grep -c '^ \{9\}ssh' <<<"$out")" "3"
has "grep: matches inside words (substring)" "$(H grep frob 2>&1)" "zzqq frobnicate"
out=$(H grep keygen 2>&1)
status "grep: a word only in a printed command finds the lookup (exit 0)" 0 $?
line "grep: question line, then the command" "$out" 2 "         ssh-keygen -R oldhost.example.org"
has "grep: a number is a word" "$(H grep 5432 2>&1)" "         ssh -N -L 5432:localhost:5432 db.example.org"
has "grep: matches a command's note" "$(H grep registry-up 2>&1)" "         docker run -d -p 5000:5000 registry:3"
lacks "grep: a match in the question only shows no command" "$(H grep frobnicate 2>&1)" "         "
out=$(H grep history 2>&1)
status "grep: status labels (your history, your notes) do not match" 1 $?
out=$(H grep zzzz 2>&1)
status "grep: no match: exit 1" 1 $?
has "grep: no match says how to ask instead" "$out" \
  'hint: no past lookups contain "zzzz"; to ask it as a question, add a word'
has "grep: every match, not only the last 10" \
  "$(H grep 2026 2>&1 | grep -c '^ *[0-9]')" "0"
has "grep: all lookups when all match" "$(H grep e 2>&1 | grep -c '^ \{3,4\}[0-9]')" "12"
dlog="$tmp/dup.jsonl"
printf '%s\n' \
  '{"time": "2026-11-01T09:00:00", "query": "list containers", "printed": ["docker ps -a", "  # your history x9"]}' \
  '{"time": "2026-11-02T09:00:00", "query": "a long command", "printed": ["rsync -e \"ssh -i ~/.ssh/id_ed25519.lab -o IdentitiesOnly=yes\" --archive --delete u@build2.example.org:/srv/data/ /home/user/backup/build2/", "  # your history x2"]}' \
  '{"time": "2026-11-03T09:00:00", "query": "show all containers", "printed": ["docker ps -a", "  # model suggestion", "docker ps -a", "  # model suggestion"]}' > "$dlog"
out=$(HINTDB_LOG="$dlog" hint grep docker 2>&1)
has "grep: a command is shown under each lookup that printed it" "$(grep -c 'docker ps -a' <<<"$out")" "2"
line "grep: printed twice in one lookup, shown once" "$out" 4 "         docker ps -a"
has "grep: long commands not truncated" "$(HINTDB_LOG="$dlog" hint grep rsync 2>&1)" \
  "/home/user/backup/build2/"

# --show: one full entry.
out=$(H history --show 2 2>&1)
status "--show NUM: exit 0" 0 $?
line "--show NUM: header" "$out" 1 "    2  2026-11-02 09:00  SSH tunnel to postgres"
line "--show NUM: printed lines indented" "$out" 2 "  ssh -N -L 5432:localhost:5432 db.example.org"
line "--show NUM: status lines as shown" "$out" 3 "    # your history x1: tunnel to postgres"
has "-s NUM" "$(H history -s 1 2>&1)" "  docker run -d -p 5000:5000 registry:3"
has "--show=NUM" "$(H history --show=1 2>&1)" "start the local registry"
has "--show: nothing found shown" "$(H history --show 3 2>&1)" "  (nothing found)"
out=$(H history --show 4 2>&1)
status "--show on a damaged line: exit 1" 1 $?
has "--show: no such entry" "$out" "hintdb: no entry 4 in the query log"
has "--show: past the end" "$(H history --show 99 2>&1)" "hintdb: no entry 99 in the query log"
for a in "ssh --show 2" "--show 2 -c" "5 --show 2" "--show" "--show x"; do
  H history $a >/dev/null 2>&1
  status "--show with other things or no number ($a): exit 2" 2 $?
done

# --show lists each of the user's rows with its source files.
slog="$tmp/src.jsonl"
HINTDB_LOG="$slog" hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" >/dev/null 2>&1
HINTDB_LOG="$slog" hintdb find -q "list jobs" "fakesched -Nel" >/dev/null 2>&1
out=$(HOME=/nonexistent HINTDB_LOG="$slog" hint history --show 1 2>&1)
line "--show: the row's source after its status line" "$out" 4 "    # from $fix/history"
if [ "$(sed -n 3p <<<"$out" | cut -c1-17)" = "    # your histor" ]; then ok "--show: status line first, then the source"
else bad "--show: status line first, then the source" "$out"; fi
has "--show: one source line per row" "$(grep -c '# from ' <<<"$out")" "3"
out=$(HOME="$root" HINTDB_LOG="$slog" hint history --show 1 2>&1)
has "--show: home shown as ~" "$out" "    # from ~/tests/fixtures/history"
out=$(HOME=/nonexistent HINTDB_LOG="$slog" hint history --show 2 2>&1)
line "--show: an uninstalled row's source under it" "$out" 4 "  #     from $fix/notes/cluster.md"
printf '%s\n' '{"time": "2026-11-01T09:00:00", "query": "q", "printed": ["dig +short example.org", "  # model suggestion"], "rows": []}' > "$tmp/nosrc.jsonl"
lacks "--show: model suggestions get no source line" "$(HINTDB_LOG="$tmp/nosrc.jsonl" hint history --show 1 2>&1)" "# from"

# --delete: blank entries in a copy of the log; the others keep their numbers.
cp "$flog" "$tmp/del.jsonl"
D() { HINTDB_LOG="$tmp/del.jsonl" OLLAMA_HOST=127.0.0.1:1 hint "$@"; }
out=$(D history -d 2 2>&1)
status "--delete NUM: exit 0" 0 $?
line "--delete NUM: says what was deleted" "$out" 1 "deleted     2  2026-11-02 09:00  SSH tunnel to postgres"
lacks "--delete NUM: gone from history" "$(D history 20 2>&1)" "SSH tunnel to postgres"
has "--delete: other entries keep their numbers" "$(D history 20 2>&1)" "   12  2026-11-11 09:00  ssh with a key"
has "--delete: the file keeps its line count" "$(wc -l <"$tmp/del.jsonl")" "13"
has "--delete: --show of a deleted entry" "$(D history --show 2 2>&1)" "hintdb: no entry 2 in the query log"
lacks "--delete: its commands are gone too" "$(D grep postgres 2>&1)" "db.example.org"
out=$(D history -d 2 2>&1)
status "--delete of a deleted entry: exit 1" 1 $?
has "--delete of a deleted entry: message" "$out" "hintdb: no entry 2 in the query log; nothing deleted"
cp "$tmp/del.jsonl" "$tmp/del.before"
out=$(D history --delete 5,99 2>&1)
status "--delete with one missing NUM: exit 1" 1 $?
has "--delete with one missing NUM: names it" "$out" "no entry 99 in the query log; nothing deleted"
if cmp -s "$tmp/del.jsonl" "$tmp/del.before"; then ok "--delete with one missing NUM: nothing deleted"
else bad "--delete with one missing NUM: nothing deleted"; fi
out=$(D history --delete=1,5-7 2>&1)
has "--delete list and range: all deleted" "$(grep -c '^deleted' <<<"$out")" "4"
out=$(D history --delete 3-5 2>&1)
has "--delete range: only the entries in it (4 damaged, 5 gone)" "$out" "deleted     3"
has "--delete range: one entry deleted" "$(grep -c '^deleted' <<<"$out")" "1"
has "--delete: the rest" "$(D history 20 2>&1 | wc -l)" "6"
for a in "history ssh -d 8" "history 2 -d 8" "history -d 8 -c" "history -d 8 -s 8" \
         "history -d" "history -d x" "history -d 8,,9"; do
  D $a >/dev/null 2>&1
  status "--delete with other things, or no or bad NUM ($a): exit 2" 2 $?
done
has "--delete with nothing changed by the refused calls" "$(D history 20 2>&1 | wc -l)" "6"
HINTDB_LOG="$tmp/del.jsonl" hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" >/dev/null 2>&1
has "a lookup after a delete is appended as the next line" \
  "$(D history 1 2>&1)" "   14  "
if command -v flock >/dev/null; then
  flock "$tmp/del.jsonl" sleep 1 &
  lock_pid=$!
  sleep 0.2
  t0=$(date +%s%N)
  HINTDB_LOG="$tmp/del.jsonl" hintdb find -q "disk usage of directory contents" "du -sh /tmp/x" >/dev/null 2>&1
  t1=$(date +%s%N)
  wait "$lock_pid"
  if [ $(( (t1 - t0) / 1000000 )) -ge 500 ]; then ok "a lookup waits for the log lock instead of writing during a delete"
  else bad "a lookup waits for the log lock instead of writing during a delete" "waited $(( (t1 - t0) / 1000000 )) ms"; fi
  has "the lookup that waited is in the log" "$(D history 1 2>&1)" "   15  "
fi

# grep: several words quoted, one argument; all of them must match.
out=$(H grep "ssh key" 2>&1)
status "grep \"two words\": exit 0" 0 $?
has "grep \"two words\": all words, anywhere in the question" "$out" "ssh with a key"
has "grep \"two words\": or in a command" "$out" "         ssh -i ~/.ssh/key user@build2.example.org"
lacks "grep \"two words\": not a lookup with only one of them" "$out" "SSH tunnel to postgres"
has "grep -c: counts lookups" "$(H grep -c ssh 2>&1)" "3"
has "grep WORD -c: option after the word" "$(H grep ssh --count 2>&1)" "3"
out=$(H grep --count zzzz 2>&1)
status "grep -c with no match: exit 1" 1 $?
line "grep -c with no match: prints 0 only" "$out" 1 "0"
for a in "" "-c" "--bogus ssh"; do
  H grep $a >/dev/null 2>&1
  status "grep without a word, or with an unknown option ($a): usage, exit 2" 2 $?
done
has "grep with an unknown option: usage shown" "$(H grep ssh -x 2>&1)" "usage: hint"

printf '%s\n' 'fc -ln -10' > "$reply"
hint history postgres docker >/dev/null 2>&1
has "history + two plain words is a question" "$(jq -r '.messages[-1].content' <"$tmp/request")" \
  "history postgres docker"
hint history without the -a flag >/dev/null 2>&1
has "history + words + an unknown dash word is a question, not usage" \
  "$(jq -r '.messages[-1].content' <"$tmp/request")" "history without the -a flag"
out=$(hint history without duplicates 2>&1)
has "history + more words is a question" "$(jq -r '.messages[-1].content' <"$tmp/request")" \
  "history without duplicates"
lacks "history + more words: no usage" "$out" "usage: hint"
hint grep recursively for a word >/dev/null 2>&1
has "grep + more words is a question" "$(jq -r '.messages[-1].content' <"$tmp/request")" \
  "grep recursively for a word"
hint search docker >/dev/null 2>&1
has "search is not a command: a question" "$(jq -r '.messages[-1].content' <"$tmp/request")" \
  "search docker"
hint -H ssh >/dev/null 2>&1
has "-H is not an option: a question, like any first word" \
  "$(jq -r '.messages[-1].content' <"$tmp/request")" "-H ssh"
: > "$HINTDB_LOG"
hint short dns lookup >/dev/null 2>&1
has "a lookup can be found again with grep" "$(hint grep dns 2>&1)" "short dns lookup"

echo "== hint remember"
# Its own history file and log, so the mtime check and the lines are known.
ah="$tmp/answer-history" alog="$tmp/answer-log.jsonl" ans="$tmp/answers"
printf '%s\n' 'du -sh /srv/current' 'sudo /usr/sbin/fakess -ltnp sport = 8080' \
  "sudo /usr/sbin/fakess -ltnp 'sport = :8080'  # my own note" 'ps aux | grep nginx' \
  'cd /etc' '#1700000000' 'history -a' 'history -d 12' 'history -a; hint remember' > "$ah"
printf '%s\n' '{"time": "2026-11-01T09:00:00", "query": "older question", "printed": []}' \
  '{"time": "2026-11-02T09:00:00", "query": "who is listening on port 8080", "printed": []}' > "$alog"
A() { HISTFILE="$ah" HINTDB_LOG="$alog" "$@"; }

out=$(A hintdb remember 2>&1)
line "remember: the last question, with its number; not in history: newest" "$out" 1 \
  "$(printf '2\twho is listening on port 8080\tnewest')"
line "remember: last command, skipping hint, history housekeeping and trivial lines" "$out" 2 \
  "ps aux | grep nginx"
out=$(A hintdb remember fakess 2>&1)
line "remember TOOL: newest line with that tool (sudo and path skipped), comment dropped" "$out" 2 \
  "sudo /usr/sbin/fakess -ltnp 'sport = :8080'"
line "remember TOOL: any command in a pipeline counts" "$(A hintdb remember grep 2>&1)" 2 "ps aux | grep nginx"
line "remember history: history lines found when named, the hint line still skipped" \
  "$(A hintdb remember history 2>&1)" 2 "history -d 12"
line "remember: a ; with no space still splits the line" \
  "$(printf '%s\n' 'du -sh /srv/current' 'history -a;hint remember' > "$tmp/h2"; HISTFILE="$tmp/h2" HINTDB_LOG="$alog" hintdb remember 2>&1)" 2 \
  "du -sh /srv/current"
line "remember: a quoted ; is not a separator" \
  "$(printf '%s\n' "fakess -x 'a;hint'" > "$tmp/h3"; HISTFILE="$tmp/h3" HINTDB_LOG="$alog" hintdb remember 2>&1)" 2 \
  "fakess -x 'a;hint'"
line "remember cd: trivial lines found when named" "$(A hintdb remember cd 2>&1)" 2 "cd /etc"
out=$(A hintdb remember zzqq 2>&1)
status "remember TOOL not in history: exit 1" 1 $?
has "remember TOOL not in history: says so" "$out" "no zzqq command found in"

out=$(HISTFILE="$tmp/no-such-history" HINTDB_LOG="$alog" hintdb remember 2>&1)
status "remember: missing history file: exit 1" 1 $?
has "remember: missing history file: says to export HISTFILE" "$out" "export HISTFILE"
out=$(HISTFILE="$ah" HINTDB_LOG="$tmp/no-such-log" hintdb remember 2>&1)
status "remember: no question yet: exit 1" 1 $?
has "remember: no question yet: says so" "$out" "no question to answer yet"
printf '%s\n' '{"time": "2099-01-01T09:00:00", "query": "asked after the last write", "printed": []}' > "$tmp/future-log"
out=$(HISTFILE="$ah" HINTDB_LOG="$tmp/future-log" hint remember fakess 2>&1 </dev/null)
status "remember: history not written since the question: exit 1" 1 $?
has "remember: history not written since the question: says what to run" "$out" \
  "run:  history -a; hint remember fakess"
lacks "remember: history not written: no prompt" "$out" "answer to"
out=$(HINTDB_ANSWERS=/dev/null A hintdb remember 2>&1)
status "remember: HINTDB_ANSWERS=/dev/null turns it off" 1 $?
has "remember: off says so" "$out" "answers are off"

rm -f "$ans"
out=$(printf '\n' | A hint remember fakess 2>&1)
status "hint remember: empty line cancels (exit 1)" 1 $?
has "hint remember: cancel says nothing saved" "$out" "cancelled, nothing saved"
[ -e "$ans" ] && bad "hint remember: cancel writes no file" || ok "hint remember: cancel writes no file"
out=$(A hint remember fakess 2>&1 <<<"sudo fakess -ltnp 'sport = :8080'")
status "hint remember: edited line saved (exit 0)" 0 $?
has "hint remember: prompt shows the question" "$out" 'remember as the answer to "who is listening on port 8080" (lookup 2):'
has "hint remember: prompt shows the command" "$out" "> sudo /usr/sbin/fakess -ltnp 'sport = :8080'"
has "hint remember: says the keys" "$out" "  Enter saves, Ctrl-C cancels. Not this line? Edit it."
lacks "hint remember TOOL: no hint to name a tool" "$out" "name its tool"
has "hint remember: without TOOL, says how to name one" \
  "$(printf '\n' | A hint remember 2>&1)" "Not this line? Edit it, or name its tool: hint remember TOOL."
has "hint remember: says where it was saved" "$out" "saved to"
line "hint remember: the line as edited, with the question as its comment" "$(cat "$ans")" 1 \
  "sudo fakess -ltnp 'sport = :8080'  # who is listening on port 8080"
has "hint remember: file mode 600" "$(stat -c %a "$ans")" "600"
printf '%s\n' '{"time": "2026-11-03T09:00:00", "query": "space used by the current release", "printed": []}' >> "$alog"
A hint remember du >/dev/null 2>&1 <<<"du -sh /srv/current"
has "hint remember: answers are appended" "$(wc -l <"$ans")" "2"
line "hint remember: each answer goes with the last question" "$(cat "$ans")" 2 \
  "du -sh /srv/current  # space used by the current release"

out=$(hint remember -x 2>&1)
status "hint remember -x: usage, exit 2" 2 $?
printf '%s\n' 'yes | fakedock prune' > "$reply"
hint remember my ssh key passphrase >/dev/null 2>&1
has "remember + more words is a question" "$(jq -r '.messages[-1].content' <"$tmp/request")" \
  "remember my ssh key passphrase"

# In the index: built in, read as history, merged with the row of the same shape.
has "sources: answers file listed as built in" "$(hintdb sources)" "$ans	(built in: hint remember)"
has "sources: no answers yet" "$(HINTDB_ANSWERS="$tmp/none" hintdb sources)" "no answers yet"
lacks "sources: answers off: not listed" "$(HINTDB_ANSWERS=/dev/null hintdb sources)" "built in: hint remember"
has "sources: wrong file listed as built in" "$(hintdb sources)" "$tmp/wrong	(built in: hint forget, nothing marked yet)"
lacks "sources: marks off: not listed" "$(HINTDB_WRONG=/dev/null hintdb sources)" "built in: hint forget"
out=$(HINTDB_DB="$tmp/answer.db" hintdb find -q "space used by the current release" "df -h" 2>/dev/null)
line "remembered row found by the question's words" "$out" 1 "du -sh /srv/current"
line "remembered row: merged with the history row, the question as its note" "$out" 2 \
  "  # your history x2: space used by the current release"
out=$(HINTDB_DB="$tmp/answer.db" hintdb find -q "who is listening on port 8080" "netstat -tulpn" 2>/dev/null)
has "remembered command found despite the wrong guessed tool" "$out" "sudo fakess -ltnp 'sport = :8080'"
has "remembered command not on PATH is kept (it has a note)" "$out" "# your history x1: who is listening on port 8080"

echo "== hint forget"
# Its own sources: a reference history and a notes file; the live history
# is not registered (forget still looks in it); the answers file is built in.
fh="$tmp/forget-history" fold="$tmp/forget-old-history" fnotes="$tmp/forget-notes.md"
printf '%s\n' 'echo keep' 'history -n 10' "fakess -l  'x'  # spaced" 'history -n 10  # again' \
  'history -n' 'history -a; hint forget' > "$fh"
printf '%s\n' 'echo old' 'history -n 10' > "$fold"
printf '%s\n' '# Shell' '' '```bash' '$ history -n 10' '```' > "$fnotes"
printf '%s\n' 'history -n 10  # show the last ten' > "$tmp/forget-answers"
printf 'history\t%s\nauto\t%s\n' "$fold" "$fnotes" > "$tmp/forget-sources"
F() { HISTFILE="$fh" HINTDB_LOG="$tmp/no-such-log" HINTDB_SOURCES="$tmp/forget-sources" \
      HINTDB_ANSWERS="$tmp/forget-answers" HINTDB_WRONG="$tmp/forget-wrong" HINTDB_DB="$tmp/forget.db" "$@"; }
sums() { md5sum "$fh" "$fold" "$fnotes" "$tmp/forget-answers"; }
before=$(sums)

has "forget: last command, skipping hint and history lines" "$(F hintdb forget 2>&1)" "fakess -l  'x'"
has "forget TOOL: newest line with that tool" "$(F hintdb forget history 2>&1)" "history -n"
out=$(F hintdb forget --where -- 'history -n 10' 2>&1)
status "forget --where: found, exit 0" 0 $?
line "forget --where: names the command" "$out" 1 "history -n 10 is in:"
line "forget --where: live history first, comment ignored, not the shorter line" "$(tr -s ' ' <<<"$out")" 2 " $fh lines 2, 4"
has "forget --where: a reference history" "$(tr -s ' ' <<<"$out")" "$fold line 2"
has "forget --where: a notes file, by contained text" "$(tr -s ' ' <<<"$out")" "$fnotes line 4"
has "forget --where: the answers file" "$(tr -s ' ' <<<"$out")" "$tmp/forget-answers line 1"
out=$(F hintdb forget --where -- "fakess -l 'x'" 2>&1)
has "forget --where: runs of spaces as one" "$out" "$fh  line 3"
printf '%s\n' 'echo other' > "$tmp/other-history"
out=$(HISTFILE="$tmp/other-history" HINTDB_LOG="$tmp/no-such-log" HINTDB_SOURCES="$tmp/forget-sources" \
      HINTDB_ANSWERS="$tmp/forget-answers" HINTDB_DB="$tmp/forget.db" hintdb forget --where -- 'history -n 10' 2>&1)
has "forget --where: other files listed" "$out" "$fold"
out=$(F hintdb forget --where -- 'zzqq --nothing' 2>&1)
status "forget --where: not found: exit 1" 1 $?
has "forget --where: not found: says so" "$out" "is in none of your sources or your history file"
out=$(HINTDB_LOG="$tmp/future-log" HISTFILE="$fh" HINTDB_SOURCES="$tmp/forget-sources" hint forget fakess 2>&1 </dev/null)
status "forget TOOL: history not written since the last lookup: exit 1" 1 $?
has "forget TOOL: stale history says what to run" "$out" "run:  history -a; hint forget fakess"

fw="$tmp/forget-wrong"
out=$(F hint forget history 2>&1 <<<$'history -n 10\n-n takes no count')
status "hint forget: exit 0" 0 $?
has "hint forget: asks which command" "$out" "which command?"
has "hint forget: says the keys" "$out" "  Enter marks it WRONG, Ctrl-C cancels. Not this line? Edit it."
has "hint forget: without TOOL, says how to name one" \
  "$(printf '\n' | F hint forget 2>&1)" "or name its tool: hint forget TOOL."
has "hint forget: offers the newest line" "$out" "> history -n"
has "hint forget: asks for a reason" "$out" "reason (optional, Enter for none):"
has "hint forget: says what it saved" "$out" "saved: history -n 10  # WRONG: -n takes no count"
line "hint forget: the mark, with the reason, in the wrong file" "$(cat "$fw")" 1 \
  "history -n 10  # WRONG: -n takes no count"
has "hint forget: wrong file mode 600" "$(stat -c %a "$fw")" "600"
has "hint forget: says where it still is" "$out" "hint now hides it. It is still in your history (up-arrow, Ctrl-R):"
line "hint forget: live history first, one file per line" "$(grep -A1 'still in' <<<"$out" | tr -s ' ')" 2 " $fh lines 2, 4"
has "hint forget: live history: the README" "$out" \
  "Delete those lines to clean it up there too; see the README for editing history safely."
lacks "hint forget: the new mark is not listed as a copy" "$out" "$fw"
lacks "hint forget: the index no longer has it" "$(F hintdb query -n 30 history 2>&1)" "history -n 10"
out=$(F hint forget history 2>&1 <<<$'history -n 10\nagain')
status "hint forget: already marked: exit 0" 0 $?
has "hint forget: already marked: says where" "$out" "history -n 10 is already marked WRONG: $fw line 1"
lacks "hint forget: already marked: no reason asked" "$out" "reason (optional"
has "hint forget: already marked: nothing saved" "$(wc -l <"$fw")" "1"
out=$(F hint forget fakess 2>&1 <<<$'fakess -l \'x\'\n')
line "hint forget: no reason: a bare WRONG!" "$(cat "$fw")" 2 "fakess -l 'x'  # WRONG!"
has "hint forget: copies found with runs of spaces as one" "$(tr -s ' ' <<<"$out")" " $fh line 3"
out=$(F hint forget fakess 2>&1 <<<$'zzqq --nowhere\n')
line "hint forget: no copies anywhere: two lines" "$(grep -v '^which\|^  Enter\|^> \|^reason' <<<"$out")" 2 \
  "hint now hides it."
out=$(F env HINTDB_WRONG=/dev/null hint forget fakess 2>&1 <<<$'fakess -z\n')
status "hint forget: marks off: exit 1" 1 $?
has "hint forget: marks off: says so" "$out" "marks are off (HINTDB_WRONG=/dev/null)"
lacks "hint forget: marks off: says so before any prompt" "$out" "which command?"
n=$(wc -l <"$fw")
out=$(printf '\n' | F hint forget 2>&1)
status "hint forget: empty line cancels (exit 1)" 1 $?
has "hint forget: cancel says nothing saved" "$out" "cancelled, nothing saved"
has "hint forget: cancel: wrong file unchanged" "$(wc -l <"$fw")" "$n"
if [ "$(sums)" = "$before" ]; then ok "hint forget: no file changed"; else bad "hint forget: no file changed" "$(sums)"; fi
out=$(hint forget -x 2>&1)
status "hint forget -x: usage, exit 2" 2 $?
has "usage: forget" "$(hint help 2>&1)" "hint forget [TOOL]"
printf '%s\n' 'nmcli connection delete home' > "$reply"
hint forget a wifi network >/dev/null 2>&1
has "forget + more words is a question" "$(jq -r '.messages[-1].content' <"$tmp/request")" \
  "forget a wifi network"

echo "== remember and forget after the question"
# The question is in the history: only the lines after it count. forget
# takes the first (the suggestion tried), answer the last (what worked).
qh="$tmp/question-history" qlog="$tmp/question-log.jsonl"
printf '%s\n' 'fakess -x old' 'hint show me the last history items' 'history -n 10' 'man history' \
  'fc -ln -10' 'history --help' 'hint forget' > "$qh"
printf '%s\n' '{"time": "2026-11-02T09:00:00", "query": "show me the last history items", "printed": []}' > "$qlog"
Q() { HISTFILE="$qh" HINTDB_LOG="$qlog" HINTDB_SOURCES="$tmp/forget-sources" \
      HINTDB_ANSWERS="$tmp/forget-answers" HINTDB_DB="$tmp/forget.db" "$@"; }
out=$(Q hintdb forget 2>&1)
line "forget: found the question" "$out" 1 "$(printf '1\tshow me the last history items\tafter')"
line "forget: the first line after the question (history lines count now)" "$out" 2 "history -n 10"
line "forget TOOL: the first TOOL line after the question" "$(Q hintdb forget history 2>&1)" 2 "history -n 10"
line "forget TOOL: another tool" "$(Q hintdb forget fc 2>&1)" 2 "fc -ln -10"
line "remember: the last line after the question, trivial ones skipped" "$(Q hintdb remember 2>&1)" 2 "fc -ln -10"
line "remember TOOL: the last TOOL line after the question" "$(Q hintdb remember history 2>&1)" 2 "history --help"
out=$(Q hintdb forget fakess 2>&1)
status "forget TOOL only before the question: exit 1" 1 $?
has "forget TOOL only before the question: not looked for there" "$out" \
  'no fakess command since you asked "show me the last history items"'
printf '%s\n' 'echo before' 'hint show me the last history items' > "$tmp/q-only"
out=$(HISTFILE="$tmp/q-only" HINTDB_LOG="$qlog" hintdb remember 2>&1)
status "remember: nothing run since the question: exit 1" 1 $?
has "remember: nothing run since the question: says so" "$out" "no command since you asked"
printf '%s\n' "hint 'what is' \"the  thing\"" 'fakess -q' > "$tmp/q-quoted"
printf '%s\n' '{"time": "2026-11-02T09:00:00", "query": "what is the  thing", "printed": []}' > "$tmp/q-quoted-log"
line "the question found through the shell's quoting" \
  "$(HISTFILE="$tmp/q-quoted" HINTDB_LOG="$tmp/q-quoted-log" hintdb forget 2>&1)" 1 \
  "$(printf '1\twhat is the  thing\tafter')"
line "the last asking of the question counts" \
  "$(printf '%s\n' 'hint show me the last history items' 'fakess -a' 'hint show me the last history items' 'fakess -b' > "$tmp/q-twice"; \
     HISTFILE="$tmp/q-twice" HINTDB_LOG="$qlog" hintdb forget 2>&1)" 2 "fakess -b"
printf '%s\n' 'hint show me the last history items' 'history 10' 'vim ~/.bash_history' 'hint remember' > "$tmp/q-trivial"
out=$(HISTFILE="$tmp/q-trivial" HINTDB_LOG="$qlog" hintdb remember 2>&1)
status "remember: only trivial lines since the question: exit 1" 1 $?
has "remember: only trivial lines: says so" "$out" 'only trivial commands since you asked "show me the last history items";'
has "remember: only trivial lines: each with the command that takes it, in order" "$out" \
  "$(printf '  history 10            hint remember history\n  vim ~/.bash_history   hint remember vim')"
has "forget TOOL: only lines of another tool after the question: not found there" \
  "$(HISTFILE="$tmp/q-trivial" HINTDB_LOG="$qlog" hintdb forget fakess 2>&1)" "no fakess command since you asked"
line "remember TOOL: a trivial line found when its tool is named" \
  "$(HISTFILE="$tmp/q-trivial" HINTDB_LOG="$qlog" hintdb remember history 2>&1)" 2 "history 10"
out=$(Q hint forget 2>&1 </dev/null)
has "hint forget: says it starts after the question" "$out" \
  'which command? the first after "show me the last history items" (lookup 1):'
out=$(printf '\n' | F hint forget 2>&1)
lacks "hint forget: no question in the log, no note" "$out" "not in your history file"
out=$(printf '\n' | A hint remember 2>&1)
has "hint remember: question not in history: says the newest is offered" "$out" \
  "(your last question is not in your history file: this is your newest command)"

echo "== WRONG marker"
# Own sources and index: a history with marks and near misses, a notes
# file with a copy of a marked command.
wh="$tmp/wrong-history" wn="$tmp/wrong-notes.md"
printf '%s\n' 'fakess -n 10' 'fakess -n 10  # WRONG!' 'fakess -n' 'fakess -r  # WRONG: -r is not a flag' \
  'fakess -b  # WRONG' 'fakess -p  # WRONG permissions fixed' 'fakess -w  # Wrong!' \
  'fakess -z  # WRONGLY named' 'fakess -q  # fix wrong permissions' 'fakess -n   10' > "$wh"
printf '%s\n' '# Sockets' '' '```bash' 'fakess -n 10' 'fakess -l' '```' > "$wn"
printf 'history\t%s\nauto\t%s\n' "$wh" "$wn" > "$tmp/wrong-sources"
W() { HISTFILE="$wh" HINTDB_LOG="$tmp/no-such-log" HINTDB_SOURCES="$tmp/wrong-sources" \
      HINTDB_ANSWERS="$tmp/none" HINTDB_DB="$tmp/wrong.db" HINTDB_NO_MAN=1 "$@"; }
W hintdb rebuild >/dev/null
widx=$(python3 - "$tmp/wrong.db" <<'EOF2'
import sqlite3, sys
for (v,) in sqlite3.connect(sys.argv[1]).execute("SELECT display FROM entries"):
    print(v)
EOF2
)
lacks "WRONG!: the command is not indexed" "$widx" "fakess -n 10"
lacks "WRONG: reason: not indexed" "$widx" "fakess -r"
lacks "bare WRONG: not indexed" "$widx" "fakess -b"
lacks "WRONG then a word: still a mark" "$widx" "fakess -p"
has "another command of the same tool stays" "$widx" "fakess -n"
has "Wrong! (not capitals) is a note, not a mark" "$widx" "fakess -w"
has "WRONGLY (not a whole word) is a note, not a mark" "$widx" "fakess -z"
has "wrong later in the comment is a note, not a mark" "$widx" "fakess -q"
has "the notes file's other command stays" "$widx" "fakess -l"
out=$(W hintdb stats 2>&1)
has "stats: lists marked commands" "$out" "marked WRONG (never shown by hint):"
has "stats: each mark with file, line and comment" "$(tr -s ' ' <<<"$out")" " fakess -r $wh line 4: WRONG: -r is not a flag"

out=$(W hintdb forget --where -- 'fakess -n 10' 2>&1)
has "forget --where: says the command is already marked, and where" "$out" \
  "fakess -n 10 is already marked WRONG: $wh line 2"
has "forget: lists the unmarked copies (spaces as one), not the marked line" "$(tr -s ' ' <<<"$out")" " $wh lines 1, 10"
has "forget: the notes copy is listed" "$(tr -s ' ' <<<"$out")" " $wn line 4"
has "forget --where: already marked: the unmarked copies under their own heading" "$out" "Unmarked copies:"
out=$(W hintdb forget --where -- 'fakess -l' 2>&1)
has "forget --where: only in a notes file" "$(tr -s ' ' <<<"$out")" " $wn line 5"
sed -i 's/  # WRONG!$//' "$wh"
has "removing the mark brings the command back" "$(W hintdb query -n 30 fakess 2>&1)" "fakess -n 10"

# A model guess the user marked WRONG: labelled, and printed after the others.
printf '%s\n' 'fakess -b  # WRONG' 'fakess -n 10' 'fakess -n 10  # WRONG: -n takes no count' > "$tmp/wrong-history2"
printf 'history\t%s\n' "$tmp/wrong-history2" > "$tmp/wrong-sources2"
W2() { HINTDB_SOURCES="$tmp/wrong-sources2" HINTDB_ANSWERS="$tmp/none" HINTDB_DB="$tmp/wrong2.db" \
       HINTDB_NO_MAN=1 HINTDB_LOG=/dev/null "$@"; }
out=$(W2 hintdb find -q "list sockets" "fakess -n 10" "fakess -l" 2>&1)
line "marked guess: not first" "$out" 1 "fakess -l"
line "marked guess: after the other guesses" "$out" 3 "fakess -n 10"
line "marked guess: labelled with the user's mark" "$out" 4 \
  "  # WRONG: -n takes no count (model suggestion, marked by you)"
has "marked guess: shown in --debug" "$(W2 hintdb find --debug -q "list sockets" "fakess -n 10" 2>&1 >/dev/null)" \
  "marked WRONG by the user, printed last: fakess -n 10"
has "marked guess: a bare mark is shown as WRONG" "$(W2 hintdb find -q "list sockets" "fakess -b" 2>&1)" \
  "  # WRONG (model suggestion, marked by you)"
printf '%s\n' 'zzqqtool -x  # WRONG!' >> "$tmp/wrong-history2"
has "marked guess, tool not installed: marked in the model's list" \
  "$(W2 hintdb find -q "frobnicate the widget" "zzqqtool -x" 2>&1)" "#   zzqqtool -x   (WRONG!, marked by you)"

echo "== forget from the last lookup's output"
# Nothing run since the question (or only trivial lines): choose from the
# commands the last lookup printed, so a wrong suggestion is marked unrun.
lh="$tmp/list-history" llog="$tmp/list-log.jsonl" lw="$tmp/list-wrong"
printf '%s\n' 'fakess -x old' 'hint show me the last history items' 'man history' > "$lh"
jq -cn '{time: "2026-11-02T09:00:00", query: "show me the last history items", printed: [
  "history 10", "  # your history x1: show last 10 commands",
  "history -n 10", "  # model suggestion",
  "ssh -L 8080:localhost:80 user@<HOST>", "  # your history x2; e.g. ssh -L 8080:localhost:80 user@gpu1.example.org",
  "fc -ln -10", "  # model suggestion",
  "history 10", "  # model suggestion",
  "# see man history(1): GNU History Library",
  "# found in notes.md, but zzqqtool is not installed here:", "#   zzqqtool -l"]}' > "$llog"
printf '%s\n' 'fc -ln -10  # WRONG: already' > "$tmp/list-marked"
printf 'history\t%s\n' "$tmp/list-marked" > "$tmp/list-sources"
L() { HISTFILE="$lh" HINTDB_LOG="$llog" HINTDB_SOURCES="$tmp/list-sources" HINTDB_WRONG="$lw" \
      HINTDB_ANSWERS="$tmp/none" HINTDB_DB="$tmp/list.db" "$@"; }
out=$(L hintdb forget 2>&1)
line "forget list: header with the question" "$out" 1 "$(printf '1\tshow me the last history items\tlist')"
if [ "$(tail -n +2 <<<"$out")" = "$(printf '%s\n' 'history 10' 'history -n 10' 'zzqqtool -l')" ]; then
  ok "forget list: commands in order, once each; no status lines, templates or marked commands"
else bad "forget list: commands in order, once each; no status lines, templates or marked commands" "$out"; fi
out=$(L hint forget 2>&1 <<<$'2\nhistory -n 10\n-n takes no count')
status "hint forget list: exit 0" 0 $?
has "hint forget list: asks from which lookup" "$out" 'which command? from "show me the last history items" (lookup 1):'
has "hint forget list: numbered" "$out" "  2  history -n 10"
has "hint forget list: asks for a number" "$out" "number (Ctrl-C cancels):"
has "hint forget list: then the editable line" "$out" "> history -n 10"
line "hint forget list: saved" "$(cat "$lw")" 1 "history -n 10  # WRONG: -n takes no count"
lacks "hint forget list: the history file is unchanged" "$(cat "$lh")" "history -n 10"
out=$(L hint forget 2>&1 <<<$'9\n')
status "hint forget list: a number not in the list: exit 1" 1 $?
has "hint forget list: says so" "$out" "not a number from the list, nothing saved"
out=$(L hint forget 2>&1 <<<$'\n')
status "hint forget list: empty answer cancels" 1 $?
has "hint forget list: the marked command is left out next time" "$(L hintdb forget 2>&1)" "$(printf 'history 10\nzzqqtool -l')"
printf '%s\n' '{"time": "2099-01-01T09:00:00", "query": "asked on a server", "printed": ["history 10"]}' > "$tmp/list-future"
line "forget list: history not written since the question: the list too" \
  "$(HINTDB_LOG="$tmp/list-future" L env HINTDB_LOG="$tmp/list-future" hintdb forget 2>&1)" 2 "history 10"
printf '%s\n' '{"time": "2026-11-02T09:00:00", "query": "show me the last history items", "printed": []}' > "$tmp/list-empty"
out=$(L env HINTDB_LOG="$tmp/list-empty" hintdb forget 2>&1)
status "forget list: nothing printed: exit 1" 1 $?
has "forget list: nothing printed: says so" "$out" "nothing to mark"

echo "== hint flags"
# Fake man and help pages: GNU (ss), BSD (nc), stacked option lines (psql),
# same-indent continuation (kubectl-get), a subcommand page (git-commit),
# values (sudo -u, head -n), optional values (lsof -i [i]), + options (dig),
# and a builtin (history).
FL() { HINTDB_MAN="$here/fake_doc.sh $fix/man" HINTDB_HELP="$here/fake_doc.sh $fix/help" hint flags "$@"; }

out=$(FL ss -tuln)
status "flags: every flag found: exit 0" 0 $?
line "flags: GNU layout, the flag line as the page writes it" "$out" 1 "ss -t, --tcp        Show TCP sockets."
line "flags: a group is split as getopt does, in the order typed" "$out" 4 \
  "ss -n, --numeric    Show numbers, do not resolve service names."
has "flags: description lines joined" "$out" "Show only listening sockets (these are left out by default)."
lacks "flags: a deeper line starting with the flag is not the entry" "$out" "in an example"
out=$(FL ss --listening)
has "flags: a long flag finds its entry" "$out" "ss -l, --listening  Show only listening sockets"
out=$(FL nc -lv -p 4567)
line "flags: BSD layout (text after a tab), continuation joined" "$out" 2 \
  "                   connection to a remote host."
has "flags: BSD layout, flag with a value" "$out" "nc -p source_port  Use source_port as the source port."
lacks "flags: the value of -p is not looked up" "$out" "4567"
out=$(FL nc -q:a 5 -z)
has "flags: -x:y is looked up as -x; a comma in parentheses is not an item break" "$out" "nc -q[:stream] seconds (input,output)"
has "flags: -x:y's value is not looked up, the next flag is" "$out" "Scan for listening daemons"
lacks "flags: -x:y is not split into letters" "$out" "nc -:"
out=$(FL 'sudo -u postgres psql -c x | grep -r foo')
has "flags: a quoted pipeline: the wrapper's flags" "$out" "sudo -u user, --user=user"
lacks "flags: the wrapper's value is not taken for the command" "$out" "postgres "
has "flags: stacked option lines are one entry" "$out" "psql -c command, --command=command"
has "flags: stacked option lines: the description below them" "$out" "Run the given command string and exit."
has "flags: each command of the pipeline" "$out" "grep -r, --recursive"
out=$(FL sudo -b -u root id)
has "flags: a flag is never taken as another flag's value" "$out" "sudo -u user, --user=user"
out=$(FL sudo grep -r foo)
lacks "flags: a wrapper without flags is skipped" "$out" "sudo"
out=$(FL kubectl get pods -o wide)
has "flags: a subcommand page is read first, shown with the subcommand" "$out" 'kubectl get -o, --output=""'
has "flags: same-indent continuation, joined at a real hyphen" "$out" "(json, yaml, go-template,"
out=$(FL kubectl get --context=x)
has "flags: the tool's own page after the subcommand's" "$out" 'kubectl get --context=""  The kubeconfig context to use.'
out=$(FL git commit -a --amend -m msg)
has "flags: subcommand page" "$out" "git commit --amend"
has "flags: --name=value spec shown" "$out" "git commit -m <msg>, --message=<msg>"
out=$(FL git commit --message=hi)
has "flags: --name=value is looked up as --name" "$out" "Use <msg> as the commit message."
out=$(FL head -n10 file)
line "flags: -n10 is -n with its value" "$out" 1 "head -n, --lines=[-]NUM  print the first NUM lines"
out=$(FL head -n -5 file)
lacks "flags: a value starting with - is not looked up" "$out" "-5"
out=$(FL lsof -i -P +D /tmp)
has "flags: an optional [value] does not take the next word" "$out" "lsof -P      does not convert port numbers"
has "flags: a + option listed on the page" "$out" "lsof +D D    searches for open files"
out=$(FL find . -mtime +30)
lacks "flags: a + word not on the page is not listed" "$out" "+30"
out=$(FL unzip -l -d out a.zip)
has "flags: a bracketed option line, as unzip writes it" "$out" "unzip -d exdir  Extract the files into the directory exdir."
lacks "flags: the bracketed option's value is not looked up" "$out" "unzip out"
has "flags: unzip's plain option lines still found" "$out" "unzip -l        List the archive's files."
out=$(FL dig +short example.org)
has "flags: dig +short" "$out" "dig +short, +noshort  This option toggles a terse answer."
out=$(FL history -n 10)
has "flags: a builtin's help" "$out" "history -n  read all history lines not already read from the history file"
out=$(FL history -x)
has "flags: a flag not in the builtin's help" "$out" "history -x  not in help history"
out=$(FL ss -e)
status "flags: a flag not on the page: exit 1" 1 $?
has "flags: a flag not on the page says so, with the page" "$out" "ss -e  not in ss(8)"
out=$(FL nosuchtool -a)
status "flags: no page: exit 1" 1 $?
has "flags: no page, no help" "$out" "nosuchtool  no man page or builtin help here"
out=$(FL 'ss -t | grep LISTEN')
status "flags: a command with no flags is not a miss: exit 0" 0 $?
line "flags: a command with no flags is listed, not skipped" "$out" 3 "grep          no flags"
FL >/dev/null 2>&1
status "flags alone: usage, exit 2" 2 $?
FL fakeflagq -a >/dev/null 2>&1
lacks "flags: nothing is written to the query log" "$(cat "$HINTDB_LOG" 2>/dev/null)" "fakeflagq"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
