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
hint remember
```

hint shows your last question and the last command you ran after it, on a
line you can edit. Press Enter to save it, or Ctrl-C to cancel. The question is saved as
a comment on the command, so the next similar question finds it, even if
the model guesses the wrong tool again.

If you ran other commands after the right one, name its tool instead. This
takes the last line since your question that runs `ss`, also inside a
pipeline:

```bash
hint remember ss
```

`hint remember` reads your history file, so the command has to be written to
it first. With `history -a` in `PROMPT_COMMAND` (see Install) it always is.
Without it, for example on a server, write it first:

```bash
history -a; hint remember
```

Answers are kept in `~/.local/share/hintdb/answers`, one `command  #
question` line each. To change or remove one, edit that file.

### Removing a wrong command

A wrong command that looks right, such as `history -n 10` (`-n` takes no
count), keeps coming back: each time you run it, it is in your history
once more. After trying it, mark it as wrong. hint takes the first command
you ran after your last question:

```bash
hint forget
```

Or name its tool, to take the first line since your question that runs it:

```bash
hint forget history
```

If you haven't run anything since the question (you saw it was wrong in
hint's answer), `hint forget` lists the commands that answer printed,
numbered, and you choose one, so a wrong suggestion is marked without
running it.

hint shows the command on a line you can edit, then asks for an optional
reason, and saves it to `~/.local/share/hintdb/wrong` as a marked line:

```text
history -n 10  # WRONG: -n takes no count
```

hint then never shows that exact command again, from any of your sources,
even after you run it again, and labels it when the model suggests it.
Other commands stay, such as `history -n`. `hintdb stats` lists the
commands you have marked. To undo a mark, delete its line from that file.

The same comment works in your own files: a comment that starts with
`WRONG` as a whole word, in capitals, on a line in your bash history marks
the command too: `# WRONG`, `# WRONG!` or `# WRONG: reason`.

#### Cleaning it out of your bash history

`hint forget` doesn't change your bash history, so the command is still
there for up-arrow and Ctrl-R. It tells you the line numbers. To delete
them while other terminals are open:

1. Write this terminal's history to the file first, unless your shell does
   it after each command:

   ```bash
   history -a
   ```

2. Edit the file, delete the lines from the last one up (so the other line
   numbers stay right), and save soon: other terminals keep appending to
   it.
3. In this terminal and every other open one, reload the history. The
   leading space keeps the line itself out of history:

   ```bash
    history -a; history -c; history -r
   ```

   Don't use `history -n` after an edit: it skips as many new lines as you
   deleted.

### Checking a command's flags

hint often finds the right tool in the wrong form: for "connect to port
4567" a model may suggest `nc -l 4567`, and `-l` listens instead. Before
running a suggestion, check what its flags do:

```bash
hint flags nc -l 4567
```

```
nc -l  Listen for an incoming connection rather than initiating a connection to
       a remote host. ...
```

The text comes from the tool's own documentation: `help` for a bash builtin
(`hint flags history -n 10`), otherwise its man page, the subcommand's page
first (`hint flags git commit --amend` reads git-commit(1), then git(1)). No
model is asked, and the command is never run, not even with `--help`. Quote
a pipeline, so the shell doesn't act on it:

```bash
hint flags 'sudo lsof -i -P -n | grep LISTEN'
```

Each command of the pipeline is explained in turn. A grouped `-tuln` is read
one letter at a time, as the tool itself reads it, and a flag's value
(`-n 10`, `-u postgres`) is not looked up. A flag the page doesn't list says
`not in nc(1)`; nothing is guessed.

### Past lookups

Every lookup is kept in a local query log, and these commands read it
without asking the model.

The last 10 lookups, like bash `history`; add a number for more:

```bash
hint history
```

```bash
hint history 30
```

Past lookups containing a word, in the question or in a command they
showed you, like `history | grep` in bash. A command that matched is shown
under its lookup:

```bash
hint grep rsync
```

The full answer of lookup 57, with the files each of your rows came from:

```bash
hint history --show 57
```

Delete lookups you didn't mean, like bash `history -d`:

```bash
hint history --delete 41,42
```

`grep` takes one word, and a number is a word: `hint grep 5432` finds the
lookup that showed a command with port 5432. With two or more words the
line is a question for the model, so `hint grep recursively for a word` is
asked as usual. To look for several words, quote them; each word must
match:

