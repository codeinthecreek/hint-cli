# hint

Ask bash for a command in plain words, and get back the commands you have
actually run, found in your own shell history and notes, alongside a
suggestion from a local LLM.

```bash
hint how do I create an ssh tunnel to postgres
```

```text
ssh -N -L 5432:localhost:5432 db.example.org
  # your history x1: tunnel to postgres
ssh -L 5433:localhost:5432 user@postgres-server
  # model suggestion
ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>
  # your history x2; e.g. ssh -L 8080:localhost:80 -i ~/.ssh/key user@gpu2.example.org
ssh buildhost
  # your history x2
# see man ssh(1): OpenSSH remote login client
```

Each answer says where it came from, and nothing is ever executed. The model
runs in [Ollama](https://ollama.com), on your machine or on a host you choose,
so your history is never sent to an outside service.

## Why an LLM and your history together

Your history knows your hosts, paths and options, but not the words you ask
with. The model knows the words, but not your machine. Each one alone misses
things the other finds:

| You ask | Your history alone | The model alone | hint (both) |
|---|---|---|---|
| `ssh tunnel to postgres`, which you once ran with a `# tunnel to postgres` comment | finds your exact command | a generic `ssh -L` with a made-up host | your command first |
| `how do I set the screen resolution` | nothing: your `xrandr` line has none of these words | `xrandr -s 1920x1080`: right tool, not your screen's settings | your `xrandr --output HDMI-1 --mode 2560x1440`, under the model's guess |
| something you have never run | nothing | a suggestion | the suggestion, labelled as one |

Measured on the author's own history (77 questions): the first line printed
was useful for 32 with the history alone, 46 with the model alone and 57 with
both; it was the exact command for 24, 14 and 37. [eval/](eval/README.md) has
scripts to measure hint on your own questions.

## How it works

```text
            $ hint how do I set the screen resolution
                              |
             +----------------+-----------------+
             |                                  |
             v                                  |
   1. ask the local model                       |
      guess: xrandr -s 1920x1080                |
             |                                  |
             v                                  v
   2. take the guess apart:            3. take the question's words:
      tool xrandr, flags -s               set screen resolution
             |                                  |
             +----------------+-----------------+
                              |
                              v
   4. query the index of your history and notes
      rows with a question word, OR for the guessed tool;
      the question's words count most
                              |
                              v
   5. print, each with where it came from
      xrandr -s 1920x1080
        # most likely (model suggestion)
      xrandr --output HDMI-1 --mode 2560x1440
        # your history x3
```

So the model's guess is used twice: it leads the search to the right tool,
and it is printed as a suggestion of its own. Because your own words count
most, a wrong guess doesn't hide a command that matches what you asked.

The index is built from your history and the notes you register. Repeats are
merged into one row with a use count, trivial commands (`ls`, `cd`, ...) and
lines that look like secrets are dropped, and `# comments` become searchable
notes. It rebuilds by itself when a source changes.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains each step in detail,
including how to read the debug output. [DESIGN.md](DESIGN.md) records why
it works this way.

## Install

You need:

- bash, curl and jq
- Python 3 with SQLite FTS5 (standard library only, no pip packages)
- [Ollama](https://ollama.com), on this machine or another host
- man-db (`apropos`), optional, for man page summaries

Check that your Python has FTS5:

```bash
python3 -c "import sqlite3; sqlite3.connect(':memory:').execute('create virtual table t using fts5(x)'); print('ok')"
```

Install the two scripts and pull the default model:

```bash
install -Dm755 hint ~/.local/bin/hint
```

```bash
install -Dm755 hintdb ~/.local/bin/hintdb
```

```bash
ollama pull qwen2.5-coder:3b
```

For commands from your current shell session to be found, bash has to write
its history after each command. Add this to `~/.bashrc`:

```bash
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

### Sources

On first use, `hintdb` registers your bash history (`$HISTFILE`, or
`~/.bash_history`). Add the notes files, justfiles and Makefiles you keep for
work on this machine:

```bash
hintdb add ~/notes/kubernetes.md ~/src/myproject/justfile
```

Git aliases (the `[alias]` section of a git config file) and bash aliases
(`alias name='body'` lines) can be added the same way. Each alias is found by
its comments and its body:

```bash
hintdb add ~/.gitconfig ~/.bash_aliases
```

Register files rather than whole folders of old notes: commands for tools
you no longer use come back as noise. `[include]` in a git config is not
followed, so add the included file itself.

## Usage

```bash
hint how do I create an ssh tunnel
```

```bash
hint dns lookup
```

A comment on a command makes it findable by what it does, next time:

```bash
ssh-keygen -R oldhost.example.org  # remove old host key known_hosts
```

### When hint didn't find it

If hint missed and you found the command some other way, run it, then tell
hint it was the answer:

```bash
hint answer
```

hint shows your last question and your last command, on a line you can
edit. Press Enter to save it, or Ctrl-C to cancel. The question is saved as
a comment on the command, so the next similar question finds it, even if
the model guesses the wrong tool again.

If you ran other commands after it, name the command's tool instead. This
takes the last line that runs `ss`, also inside a pipeline:

```bash
hint answer ss
```

`hint answer` reads your history file, so the command has to be written to
it first. With `history -a` in `PROMPT_COMMAND` (see Install) it always is.
Without it, for example on a server, write it first:

```bash
history -a; hint answer
```

Answers are kept in `~/.local/share/hintdb/answers`, one `command  #
question` line each. To change or remove one, edit that file.

### Past lookups

Every lookup is kept in a local query log, and these commands read it
without asking the model.

The last 10 lookups, like bash `history`:

```bash
hint history
```

Past questions containing a word:

```bash
hint history tunnel
```

Commands you were given that contain a word:

```bash
hint search rsync
```

The full answer of lookup 57, with the files each of your rows came from:

```bash
hint history --show 57
```

Delete lookups you didn't mean, like bash `history -d`:

```bash
hint history --delete 41,42
```

`history` and `search` take at most one word. With two or more words the
line is a question for the model, so `hint history without duplicates` is
asked as usual. To search for several words, use `-H` or `-S`:

```bash
hint -H ssh key
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `HINT_MODEL` | `qwen2.5-coder:3b` | Ollama model |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `HINT_DEBUG` | unset | print the model's guesses and the search scores to stderr |
| `HINTDB_IGNORE` | empty | extra command words never to index (space-separated) |
| `HINTDB_NO_MAN` | unset | disable the man page index |
| `HINTDB_DB` | `~/.local/share/hintdb/hint.db` | index location |
| `HINTDB_MANDB` | next to `HINTDB_DB` | man page index location |
| `HINTDB_SOURCES` | `~/.config/hintdb/sources` | list of sources |
| `HINTDB_APROPOS` | `apropos .` | command that lists man page summaries (for testing) |
| `HINTDB_LOG` | `~/.local/share/hintdb/queries.jsonl` | query log; `/dev/null` turns it off |
| `HINTDB_ANSWERS` | `~/.local/share/hintdb/answers` | answers saved by `hint answer`; `/dev/null` turns them off |
| `HISTFILE` | `~/.bash_history` | the history `hint answer` reads; export it if yours is elsewhere |

The query log stays on your machine, like your shell history, and contains
commands from it.

## Limitations

- **A question that doesn't name the tool** finds your command only through
  its words. If you use a less common tool than the one the model guesses,
  and none of the question's words are on your command, it isn't found. A
  bigger model doesn't change that; a `# comment` on the command does.
- **Hosts without a dot** (`ssh myserver`) aren't recognised as hosts, so
  each one stays a separate row.
- **Long and short options** (`-r`, `--recursive`) aren't treated as the same.
- **Bash history without timestamps** gives only rough recency (line order).

## Reference

### hint options

| Form or option | Meaning |
|---|---|
| `-H`, `--history [WORD...]` | past questions containing all WORDs (no words: every lookup) |
| `-S`, `--search WORD...` | past commands containing all WORDs |
| `-n`, `--last N` | only the last N matching lines (default 10) |
| `-c`, `--count` | print the number of matching lines instead |
| `-s`, `--show NUM` | the full answer of lookup NUM, with your rows' source files |
| `-d`, `--delete NUM[,NUM\|NUM-NUM]...` | delete lookups from the log |
| `answer [TOOL]` | save your last command, or your last TOOL command, as the answer to the last question |

`-n` and `-c` work after `history`, `search`, `-H` and `-S`. `--show` and
`--delete` work only after `history` and `-H`, on their own. `hint help`
prints the usage; `hint help me ...` is a question.

### hintdb commands

| Command | Purpose |
|---|---|
| `hintdb add PATH... [--kind history\|md\|text\|just\|make]` | register sources and rebuild |
| `hintdb remove PATH...` | unregister sources and rebuild |
| `hintdb sources` | list registered sources |
| `hintdb rebuild` | force a full rebuild |
| `hintdb update` | rebuild only if something changed |
| `hintdb stats` | rows per kind and per source file (and how many come only from that file) |
| `hintdb stats --source PATH` | the rows from one source file or directory, most used first |
| `hintdb find [--debug] -q QUESTION [GUESS...]` | your commands for a question and the model's guesses (used by `hint`) |
| `hintdb log ...` | read and edit the query log (used by `hint history` and `hint search`) |
| `hintdb answer [TOOL]` | the last question and the command that answers it (used by `hint answer`) |
| `hintdb query [-n N] WORDS...` | the search for the words alone, with scores (debugging) |

Source kinds are detected from the file name. Use `--kind` to override, for
example for an old history file:

```bash
hintdb add --kind history ~/.bash_history.old
```

## Tests

```bash
tests/run.sh
```

The tests use synthetic fixtures and a stub Ollama server, so they need no
model and never touch your index, history or query log. To measure hint on
your own questions with a real model, see [eval/README.md](eval/README.md).
