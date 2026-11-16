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
cleanup() { [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

# Run the repo's hint/hintdb, not installed copies.
mkdir -p "$tmp/bin"
ln -s "$root/hint" "$tmp/bin/hint"
ln -s "$root/hintdb" "$tmp/bin/hintdb"
export PATH="$tmp/bin:$PATH"

# Isolated index and sources.
export HINTDB_DB="$tmp/hint.db" HINTDB_MANDB="$tmp/man.db"
export HINTDB_SOURCES="$tmp/sources" HISTFILE="$fix/history"
export HINTDB_APROPOS="cat $fix/apropos.txt"
unset HINTDB_IGNORE HINTDB_NO_MAN HINTDB_MATCH_MIN HINT_DEBUG HINT_MODEL

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
if grep -nP '[^\x00-\x7F]' "$root/hint" "$root/hintdb" "$here"/*.sh "$here"/*.py >/dev/null; then
  bad "code is ASCII only" "$(grep -nP '[^\x00-\x7F]' "$root/hint" "$root/hintdb" "$here"/*.sh "$here"/*.py)"
else
  ok "code is ASCII only"
fi

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
line "man NAME line finds dig for 'DNS lookup'" "$out" 1 "dig  # DNS lookup utility  [man dig(1)]"
has "man hit pulls in the user's own dig rows" "$out" "dig +short <HOST>  [x3"

echo "== match"
out=$(hintdb match "dig +short example.com" 2>&1)
line "exact match prints the user's row" "$out" 1 "dig +short <HOST>"
has "exact match status: history count and example" "$out" "# your history x3; e.g. dig +short web"
lacks "exact match does not print the guess" "$out" "example.com"

out=$(hintdb match "dig example.com" 2>&1)
line "guess without flags matches on all tokens" "$out" 1 "dig <HOST>"

out=$(hintdb match "ssh -L 8080:localhost:80 user@remote_host" 2>&1)
line "flags beat use count: tunnel row, not plain ssh x6" "$out" 1 \
  "ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>"
has "partial match also prints the guess, after the user's rows" "$out" "ssh -L 8080:localhost:80 user@remote_host"
line "partial match: guess below the user's rows is just a model suggestion" "$out" 6 \
  "  # model suggestion"
has "case 2: see man, with section and summary" "$out" "# see man ssh(1): OpenSSH remote login client"

out=$(hintdb match "nslookup example.com" 2>&1)
line "case 2: first guess" "$out" 1 "nslookup example.com"
line "case 2: first guess is the most likely" "$out" 2 "  # most likely (model suggestion)"
line "case 2: see man after the suggestions" "$out" 3 \
  "# see man nslookup(1): query Internet name servers interactively"

out=$(hintdb match "nslookup example.com" "nslookup -type=mx example.com" 2>&1)
line "case 2: later guesses are alternatives" "$out" 4 "  # alternative (model suggestion)"
if [ "$(grep -c '^# see man nslookup' <<<"$out")" = 1 ]; then
  ok "case 2: see man once per tool"
else
  bad "case 2: see man once per tool" "$out"
fi

echo "== installed only"
out=$(hintdb match "foozz --bar" 2>&1)
line "uninstalled guess, nothing else: says so" "$out" 1 \
  "# no installed command found; the model suggested the following:"
line "uninstalled guess shown as a comment only" "$out" 2 "#   foozz --bar"

out=$(hintdb match "foozz --bar" "dig +short example.com" 2>&1)
line "uninstalled guess omitted when an installed command is shown" "$out" 1 "dig +short <HOST>"
lacks "uninstalled guess not mentioned then" "$out" "foozz"

out=$(hintdb match "fakesched -Nel" 2>&1)
line "user's rows for an uninstalled tool: named source" "$out" 1 \
  "# found in cluster.md, but fakesched is not installed here:"
line "user's rows for an uninstalled tool: as comments" "$out" 2 "#   fakesched -Nel"
if grep -q '^fakesched' <<<"$out"; then
  bad "uninstalled tool never printed as a command" "$out"
else
  ok "uninstalled tool never printed as a command"
fi
lacks "uninstalled guess with rows not repeated in the model block" "$out" "no installed command found"

out=$(hintdb match "history 10" 2>&1)
line "shell builtins count as installed (history)" "$out" 1 "history 10"
out=$(hintdb match "fc -ln -10" 2>&1)
line "shell builtins count as installed (fc, user's row)" "$out" 1 "fc -ln -10"
has "shell builtins count as installed (fc, user's row)" "$out" "# your history x1"

out=$(hintdb match "dig +short a.example.org" "dig +short b.example.org" 2>&1)
if [ "$(grep -c '^dig +short <HOST>$' <<<"$out")" = 1 ]; then
  ok "same row for two guesses printed once"
else
  bad "same row for two guesses printed once" "$out"
fi

out=$(hintdb match "nslookup example.com" "dig +short example.com" 2>&1)
line "user's row from a later guess comes before an earlier model suggestion" "$out" 1 \
  "dig +short <HOST>"
line "model suggestion follows the user's rows" "$out" 3 "nslookup example.com"

out=$(hintdb match "ssh-keygen -f ~/.ssh/known_hosts" 2>&1)
has "case 1: several matching rows of the tool are shown" "$out" "ssh-keygen -l -f /home/user/.ssh/<PATH>"
if [ "$(grep -c '^ssh-keygen .*-R' <<<"$out")" = 1 ]; then
  ok "case 1: host and flag-order variants of a row shown once"
else
  bad "case 1: host and flag-order variants of a row shown once" "$out"
fi
lacks "case 1: rows below HINTDB_MATCH_MIN not shown" "$out" "-C <STR>"
line "case 1: model guess follows the user's rows" "$out" 5 "ssh-keygen -f ~/.ssh/known_hosts"

out=$(HINTDB_MATCH_MIN=0.9 hintdb match "ssh -L 8080:localhost:80 user@remote_host" 2>&1)
line "HINTDB_MATCH_MIN raises the bar" "$out" 1 "ssh -L 8080:localhost:80 user@remote_host"

err=$(hintdb match --debug "ssh -L 8080:localhost:80 user@remote_host" 2>&1 >/dev/null)
has "--debug shows the shape" "$err" "shape: ssh -L <N>:localhost:<N> <USER@HOST>"
has "--debug shows the score table" "$err" "flags   all  uses   shape"
has "--debug shows the decision" "$err" "-> partial match"

out=$(printf '%s\n' "dig +short example.com" | hintdb match 2>&1)
line "guesses read from stdin" "$out" 1 "dig +short <HOST>"

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

printf '%s\n' '```bash' '1. dig +short example.com' '' '$ ssh -L 8080:localhost:80 user@remote_host' \
  '- nslookup example.com' 'host example.com' '```' > "$reply"
out=$(hint how do I look up dns 2>&1)
status "messy reply: exit 0" 0 $?
line "fences and numbering stripped" "$out" 1 "dig +short <HOST>"
has "\$ prompt stripped" "$out" "ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>"
has "bullet stripped" "$out" "nslookup example.com"
lacks "at most 3 guesses used" "$out" "host example.com"

req=$(cat "$tmp/request")
has "request: model default" "$(jq -r .model <<<"$req")" "qwen2.5-coder:3b"
has "request: temperature 0" "$(jq -r .options.temperature <<<"$req")" "0"
has "request: not streamed" "$(jq -r .stream <<<"$req")" "false"
has "request: system, example exchange, then the query" \
  "$(jq -r '[.messages[].role] | join(",")' <<<"$req")" "system,user,assistant,user"
has "request: last message is the query" \
  "$(jq -r '.messages[-1].content' <<<"$req")" "how do I look up dns"

printf '%s\n' 'dig +short example.com' > "$reply"
err=$(HINT_DEBUG=1 hint dns lookup 2>&1 >/dev/null)
has "HINT_DEBUG: model guesses" "$err" "hint: model guesses:"
has "HINT_DEBUG: match scores" "$err" "flags   all  uses   shape"

: > "$reply"
out=$(hint dns lookup 2>&1)
status "empty reply: exit 1" 1 $?
has "empty reply: message" "$out" "model returned no commands"

out=$(OLLAMA_HOST=127.0.0.1:1 hint dns lookup 2>&1)
status "Ollama unreachable: exit 1" 1 $?
has "Ollama unreachable: message" "$out" "hint: no response from Ollama"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
