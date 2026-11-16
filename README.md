# hint

Natural-language command lookup for bash that answers from your own shell history and notes.

```
$ hint how do I create an ssh tunnel
ssh -L 11434:localhost:11434 -i ~/.ssh/my_key <USER@HOST>
  # your history x2; e.g. ssh -L 11434:localhost:11434 -i ~/.ssh/my_key ubuntu@gpu-dev.example.com
ssh -L 8080:localhost:80 user@remote_host
  # model suggestion (ssh: OpenSSH remote login client)
```

A local LLM guesses the command. `hint` then replaces the guess with the closest
command you have actually used, in your usual form. Nothing is ever executed.

## How it works

1. **Guess.** `hint` asks an LLM (Ollama chat API, temperature 0) for 1-3
   commands that do what you asked.
2. **Match.** `hintdb match` reduces each guess to a *shape* (values become
   placeholders such as `<HOST>` and `<PATH>`). It then compares that shape with
   your indexed commands for the same tool:
   - score = overlap of option flags (`-x`, `--long`, `+opt`, values ignored);
     ties are broken by overlap of all tokens, then by use count
   - **match** (flag overlap >= 0.5): up to 5 of your commands in total, best
     first; variants that differ only in values (hosts, flag order) show
     once. The model's guess follows unless it has the same shape as one of
     them.
   - **no match**: the model's guess, with the tool's man page summary
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

### hintdb commands

| Command | Purpose |
|---|---|
| `hintdb add PATH... [--kind history\|md\|text\|just]` | register sources and rebuild |
| `hintdb remove PATH...` | unregister sources and rebuild |
| `hintdb sources` | list registered sources |
| `hintdb rebuild` | force a full rebuild |
| `hintdb update` | rebuild only if something changed |
| `hintdb stats` | entries per kind and man page count, for checking dedup |
| `hintdb match [--debug] GUESS...` | closest own command per guessed command (used by `hint`) |
| `hintdb query [-n N] WORDS...` | keyword search over the index (debugging; not used by `hint`) |

Source kinds are detected from the file name. Use `--kind` to override, e.g. for
an old history file:

```bash
hintdb add --kind history ~/.bash_history.old
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `HINT_MODEL` | `qwen2.5-coder:3b` | Ollama model |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `HINT_DEBUG` | unset | print model guesses and match scores to stderr |
| `HINTDB_MATCH_MIN` | `0.5` | minimum flag overlap to count as a match |
| `HINTDB_IGNORE` | empty | extra command words never to index (space-separated) |
| `HINTDB_NO_MAN` | unset | disable the man page index |
| `HINTDB_DB` | `~/.local/share/hintdb/hint.db` | index location |
| `HINTDB_MANDB` | next to `HINTDB_DB` | man index location |
| `HINTDB_SOURCES` | `~/.config/hintdb/sources` | source list |
| `HINTDB_APROPOS` | `apropos .` | command that lists man NAME lines (for testing) |

## Tests

```bash
tests/run.sh
```

The suite uses synthetic fixtures in `tests/fixtures` and a stub Ollama
server, so it needs no model and never touches your index or history.
Requires python3 (with FTS5), curl and jq.

## Limitations

- Hosts without a dot (`ssh myserver`) aren't recognised as hosts, so each one
  stays a separate row.
- Bundled short flags aren't split: `grep -ri` and `grep -r -i` count as
  different flags.
- Long and short forms of the same option (`-r`, `--recursive`) aren't treated
  as equal.
- Only one row is returned per guess, even when several of your commands score
  equally.
- Bash history without timestamps gives only rough recency (line order).

## Debugging a lookup

```bash
HINT_DEBUG=1 hint how do I create an ssh tunnel
```

```
hint: model guesses:
ssh -L 8080:localhost:80 user@remote_host
hintdb: guess: ssh -L 8080:localhost:80 user@remote_host
hintdb:   shape: ssh -L <N>:localhost:<N> <USER@HOST>
hintdb:   368 rows for tool 'ssh', top:
hintdb:     flags   all  uses   shape
hintdb:      0.50  0.60  x2     ssh -L <N>:localhost:<N> -i <PATH> <USER@HOST>
hintdb:      0.50  0.33  x2     ssh -L <N>:<HOST>:<N> -i <PATH> <USER@HOST>
hintdb:      0.00  0.33  x893   ssh <USER@HOST>
hintdb:   -> partial match (0.50 >= 0.5); guess shown too
ssh -L 11434:localhost:11434 -i ~/.ssh/my_key <USER@HOST>
  # your history x2; e.g. ssh -L 11434:localhost:11434 -i ~/.ssh/my_key ubuntu@gpu-dev.example.com
