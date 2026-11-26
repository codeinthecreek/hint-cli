# How hint works

`hint` answers a question like "how do I create an ssh tunnel" with commands
you have actually run, found in your shell history and notes, alongside a
command suggested by a local LLM. This page explains how that works, step by
step. [README.md](../README.md) covers installing and using hint;
[DESIGN.md](../DESIGN.md) records why each part is the way it is, with the
measurements behind it.

## The big picture

There are two programs:

- `hint`, a bash script, asks the model and prints the answer.
- `hintdb`, a Python script, keeps an index of your commands and searches it.

Traced with one question:

```text
             $ hint how do I set the screen resolution
                               |
                               | the question
             +-----------------+------------------+
             |                                    |
             v                                    |
   1. ASK THE MODEL  (Ollama)                     |
      "which commands do this?"                   |
             |                                    |
             | the guess:                         |
             |   xrandr -s 1920x1080              |
             v                                    v
   2. TAKE THE GUESS APART              3. TAKE THE QUESTION'S WORDS
      tool   xrandr                        drop filler words
      flags  -s                            (how, do, I, the)
      words  xrandr                               |
             |                                    |
             | tool  -> finds rows + ranks        | words: set screen resolution
             | flags -> ranks only                |   -> finds rows + ranks
             | words -> ranks only                |
             |                                    |
             +-----------------+------------------+
                               |
                               v
   4. QUERY THE INDEX   <--- your rows --- INDEX (hint.db), built from your
                                           history, notes, justfiles, aliases
      which rows:   a question word is in the row,
                    OR the row is for the guessed tool
      ranking:      question words count most;
                    tool, matching flags and guess words add a little
                               |
                               | your best rows, ranked:
                               |   xrandr --output HDMI-1 --mode 2560x1440
                               | the guess, as the model wrote it:
                               |   xrandr -s 1920x1080
                               v
   5. PRINT, each line labelled
      xrandr -s 1920x1080
        # most likely (model suggestion)
      xrandr --output HDMI-1 --mode 2560x1440
        # your history x3
```

`hint` runs step 1 and passes the question and the guess to `hintdb find`,
which runs steps 2 to 5. Steps 2 and 3 turn the question and the guess into
the terms for step 4, the query on the index.

Your `xrandr` line contains none of the question's words, so the question's
words alone find nothing. The guessed tool is what brings it in. The guess's
flags (`-s`) don't match yours (`--output --mode`), so they add nothing here.

The model and the index each know something the other doesn't:

- **The model knows the vocabulary.** It knows that "screen resolution" means
  `xrandr`, even though nothing in your history says "screen" or "resolution".
- **Your index knows your machine.** It has the hosts, paths and options you
  actually use, which no model can know.

So the model's guess is used twice. It is a search term that leads the search
to the right tool, and it is printed as a suggestion of its own, for questions
your history can't answer.

## 1. Building the index

`hintdb` reads your registered sources, and the answers saved by `hint
answer`, and turns every command in them into a row of a SQLite full-text
index (`hint.db`).

**What is read from each kind of source:**

| Source | Commands | Notes (searchable text attached to the command) |
|---|---|---|
| bash history | every line | a trailing `# comment` |
| markdown and text notes | lines in shell code blocks, `$ ` lines | the heading, the prose line or `# comment` above |
| justfiles, Makefiles | single-command recipe lines | `just <recipe>` / `make <target>` and the doc comment |
| git aliases | `git <alias>` | the comment above, the section heading, the body |
| bash aliases | the alias name | the comment above the block, the body |
| answers (`hint remember`) | every line | the question it answered |

