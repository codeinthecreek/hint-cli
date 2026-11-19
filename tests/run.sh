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
for t in fakedock fakedock-compose FakeVM; do
  printf '#!/bin/sh\n' > "$tmp/bin/$t"; chmod +x "$tmp/bin/$t"
done
export PATH="$tmp/bin:$PATH"

# Isolated index and sources.
export HINTDB_DB="$tmp/hint.db" HINTDB_MANDB="$tmp/man.db"
export HINTDB_SOURCES="$tmp/sources" HISTFILE="$fix/history"
export HINTDB_APROPOS="cat $fix/apropos.txt"
unset HINTDB_IGNORE HINTDB_NO_MAN HINT_DEBUG HINT_MODEL

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

echo "== hint (stub Ollama)"
reply="$tmp/reply"
export STUB_REPLY_FILE="$reply"
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

printf '%s\n' 'dig +short example.com' > "$reply"
err=$(HINT_DEBUG=1 hint dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: model guesses" "$err" "hint: model guesses:"
has "HINT_DEBUG: find scores" "$err" "score   bm25 tool flags gwords  uses   command"

: > "$reply"
out=$(hint short dns lookup 2>&1)
status "empty reply: the question's own words are still looked up (exit 0)" 0 $?
has "empty reply: the user's row found by the question's words" "$out" "dig +short <HOST>"

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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