ssh -L 8080:localhost:80 user@remote_host
  # model suggestion (ssh: OpenSSH remote login client)
```

How to read it:

- **Wrong tool in the guesses:** a model or prompt problem. Try a larger model,
  e.g. `HINT_MODEL=qwen2.5-coder:7b`.
- **Right tool, wrong row chosen:** a scoring problem; the table shows why.
- **Useful rows just below 0.5:** adjust `HINTDB_MATCH_MIN`.

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
  ~/.local/bin/hintdb        python (stdlib + sqlite FTS5): index + match
  ~/.config/hintdb/sources   registered sources (kind<TAB>path)
  ~/.local/share/hintdb/     hint.db, man.db


 INGEST  (hintdb add/remove/rebuild, or automatically before match/query
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
          note         all notes (search only)
          cmdword      ssh
          sources      files the row came from (for "found in <source>")
          prog/args/data   weighted FTS columns (hintdb query only)
          |
          v
        hint.db (FTS5, schema 6)

  apropos . --> sections 1/8 NAME lines --> man.db
  (rebuilt when /var/cache/man index files change)
                ssh: OpenSSH remote login client


 QUERY   $ HINT_DEBUG=1 hint how do I create an ssh tunnel
 ============================================================================

  hint
   |  (1) GUESS     POST $OLLAMA_HOST/api/chat   model $HINT_MODEL
   |                temperature 0, num_predict 120
   |                messages:
   |                  system     1-3 commands, best first, commands only
   |                  user       show disk usage of a directory   (example)
   |                  assistant  du -sh /var/log / ncdu /var/log  (example)
   |                  user       how do I create an ssh tunnel
   v
  model reply  ->  cleanup (fences, "$ ", numbering, blanks; max 3 lines)
   |
   |   ssh -L 8080:localhost:80 user@remote_host
   v
  (2) MATCH     hintdb match [--debug] -- <guess>...
   |
   |  per guess:
   |    tool   = ssh
   |    shape  = ssh -L <N>:localhost:<N> <USER@HOST>
   |    rows   = hint.db WHERE cmdword = 'ssh'          (368 rows)
   |    score each:  flags  overlap of -x/--long/+opt tokens (values ignored;
   |                        all tokens if the guess has no flags)
   |                 all    overlap of all argument tokens (tie-breaker)
   |                 uses   count (last tie-breaker)
   |
   |      flags   all  uses   shape
   |       0.50  0.60  x2     ssh -L <N>:localhost:<N> -i <PATH> <USER@HOST>
   |       0.50  0.33  x2     ssh -L <N>:<HOST>:<N> -i <PATH> <USER@HOST>
   |       0.50  0.33  x2     ssh -L <HOST>:<N>:localhost:<N> -i <PATH> <USER@HOST>
   |       0.50  0.33  x1     ssh -L <HOST>:localhost:<N> -i <PATH> <USER@HOST>
   |       0.00  0.33  x893   ssh <USER@HOST>
   |
   |    tool not installed (not on PATH, not a builtin)?
   |                          -> your rows as "# found in <source>" comments;
   |                             guesses as comments only if nothing else
   |    best flags >= HINTDB_MATCH_MIN (0.5)?
   |      exact (same shape)  -> your rows only (up to 5)
   |      partial             -> your rows, then the guess     <- this case
   |      no match            -> the guess, with man summary
   v
  (3) OUTPUT    two lines per result, nothing executed; your rows from all
                guesses first, then the model suggestions (each in guess order)

  ssh -L 11434:localhost:11434 -i ~/.ssh/my_key <USER@HOST>
    # your history x2; e.g. ssh -L 11434:localhost:11434 -i ~/.ssh/my_key ubuntu@gpu-dev.example.com
  ssh -L 8080:localhost:80 user@remote_host
    # model suggestion (ssh: OpenSSH remote login client)


 DEBUG ONLY
 ============================================================================
  hintdb query WORDS   keyword search (FTS5 + man NAME lines) over the same
                       index; no longer used by hint
  hintdb stats         rows per kind, man page count
```

