# DESIGN.md

Design decisions for `hint` and `hintdb`. README.md covers usage and the
architecture diagram; this file records what the system must do and why.

## Purpose

Answer "what was that command again?" from the user's own shell history and
notes, in the form the user actually uses. Nothing is ever executed.

## Components

- `hint` (bash script on PATH): makes one LLM call to guess 1-3 commands, then
  passes the guesses to `hintdb match`.
- `hintdb` (Python, single file, stdlib only): builds the index from history,
  notes, justfiles and man NAME lines, and matches guesses against it.

## Lookup

1. **Guess.** One call to Ollama's chat API (`/api/chat`) at temperature 0.
   The rules go in the system message; the worked example goes in as a prior
   user/assistant exchange, never as inline text the model could continue.
   There is only one model call per lookup. Adding a compose or query-expansion
   call is a design change.
2. **Match.** For each guess, only rows for the same tool (command word) are
   considered. Score:
   1. overlap of option flags (`-x`, `--long`, `+opt`; values after `=`
      ignored), or of all argument tokens if the guess has no flags
   2. overlap of all argument tokens (tie-breaker)
   3. use count (last tie-breaker)

   A row matches when its flag score is >= `HINTDB_MATCH_MIN` (default 0.5).
3. **Installed only.** A command is shown only if its tool is installed here
   (on PATH, or a just recipe). This applies to the user's rows and to model
   guesses alike, and is checked at lookup time, so installing a tool later
   brings its rows back without a rebuild. Asking about tools that are not
   installed is not hint's job; it says so and stops there.
4. **Output.** Two lines per result: the command, then a `#` status line
   saying where it came from. Nothing is executed. In this order:
   1. **The user's rows** (case 1: "I've run this before"): rows that match a
      guess, best first, up to 5 in total, taken round-robin over the guesses
      (each guess's best row first). The guess says which words matter: its
      literal words (not flags or placeholders, e.g. `list` in
      `docker exec -it ollama ollama list`). The best row is always shown;
      extra rows must keep at least half of those words. Rows with the same
      flags and the same kept words differ only in values and are shown once,
      the best-scoring one. So `ssh-keygen -f <PATH> -R <HOST>`, `-R oldhost`
      and `-R <HOST> -f <PATH>` show as one row, while `kubectl get pods`,
      `-A` and `--show-labels` show as separate rows. This only hides rows for
      that lookup; the index keeps them all.
   2. **Model suggestions** (case 2: "I don't know the command"): guesses with
      no matching row, plus guesses whose shape differs from the matched row.
      The first is labelled "most likely", the others "alternative", followed
      by `see man <tool>(<section>)` once per tool that has a man page.
   3. **Not installed**, as `#` comments only, never as commands:
      - rows from the user's sources:
        `# found in <source>, but <tool> is not installed here:` then the rows
      - model guesses, when no installed command was printed at all:
        `# no installed command found; the model suggested the following:`
        then the guesses

   A wrong first guess must not push the user's command below a model
   suggestion: the user's rows always come first, each group in guess order.

## Index

- **Sources:** bash history, markdown and text notes, justfiles. Man NAME
  lines (sections 1 and 8, from `apropos .`) go into a separate `man.db`.
- **Cleaning:** drop trivial commands (unless annotated), lines that look like
  secrets, `hint`/`hintdb` lines plus `HINTDB_IGNORE`, and one-off history
  lines whose command is not on PATH.
- **Shapes:** values become placeholders (`<HOST>`, `<USER@HOST>`, `<PATH>`,
  `<FILE>`, `<STR>`, `<URL>`, `<HEX>`, `<N>`). Flags stay exactly as written.
  Quotes around a single token are ignored. Commands with the same shape merge
  into one row with a use count, a display template (tokens that vary become
  placeholders) and two real examples. Rows are not merged any further in the
  index: grouping by flags alone (tried 2026-11-16) merged commands whose
  positional words matter (`docker exec -it ollama ollama list` / `... ps`,
  `mount -t cifs` / `-t nfs`, `git rev-parse --short HEAD` / `origin/main`).
- **Source:** each row records the source files it came from, for the
  "found in <source>" message.
- **Notes:** a note belongs to the variant it came from. It appears on a merged
  row only when variants carrying it make up at least half the uses; otherwise
  it is shown only next to its own example. All notes stay searchable.
- **Rebuilds:** always full, into a temp file, then an atomic replace. A
  rebuild is triggered automatically when a source file, the man-db index, the
  schema version or `HINTDB_IGNORE` changes.

## Known limitations

Listed in README.md under "Limitations". Each is addressed only when a real
query is affected.
