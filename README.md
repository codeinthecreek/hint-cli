# hint

Natural-language command lookup for bash that answers from your own shell history and notes.

```bash
hint how do I create an ssh tunnel
```

```text
ssh -L 11434:localhost:11434 -i ~/.ssh/my_key <USER@HOST>
  # your history x2; e.g. ssh -L 11434:localhost:11434 -i ~/.ssh/my_key ubuntu@gpu-dev.example.com
ssh -L 8080:localhost:80 user@remote_host
  # model suggestion
# see man ssh(1): OpenSSH remote login client
```

A local LLM guesses the command. `hint` then looks up the commands you have
actually used, by your question's words and the model's guess, and shows them in
your usual form with the model's guess alongside. Nothing is ever executed.

Every lookup is kept in a local log, so past questions and answers can be
looked up again without the model, like shell history. Later, `hint search
tunnel` finds that answer again:

```text
ssh -L 11434:localhost:11434 -i ~/.ssh/my_key <USER@HOST>  # 12  2026-11-20 how do I create an ssh tunnel
```

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
4. **Log.** The question, the guesses and the printed lines are appended to
   the query log, for `hint history` and `hint search`.

The index (`hint.db`) is built from your sources:

- **Cleaning.** Trivial commands (`ls`, `cd`, `vim file`, ...), lines that look
  like secrets, `hint`/`hintdb` lines and probable typos (one-off commands not
  on `PATH`) are dropped.
- **Deduplication.** Commands with the same shape are merged into one row with a
  use count, a template (`ssh -L <N>:localhost:<N> <HOST>`) and two real
  examples. Flags are kept as written; only values are replaced.
- **Notes.** Trailing `# comments` in history, markdown headings and comments,
  and justfile and Makefile recipe names and doc comments become searchable
  notes. A note
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
Add the notes files, justfiles and Makefiles you keep for work on this
machine, such as a cheatsheet or a project's justfile:

```bash
hintdb add ~/notes/kubernetes.md ~/src/myproject/justfile
```

Register files rather than whole folders of old notes: commands for tools or
platforms you no longer use come back as noise. (A directory is walked for
`*.md`, `*.markdown`, `*.txt`, `justfile`, `*.just`, `Makefile`, `makefile`,
`GNUmakefile` and `*.mk`, skipping hidden directories.)

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

Every lookup is kept in the query log, and these commands read it without
asking the model.

The last 10 lookups, like bash `history`:

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

The full answer of lookup 57, as it was printed:

```bash
hint history --show 57
```

Delete lookups you didn't mean (a typo, a line that went to the model by
mistake), like bash `history -d`:

```bash
hint history --delete 41,42
```

What `hint history tunnel` prints:

```text
   12  2026-11-20 09:14  how do I create an ssh tunnel
   57  2026-11-20 10:22  ssh tunnel to postgres
```

What `hint search tunnel` prints:

```text
ssh -N -L 5432:localhost:5432 db.example.org  # 57  2026-11-20 ssh tunnel to postgres (x2)
```

What `hint history --show 57` prints:

```text
   57  2026-11-20 10:22  ssh tunnel to postgres
  ssh -N -L 5432:localhost:5432 db.example.org
    # your history x1: tunnel to postgres
    # from ~/.bash_history
  ...
```

- **history** prints one line per lookup: its number, the time and the
  question.
- **search** prints one line per command that was printed, then the number,
  date and question of the newest lookup that printed it, and how many did.
  A command's note counts for matching; the "your history", "your notes",
  "your Makefile" and "your justfile" labels do not.
- **--show** prints the whole answer, each of your rows followed by the
  files it came from, so a row you don't want can be found and fixed in its
  source (`grep -n` on the example in its status line).
- **--delete** takes `N`, `N,M`, `N-M` or a mix. A deleted lookup's line is
  blanked, so the others keep their numbers. If a listed number is not in
  the log, nothing is deleted; a range deletes the lookups in it.

Lists are oldest first, so the newest is just above your prompt. Matching
is case-insensitive and on plain substrings. A lookup's number is its line
in the log file, so deleting lines from the log by hand renumbers the ones
after them.

**Words and options.** `history` and `search` take at most one word, plus
options anywhere on the line:

```bash
hint history postgres --count
```