```bash
hint grep "ssh key"
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `HINT_MODEL` | `qwen2.5-coder:3b` | Ollama model |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server |
| `HINT_KEEP_ALIVE` | unset (the server's setting) | how long Ollama keeps the model loaded after a lookup: `2h`, `-1` (until Ollama restarts), `0` (unload at once) |
| `HINT_OLLAMA_OPTIONS` | unset | Ollama model options as one JSON object, laid over hint's own (`temperature` 0, `num_predict` 120) |
| `HINT_TIMEOUT` | `60` | seconds to wait for Ollama; loading a larger model can take longer |
| `HINT_THINK` | `false` | thinking mode for models that have one: `true`, `false`, or a level such as `low` |
| `HINT_DEBUG` | unset | print the model's guesses and the search scores to stderr |
| `HINTDB_IGNORE` | empty | extra command words never to index (space-separated) |
| `HINTDB_NO_MAN` | unset | disable the man page index |
| `HINTDB_DB` | `~/.local/share/hintdb/hint.db` | index location |
| `HINTDB_MANDB` | next to `HINTDB_DB` | man page index location |
| `HINTDB_SOURCES` | `~/.config/hintdb/sources` | list of sources |
| `HINTDB_APROPOS` | `apropos .` | command that lists man page summaries (for testing) |
| `HINTDB_LOG` | `~/.local/share/hintdb/queries.jsonl` | query log; `/dev/null` turns it off |
| `HINTDB_ANSWERS` | `~/.local/share/hintdb/answers` | answers saved by `hint remember`; `/dev/null` turns them off |
| `HINTDB_WRONG` | `~/.local/share/hintdb/wrong` | commands marked by `hint forget`; `/dev/null` turns it off |
| `HISTFILE` | `~/.bash_history` | the history `hint remember` reads; export it if yours is elsewhere |

For example, a larger model kept loaded for two hours, with 12 of its layers
on the GPU:

```bash
export HINT_MODEL=qwen2.5-coder:7b
```

```bash
export HINT_KEEP_ALIVE=2h
```

```bash
export HINT_OLLAMA_OPTIONS='{"num_gpu": 12}'
```

```bash
export HINT_TIMEOUT=120
```

`HINT_DEBUG=1` prints the model, keep_alive, think, timeout and options each
lookup sends, and a thinking model's reasoning. Ollama ignores an option name
it does not know, with only a warning in its own log, so check the spelling
there if a setting seems to have no effect.
Ollama loads a model on the first lookup after it was unloaded (by default
after 5 minutes idle); that lookup takes longer.

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
- **`hint flags`** reads options that start with `-` (and `+` ones the page
  lists, as dig's). Operands such as dd's `if=` and old-style `tar xvf`
  aren't flags to it. Man pages laid out differently from the usual option
  lists give less, and a tool without a man page or builtin help gives
  nothing.

## Reference

### hint options

| Form or option | Meaning |
|---|---|
| `history [N]` | your last 10 lookups, or the last N |
| `history -s`, `--show NUM` | the full answer of lookup NUM, with your rows' source files |
| `history -d`, `--delete NUM[,NUM\|NUM-NUM]...` | delete lookups from the log |
| `grep [-c] WORD` | past lookups whose question or commands contain WORD; `-c`: just the number |
| `remember [TOOL]` | save your last command, or your last TOOL command, as the answer to the last question |
| `forget [TOOL]` | mark the first command after your last question, or the first TOOL command, as wrong, so hint never shows it |
| `flags COMMAND...` | what each flag of COMMAND does, from the builtin's help or the man page; quote a pipeline |

`--show` and `--delete` stand alone. `hint help` prints the usage; `hint
help me ...` is a question.

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
| `hintdb log ...` | read and edit the query log (used by `hint history` and `hint grep`) |
| `hintdb remember [TOOL]` | the last question and the command that answers it (used by `hint remember`) |
| `hintdb forget --where -- COMMAND` | the files and lines that hold COMMAND, and where it is marked |
| `hintdb forget --save [--reason R] -- COMMAND` | mark COMMAND as wrong (used by `hint forget`) |
| `hintdb flags -- COMMAND...` | what each flag of COMMAND does (used by `hint flags`) |
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
