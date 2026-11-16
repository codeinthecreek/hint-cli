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
3. **Output.** Two lines per result: the command, then a `#` status line
   saying where it came from. The user's usage takes precedence over the
   model's guess:
   - **exact** (identical shape): the user's row only
   - **partial** (best flag score >= `HINTDB_MATCH_MIN`, default 0.5): the
     user's row, then the guess
   - **no match**: the guess alone, with the tool's man summary, or a
     "not installed" note if the tool has no rows and is not on PATH

   Across guesses, all of the user's rows are printed first, then all model
   suggestions, each group in guess order. A wrong first guess must not push
   the user's command below a model suggestion.

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
  placeholders) and two real examples.
- **Notes:** a note belongs to the variant it came from. It appears on a merged
  row only when variants carrying it make up at least half the uses; otherwise
  it is shown only next to its own example. All notes stay searchable.
- **Rebuilds:** always full, into a temp file, then an atomic replace. A
  rebuild is triggered automatically when a source file, the man-db index, the
  schema version or `HINTDB_IGNORE` changes.

## Known limitations

Listed in README.md under "Limitations". Each is addressed only when a real
query is affected.