**What is dropped:** trivial commands (`ls`, `cd`, `vim file`, ...) unless they
carry a note, lines that look like secrets, `hint` and `hintdb` themselves,
probable typos (a one-off command that isn't on your `PATH`), and commands
you marked as wrong with a `# WRONG` comment on one of their history lines.

**Merging repeats.** Commands that differ only in their values are one row.
Values become placeholders, while flags are kept as you wrote them:

```text
ssh -L 8080:localhost:80 -i ~/.ssh/key user@gpu1.example.org
ssh -L 8080:localhost:80 -i ~/.ssh/key user@gpu2.example.org
        |
        v
ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>       used 2 times
```

Each row keeps its use count, two real examples, its notes and the files it
came from.

**Man pages.** The one-line summaries of installed commands (from
`apropos .`) go into a second index, `man.db`, so a suggested tool can be shown
with what it does.

**When it rebuilds.** Before each lookup, `hintdb` checks whether any source
file, the man page index or the index format has changed, and if so rebuilds
from scratch.

## 2. Answering a question

The example: `hint how do I set the screen resolution`, with this line three
times in your history:

```text
xrandr --output HDMI-1 --mode 2560x1440
```

### Guess

`hint` sends the question to Ollama (temperature 0, for steady answers) and asks for 1-3 commands, one per line, using a
different tool on each line if it isn't sure. The reply is cleaned up: code
fences, numbering, `$ ` prompts and prose lines are removed.

```text
xrandr -s 1920x1080
```

If Ollama can't be reached, `hint` says so and stops. If the reply is empty
or is all prose, the search still runs on the question's words alone.

### Find

`hintdb find` gets the question and the guesses.

**Which rows are considered.** A row is a candidate if it contains a word of
the question (by stem, so "tunnels" finds "tunnel") OR it is for a tool the
model guessed. The second path is what finds your `xrandr` line: it contains
none of the words "set", "screen" or "resolution".

**How they are ranked.** Each candidate gets a score made of parts:

| Part | Weight | What it measures |
|---|---|---|
| question words | 1.0 | how well the row matches the question's words (bm25, best row = 1); your `# comments` count extra |
| guessed tool | 0.3 | the row is for a guessed tool (full credit for the first guess's tool) |
| shared flags | 0.3 | the row has the same flags as a guess for that tool |
| guess words | 0.3 | the row contains the guesses' words (the tool, subcommands, names), not their flags |
| use count | 0.02 | small tie-breaker: commands you use more often |

Your own words weigh the most. A wrong guess therefore adds a little to the
wrong tool's rows, but it doesn't hide a row that matches what you asked.

**Which of your rows are kept.** The best 5. Rows that differ only in values
show once, and rows that match nothing but the tool's name (plain
`ssh <host>` for "ssh tunnel") show once per tool. Commands that aren't
installed on this machine are listed as `#` comments rather than commands.

### Print

Your best row comes first if it contains more than half of the question's
words (rare words count more). Otherwise the model's first guess comes first,
marked "most likely". Here your row has none of the question's words, so the
guess leads:

```text
xrandr -s 1920x1080
  # most likely (model suggestion)
xrandr --output HDMI-1 --mode 2560x1440
  # your history x3
```

Every result is two lines: the command, then where it came from. Further
guesses follow, then a `# see man <tool>` line for each suggested tool.
Nothing is ever executed.

Without the guess, the same question finds nothing, and `hint` asks you to
rephrase.

### Log

The question, the guesses and the printed lines are added to a local query
log (`queries.jsonl`), which `hint history` reads without
asking the model.

### Remember

When a lookup missed, `hint remember` takes the last question from the log and
your last command from your history file, and after you confirm it appends
`command  # question` to the answers file. That file is read like history,
so the question becomes a comment on your command's row, and the next
similar question finds it by its words.

### Forget

`hint forget` is the opposite: for a wrong command, it saves `command  #
WRONG: reason` to the wrong file. A line marked `# WRONG` in any history
file drops that exact command from the index, from every source, and a
model suggestion of it is labelled. `hint forget` also says where the
command is still in your history, if you want to delete it there too.

## 3. Debugging a lookup

`HINT_DEBUG=1` shows what the model guessed and how each candidate scored:

```bash
HINT_DEBUG=1 hint how do I create an ssh tunnel to postgres
```

```text
hint: model guesses:
ssh -L 5433:localhost:5432 user@postgres-server
hintdb: words: ['create', 'ssh', 'tunnel', 'postgres']
hintdb: guessed tools: ['ssh']  guess words: ['ssh', 'postgres']
hintdb:    score   bm25 tool flags gwords  uses   command
hintdb:    1.750   1.00  1.0  0.50   1.00  x1      ssh -N -L 5432:localhost:5432 db.example.org  # tunnel to postgres
hintdb:    0.601   0.05  1.0  0.50   0.30  x2      ssh -L 8080:localhost:80 -i ~/.ssh/key user@<HOST>
hintdb:    0.593   0.04  1.0  0.50   0.30  x2      ssh -L 0.0.0.0:11434:localhost:11434 -i ~/.ssh/key user@<HOST>
hintdb:    0.518   0.11  1.0  0.00   0.30  x2      ssh buildhost
...
hintdb: best row holds 0.71 of the question's words -> user's row leads
```

The columns are the parts of the score above, before weighting: `bm25` for
the question's words, then the guessed tool, shared flags and guess words.
The top row wins because its `# tunnel to postgres` comment matches the
question.

When your command isn't shown, the table usually tells you why:

- **It's not in the table.** None of the question's words are in it, and the
  model guessed a different tool. Add a `# comment` to the command in your
  history, using the words you would ask with.
- **It's in the table but ranked low.** Look at which columns are low. A
  wrong tool guess shows as `tool 0.0` for your row.
- **The guesses are the wrong tool.** The question probably doesn't name the
  tool, and you use a less common one than the obvious answer. A bigger model
  doesn't fix this (tried, see DESIGN.md). Naming the tool in the question or
  commenting the command does.

Two more views of the index:

```bash
hintdb stats
```

prints how many rows each source contributes, and how many come only from
that source (what removing it would lose).

```bash
hintdb query remove host key
```

ranks the index for the words alone, without asking the model.

## Files

| File | What it is |
|---|---|
| `hint` | bash script: asks the model, prints the answer |
| `hintdb` | Python script (stdlib and SQLite FTS5): index, search, query log |
| `~/.config/hintdb/sources` | your registered sources |
| `~/.local/share/hintdb/hint.db` | the index of your commands |
| `~/.local/share/hintdb/man.db` | man page summaries |
| `~/.local/share/hintdb/queries.jsonl` | the query log |
| `~/.local/share/hintdb/answers` | answers saved by `hint remember` |
| `~/.local/share/hintdb/wrong` | commands marked by `hint forget` |
