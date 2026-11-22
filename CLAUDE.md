# CLAUDE.md

How to work on `hint` and `hintdb`. Design decisions are in DESIGN.md; change
them only with agreement. README.md covers usage and architecture.

## Principles

- **Keep it simple.** Prefer the smallest change that fixes an observed
  problem. Don't add tables of per-tool flag semantics, extra model calls or
  new subsystems unless a real query shows they're needed. When unsure,
  describe the option and ask rather than building it.
- **Design before code.** For a change to the pipeline (what is called, in
  what order, what flows between steps), show an ASCII data-flow diagram traced
  with a real example query, and get agreement before implementing. If asked
  not to implement yet, don't. Update DESIGN.md once a design change is agreed.
- **Fix one thing at a time.** Keep guess (prompt/model) fixes separate from
  match/ranking fixes, so each can be measured on its own.

## Constraints

- `hintdb`: Python 3 stdlib only (sqlite3 with FTS5). No pip dependencies.
- `hint`: a standalone bash script on PATH, not a function sourced from
  `.bashrc`. Dependencies: curl, jq, hintdb.
- ASCII only in code, docs and output.
- In user-facing docs, each command goes in its own code block, with no
  output mixed into the same block.
- **Bump `SCHEMA_VERSION`** in `hintdb` whenever the table layout or any
  cleaning, shape or note rule changes, so existing databases rebuild by
  themselves. Forgetting this leaves stale rows that make tests look wrong.

## Testing

- Run `tests/run.sh`. It uses only `tests/fixtures` and the stub server
  `tests/stub_ollama.py`, and never touches the real index, history or Ollama.
- Never commit or paste real shell history. Fixtures are synthetic and use
  example hostnames (example.org, 192.0.2.x, 2001:db8::). Add a fixture line and
  a check to `tests/run.sh` for each behaviour that changes or each bug fixed.
- Check designed behaviour only. Known limitations (README) are not encoded as
  expected results.
- Isolate test runs from the real index with `HINTDB_DB`, `HINTDB_SOURCES` and
  `HISTFILE` pointing into a scratch directory, and `HINTDB_NO_MAN=1` or
  `HINTDB_APROPOS="cat <fake apropos output>"` for man pages.
- Test `hint` against a stub HTTP server that mimics `/api/chat`, including
  messy replies (fences, numbering, `$ ` prompts) and replies that ignore
  instructions.
- Before handing over a change, run `tests/run.sh` (it also checks syntax,
  ASCII and that both scripts are executable), and show the affected
  `hintdb find --debug` output (what `HINT_DEBUG=1 hint ...` prints).
- The user tests locally on the real machine with real history. Ask for
  `HINT_DEBUG=1` output when a result looks wrong, and diagnose from the score
  table before changing anything.

## Accuracy

- Say plainly what was verified and what wasn't. Ollama API fields,
  `apropos` output format and man-db paths were written from documentation
  knowledge and tested only against stubs; flag that rather than presenting it
  as confirmed.
- Show real output from test runs, not expected output.
