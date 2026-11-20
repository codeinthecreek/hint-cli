# hint

Natural-language command lookup for bash that answers from your own shell history and notes.

```
$ hint how do I create an ssh tunnel
ssh -L 11434:localhost:11434 -i ~/.ssh/my_key <USER@HOST>
  # your history x2; e.g. ssh -L 11434:localhost:11434 -i ~/.ssh/my_key ubuntu@gpu-dev.example.com
ssh -L 8080:localhost:80 user@remote_host
  # model suggestion
# see man ssh(1): OpenSSH remote login client
```

A local LLM guesses the command. `hint` then looks up the commands you have
actually used, by your question's words and the model's guess, and shows them in
your usual form with the model's guess alongside. Nothing is ever executed.

## How it works

1. **Guess.** `hint` asks an LLM (Ollama chat API, temperature 0) for 1-3
   commands that do what you asked.
2. **Find.** `hintdb find` looks up your indexed commands for the question:
   - **candidates:** every row that contains a word of the question (matched
     by stem with SQLite FTS5's porter stemmer, so `tunnels` finds `tunnel`)
     or is for a tool the model guessed. Paths and other values are searched
     only when the question mentions a path (`/`, `~`, dir, folder, path).
   - **score:** bm25 of the question's words (your history comments weigh
     more), plus smaller parts for the guessed tool, the flags the row shares
     with a guess, and the guesses' words; use count breaks ties.
   - **your rows:** the best 5; variants that differ only in values (hosts,
     flag order) show once. Rows that match nothing but the tool's name
     (plain `ssh <host>` for "ssh tunnel") show once per tool, and the list
     gets shorter instead of filling up with them. A guessed `a-b` tool
     (`docker-compose`) also counts as `a b` when that is how you type it.
   - **who leads:** your best row comes first when it holds more than half of
     the question's words; the model's first guess then comes second.
     Otherwise the model's guess comes first ("most likely"), then your rows.
     Further guesses follow, with `# see man <tool>(<section>): <summary>`
     once per suggested tool. A guess with the same shape as one of your
     printed rows is not repeated.
   - **not installed** (not on PATH and not a shell builtin): never printed as
     a command. Your rows for it are listed as `#` comments with the file
     they came from; the model's guesses are listed that way only when
     nothing installed was found.
3. **Print.** Each result is two lines: the command, then a `#` status line
   saying where it came from.

The index (`hint.db`) is built from your sources:

- **Cleaning.** Trivial commands (`ls`, `cd`, `vim file`, ...), lines that look
  like secrets, `hint`/`hintdb` lines and probable typos (one-off commands not
  on `PATH`) are dropped.
- **Deduplication.** Commands with the same shape are merged into one row with a
  use count, a template (`ssh -L <N>:localhost:<N> <HOST>`) and two real
  examples. Flags are kept as written; only values are replaced.
- **Notes.** Trailing `# comments` in history, markdown headings and comments,
  and justfile recipe names and doc comments become searchable notes. A note
  is shown on a merged row only if at least half of its uses carry it;
  otherwise it stays with its own example.
- **Man pages.** The NAME lines of installed section 1 and 8 pages (from
  `apropos .`) go into a separate `man.db`, used for the summary on
  model-suggested tools.

The index rebuilds automatically before a lookup whenever a source file, the
man-db index, the schema version or `HINTDB_IGNORE` has changed. Every rebuild
is a full rebuild into a temp file followed by an atomic replace.

## Requirements