With two or more words the line is a question for the model, so `hint
history without duplicates` and `hint search for files containing foo` are
asked as usual. `search` with no word, or any unknown option, prints the
usage. For several words, or a number to search for, use `-H` / `-S`:

```bash
hint -H --last 5 ssh key
```

```bash
hint -S --count docker
```

| Form or option | Meaning |
|---|---|
| `-H`, `--history [WORD...]` | past questions containing all WORDs (no words: every lookup) |
| `-S`, `--search WORD...` | past commands containing all WORDs |
| `-n`, `--last N` | only the last N matching lines (default 10) |
| `-c`, `--count` | print the number of matching lines instead |
| `-s`, `--show NUM` | the full answer of lookup NUM, with your rows' source files |
| `-d`, `--delete NUM[,NUM\|NUM-NUM]...` | delete lookups from the log |

`-n` and `-c` work after `history`, `search`, `-H` and `-S`. `--show` and
`--delete` work only after `history` and `-H`, and on their own (no words,
`-n` or `-c`).

**Help.** `hint help` prints the usage; `hint help me ...` is a question.

### hintdb commands

| Command | Purpose |
|---|---|
| `hintdb add PATH... [--kind history\|md\|text\|just\|make]` | register sources and rebuild |
| `hintdb remove PATH...` | unregister sources and rebuild |
| `hintdb sources` | list registered sources |
| `hintdb rebuild` | force a full rebuild |
| `hintdb update` | rebuild only if something changed |
| `hintdb stats` | entries per kind, man page count, and entries per source file (and how many come from that file only) |
| `hintdb stats --source PATH` | the entries from one source file (or from the files under a directory), most uses first |
| `hintdb find [--debug] -q QUESTION [GUESS...]` | your commands for a question and the model's guesses (used by `hint`) |
| `hintdb log [--printed] [-n N] [-c] [WORD...]` | past questions containing all WORDs; `--printed`: past commands (used by `hint history` / `hint search`) |
| `hintdb log --show N` | the full entry N of the query log, with each row's source files |
| `hintdb log --delete N[,N\|N-M]...` | delete entries from the query log (their numbers stay unused) |
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
and contains commands from your history. `hint history` and `hint search`
read it (see "Past lookups"). To turn it off:

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

To see what each source contributes after cleaning and dedup:

```bash
hintdb stats
```

After the counts per kind and the man page count, it prints one line per
source file: its entries, and how many of them come from that file only.
The second number is what removing the source would drop; the rest are
also in another source, often your history. For example:

```text
~/.bash_history	5210 entries, 4870 only from this source
~/notes/kubernetes.md	140 entries, 122 only from this source
```

To see the entries themselves, one per line with use count and note (and
the other sources, for an entry not only from this one), pass the file or a
directory of sources:

```bash
hintdb stats --source ~/src/myproject/Makefile
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
  Makefiles ---------+   - md: shell fences + "$ " lines; note = heading,
          |                prose line, "# comment" above
          |              - just, make: recipe lines, "\" lines joined, only
          |                single commands (no if/for, ; && ||, echo);
          |                note = "just|make <recipe>" + doc
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


 PAST LOOKUPS   $ hint history tunnel   /   $ hint search tunnel
 ============================================================================

  hint   history|search + at most one word + options -> hintdb log
         (two or more words: a question, as above; no model call here)
   |
   v
  hintdb log [--printed] [-n N] [-c] [-s N] [-d N,M-K] WORDS
   |   read ~/.local/share/hintdb/queries.jsonl, number = line in the file
   |   history   lookups whose question has every word
   |               -> "   57  2026-11-20 10:22  ssh tunnel to postgres"
   |   --printed lookups' command lines whose text or note has every word,
   |   (search)  one line per command, newest lookup's number + question
   |               -> "ssh -N -L 5432:... db.example.org  # 57  2026-11-20 ..."
   |   -n N      only the last N (default 10), oldest first
   |   -c        the number of lines instead
   |   -s N      lookup N in full, "# from <file>" under each of your rows
   |   -d N,M-K  blank those lines (numbers kept) under flock, as appends are
   v
  stdout; exit 1 when nothing matches


 DEBUG ONLY
 ============================================================================
  hintdb query WORDS   find's ranking for the words alone (no model guesses),
                       with scores, then matching man NAME lines; not used
                       by hint
  hintdb stats         rows per kind, man page count, rows per source file
                       (and how many from that file only)
```