- bash, curl, jq
- Python 3 with SQLite FTS5 (stdlib only, no pip packages)
- [Ollama](https://ollama.com) running locally or on another host, with a model
  pulled (default `qwen2.5-coder:3b`)
- man-db (`apropos`) for man page summaries (optional)

Check that your Python has FTS5:

```bash
python3 -c "import sqlite3; sqlite3.connect(':memory:').execute('create virtual table t using fts5(x)'); print('ok')"
```

## Install

```bash
install -Dm755 hint ~/.local/bin/hint
```

```bash
install -Dm755 hintdb ~/.local/bin/hintdb
```

```bash
ollama pull qwen2.5-coder:3b
```

On first use, `hintdb` registers `$HISTFILE` (or `~/.bash_history`) as a source.
Add notes and justfiles. Directories are walked for `*.md`, `*.markdown`,
`*.txt`, `justfile` and `*.just`; hidden directories are skipped.

```bash
hintdb add ~/notes ~/workspace/docs/cheatsheet.md
```

For commands from the current shell session to be indexed, the shell has to
write its history out after each command (a script can't do this for the calling
shell). Add this to `~/.bashrc`:

```bash
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

## Usage

```bash
hint how do I create an ssh tunnel
```

```bash
hint dns lookup
```

Annotating commands makes them findable by intent later:

```bash
ssh-keygen -R oldhost.example.org  # remove old host key known_hosts
```

### Past lookups

Every lookup is kept in the query log (see below). Like shell history, you
can look through it again without asking the model. The last 10 lookups:

```bash
hint history
```

Past questions containing a word:

```bash
hint history tunnel
```

The last 20 lookups:

```bash
hint history 20
```

Past commands containing a word, like grep over the answers you were given:

```bash
hint search rsync
```

`history` prints one line per lookup: its number, the time and the
question. `search` prints one line per command that was printed (its note
counts for matching, but the "your history" and "your notes" labels do
not), followed by the number, date and question of the newest lookup that
printed it, and how many lookups did. Both list oldest first, so the newest
is just above your prompt. Matching is case-insensitive and on plain
substrings. To see the full answer of a lookup, give its number:

```bash
hint history --show 57
```

Each of your rows in it is followed by the files it came from (`# from
~/.bash_history`), so a row you don't want can be found and fixed in its
source, with `grep -n` on the example shown in its status line.

`history` and `search` take at most one word, plus options anywhere on
the line. On its own `history` lists the last 10 lookups and `search`
prints the usage (it needs a word). With two or more words the line is a
question for the model (`hint history without duplicates`, `hint search
for files containing foo`). An unknown option prints the usage, as does
`hint help`.
How many past questions mention postgres:

```bash
hint history postgres --count
```

For several words, or a number to search for, use `-H` / `-S`:

```bash
hint -H --last 5 ssh key
```

```bash
hint -S --count docker
```

| Flag | Meaning |
|---|---|
| `-H`, `--history [WORD...]` | past questions containing all WORDs (no words: every lookup) |
| `-S`, `--search WORD...` | past commands containing all WORDs |
| `-n`, `--last N` | only the last N matching lines (default 10) |
| `-c`, `--count` | print the number of matching lines instead |
| `-s`, `--show NUM` | the full answer of lookup NUM; `history` and `-H` only, on its own (no words, `-n` or `-c`) |
| `-d`, `--delete NUM[,NUM\|NUM-NUM]...` | delete lookups from the log; `history` and `-H` only, on its own |

Options can go before or after the words. `-n` and `-c` work with all four
forms; `--show` and `--delete` only with `history` and `-H`.

To keep lookups you didn't mean (a typo, a line that went to the model by
mistake) out of `history` and `search`, delete them by number, like bash
`history -d`:

```bash
hint history --delete 41,42
```

A deleted lookup's line is blanked, so the others keep their numbers. If a
listed number is not in the log, nothing is deleted; a range (`41-45`)
deletes the lookups in it. Deleting lines from the log by hand instead
renumbers the ones after them.

`hint help` alone prints the usage; `hint help me ...` is a question.

### hintdb commands

| Command | Purpose |
|---|---|
| `hintdb add PATH... [--kind history\|md\|text\|just]` | register sources and rebuild |
| `hintdb remove PATH...` | unregister sources and rebuild |
| `hintdb sources` | list registered sources |
| `hintdb rebuild` | force a full rebuild |
| `hintdb update` | rebuild only if something changed |
| `hintdb stats` | entries per kind and man page count, for checking dedup |
| `hintdb find [--debug] -q QUESTION [GUESS...]` | your commands for a question and the model's guesses (used by `hint`) |
| `hintdb log [--printed] [-n N] [-c] [WORD...]` | past questions containing all WORDs; `--printed`: past commands (used by `hint history` / `hint search`) |
| `hintdb log --show N` | the full entry N of the query log |
| `hintdb query [-n N] WORDS...` | `find`'s ranking for the words alone, with scores, then matching man pages (debugging; not used by `hint`) |

Source kinds are detected from the file name. Use `--kind` to override, e.g. for
an old history file:

```bash
hintdb add --kind history ~/.bash_history.old
```

### Query log

Every lookup appends one JSON line to `~/.local/share/hintdb/queries.jsonl`:
the time, your question, the model's guesses, the lines printed (exactly as
shown, also when nothing was printed) and the source files of each of your
rows that was printed. Like your shell history, it stays on your machine
and contains commands from your history. To turn it off:

```bash
export HINTDB_LOG=/dev/null
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `HINT_MODEL` | `qwen2.5-coder:3b` | Ollama model |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `HINT_DEBUG` | unset | print model guesses and find scores to stderr |
| `HINTDB_IGNORE` | empty | extra command words never to index (space-separated) |
| `HINTDB_NO_MAN` | unset | disable the man page index |
| `HINTDB_DB` | `~/.local/share/hintdb/hint.db` | index location |
| `HINTDB_MANDB` | next to `HINTDB_DB` | man index location |
| `HINTDB_SOURCES` | `~/.config/hintdb/sources` | source list |
| `HINTDB_APROPOS` | `apropos .` | command that lists man NAME lines (for testing) |
| `HINTDB_LOG` | `~/.local/share/hintdb/queries.jsonl` | query log; `/dev/null` turns it off |

## Tests

```bash
tests/run.sh
```

The suite uses synthetic fixtures in `tests/fixtures` and a stub Ollama
server, so it needs no model and never touches your index, history or
query log.
Requires python3 (with FTS5), curl and jq.

To measure hint on your own queries with a real model, see
[eval/README.md](eval/README.md).

## Limitations

- Hosts without a dot (`ssh myserver`) aren't recognised as hosts, so each one
  stays a separate row.
- Bundled short flags are compared letter by letter only for letters you have
  also typed alone with that tool: `grep -ri` matches `grep -r -i` once your
  history has `grep -r` and `grep -i`. So `find -name` is never split, but a
  bundle whose letters you never typed alone (`rsync -avz`) stays whole.
- Long and short forms of the same option (`-r`, `--recursive`) aren't treated
  as equal.
- When the model's first guess has the same shape as one of your rows, it is
  not printed again, and the next guess (possibly another tool) is the one
  that can lead.
- Bash history without timestamps gives only rough recency (line order).

## Debugging a lookup

```bash
HINT_DEBUG=1 hint how do I create an ssh tunnel to postgres
```

```
hint: model guesses:
ssh -L 5433:localhost:5432 user@postgres-server
hintdb: words: ['create', 'ssh', 'tunnel', 'postgres']
hintdb: guessed tools: ['ssh']  guess words: ['ssh', 'postgres']
hintdb: 12 candidate rows, top:
hintdb:    score   bm25 tool flags gwords  uses   command
hintdb:    1.750   1.00  1.0  0.50   1.00  x1      ssh -N -L 5432:localhost:5432 db.example.org  # tunnel to postgres
hintdb:    0.600   0.04  1.0  0.50   0.30  x2      ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>
hintdb:    0.508   0.10  1.0  0.00   0.30  x2      ssh buildhost
hintdb:    0.508   0.10  1.0  0.00   0.30  x2      ssh webhost
hintdb:    0.499   0.46  0.0  0.00   0.00  x6      mkdir <PATH>
hintdb:    0.496   0.07  1.0  0.00   0.30  x6      ssh user@<HOST>
...
hintdb: best row holds 0.71 of the question's words -> user's row leads
ssh -N -L 5432:localhost:5432 db.example.org
  # your history x1: tunnel to postgres
ssh -L 5433:localhost:5432 user@postgres-server
  # model suggestion
ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>
  # your history x2; e.g. ssh -L 8080:localhost:80 -i ~/.ssh/key user@gpu2.example.org
ssh buildhost
  # your history x2
mkdir <PATH>
  # your history x6; e.g. mkdir /dev/video1394  # create firewire devices
# see man ssh(1): OpenSSH remote login client
```

`ssh webhost` and `ssh user@<HOST>` match nothing but the tool, like `ssh
buildhost`, so only the best of them is shown and the list ends at 4 rows.

How to read it:

- **Wrong tool in the guesses:** a model or prompt problem. Try a larger model,
  e.g. `HINT_MODEL=qwen2.5-coder:7b`.
- **Your command is missing from the table:** none of the question's words
  are in it (or only in its paths and values, which are searched only when
  the question mentions a path), and the model guessed another tool. A
  `# comment` on the command in your history fixes that for next time.
- **Your command is in the table but ranked low:** a scoring problem; the
  columns show which part is missing.

To see what a source contributes after cleaning and dedup:

```bash
hintdb stats
```

```bash
hintdb query remove host key
```

## Architecture

Data flow from sources to the printed answer, traced with the example query
`hint how do I create an ssh tunnel`.

```text
 FILES
 ============================================================================
  ~/.local/bin/hint          bash script: model call + output
  ~/.local/bin/hintdb        python (stdlib + sqlite FTS5): index + find
  ~/.config/hintdb/sources   registered sources (kind<TAB>path)
  ~/.local/share/hintdb/     hint.db, man.db, queries.jsonl (query log)


 INGEST  (hintdb add/remove/rebuild, or automatically before find/query
          when any source's mtime/size, the schema version or HINTDB_IGNORE
          changes; full rebuild into a temp file, then atomic replace)
 ============================================================================

  ~/.bash_history ---+
  notes *.md *.txt --+   extract
  justfiles ---------+   - history: one line each, trailing "# note"
          |              - md: shell fences + "$ " lines; note = heading,
          |                prose line, "# comment" above
          |              - just: recipe lines; note = "just <recipe>" + doc
          v
  clean   drop: trivial (ls, cd, vim file ...) unless noted
                secrets (token, password, keys ...)
                hint / hintdb lines (+ HINTDB_IGNORE)
                one-off history lines whose command is not on PATH
          |
          v
  shape   values -> placeholders, flags kept as written
          ssh -L 11434:localhost:11434 -i ~/.ssh/my_key ubuntu@gpu-dev.example.com
            -> ssh -L <N>:localhost:<N> -i <PATH> <USER@HOST>
          (<HOST> <USER@HOST> <PATH> <FILE> <STR> <URL> <HEX> <N>)
          |
          v
  merge   one row per shape:
          count        total uses                          x2
          display      template: constant tokens kept,     ssh -L 11434:localhost:11434
                       varying ones as placeholders          -i ~/.ssh/my_key
                                                             <USER@HOST>
          examples     2 real variants, each with its own note
          dnote        notes carried by >= half the uses
          hnote        history comments (search only, weighs more)
          nnote        text from notes files (search only)
          cmdword      ssh
          sources      files the row came from (for "found in <source>")
          prog/args/data/variants   searched FTS columns
          |
          v
        hint.db (FTS5, porter stemmer, schema 11)

  apropos . --> sections 1/8 NAME lines --> man.db
  (rebuilt when /var/cache/man index files change)
                ssh: OpenSSH remote login client


 QUERY   $ hint how do I create an ssh tunnel to postgres
 ============================================================================

  hint
   |  (1) GUESS     POST $OLLAMA_HOST/api/chat   model $HINT_MODEL
   |                temperature 0, num_predict 120
   |                messages:
   |                  system     1-3 commands, best first, commands only
   |                             (a different tool on each line if unsure)
   |                  user       show disk usage of a directory   (example)
   |                  assistant  du -sh /var/log / ncdu /var/log  (example)
   |                  user       how do I create an ssh tunnel to postgres
   |                cannot connect / timeout / Ollama error -> say which, exit 1
   v
  model reply  ->  cleanup (fences, "$ ", numbering, blanks; max 3 lines)
   |               (nothing left: the lookup goes on with the question alone)
   |   ssh -L 5433:localhost:5432 user@postgres-server
   v
  (2) FIND      hintdb find [--debug] -q <question> -- <guess>...
   |
   |    words       create ssh tunnel postgres     (stopwords dropped)
   |    tools       ssh                            (from the guesses)
   |    candidates  rows with a question word (porter stem; values only if a
   |                path is mentioned) OR for a guessed tool
   |    score       1.0  x bm25 of the question's words / best bm25
   |                       (history comment column x1.5)
   |              + 0.3  x guessed tool (1.0 first guess, 0.7 later)
   |              + 0.3  x flag overlap with a guess for the same tool
   |              + 0.3  x share of the guesses' words found (rarer count more)
   |              + 0.02 x ln(uses)
   |
   |      score   bm25 tool flags gwords  uses   command
   |      1.750   1.00  1.0  0.50   1.00  x1     ssh -N -L 5432:localhost:5432 db.example.org  # tunnel to postgres
   |      0.600   0.04  1.0  0.50   0.30  x2     ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>
   |      0.508   0.10  1.0  0.00   0.30  x2     ssh buildhost
   |      0.508   0.10  1.0  0.00   0.30  x2     ssh webhost       (tool only: skipped)
   |
   |    your rows   best 5 installed; same tool + flags + words shown once;
   |                rows matching only the tool shown once per tool, and
   |                their places not refilled
   |    who leads   best row holds > half the question's words (by rarity)?
   |                  yes -> best row, model's guess, other rows   <- 0.71 here
   |                  no  -> model's guess ("most likely"), your rows
   v
  (3) OUTPUT    two lines per result, nothing executed; then further guesses,
                "see man <tool>(<sec>)" once per suggested tool, and any
                "not installed" comments. Nothing printed at all ->
                "Sorry, I didn't understand your question, can you rephrase it?"
                hintdb find then appends the lookup to the query log
                (question, guesses, printed lines, each row's sources).

  ssh -N -L 5432:localhost:5432 db.example.org
    # your history x1: tunnel to postgres
  ssh -L 5433:localhost:5432 user@postgres-server
    # model suggestion
  ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>
    # your history x2; e.g. ssh -L 8080:localhost:80 -i ~/.ssh/key user@gpu2.example.org
  ssh buildhost
    # your history x2
  ...
  # see man ssh(1): OpenSSH remote login client


 DEBUG ONLY
 ============================================================================
  hintdb query WORDS   find's ranking for the words alone (no model guesses),
                       with scores, then matching man NAME lines; not used
                       by hint
  hintdb stats         rows per kind, man page count
```

