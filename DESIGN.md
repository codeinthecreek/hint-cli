# DESIGN.md

Design decisions for `hint` and `hintdb`. README.md covers usage and the
architecture diagram; this file records what the system must do and why.

## Purpose

Answer "what was that command again?" from the user's own shell history and
notes, in the form the user actually uses. Nothing is ever executed.

## Components

- `hint` (bash script on PATH): makes one LLM call to guess 1-3 commands, then
  passes the query and the guesses to `hintdb find`.
- `hintdb` (Python, single file, stdlib only): builds the index from history,
  notes, justfiles and man NAME lines, and finds the user's rows for a query.
  `hintdb find --debug` shows the score parts. `hintdb query` stays for
  debugging: `find`'s ranking for the words alone (no model guesses), each
  row with its score, then matching man NAME lines. `hintdb match` (guesses only, by
  flag overlap) is dropped: `find` replaces it, and its flag overlap is one
  of `find`'s score parts.

## Lookup

1. **Guess.** One call to Ollama's chat API (`/api/chat`) at temperature 0.
   The rules go in the system message; the worked example goes in as a prior
   user/assistant exchange, never as inline text the model could continue.
   There is only one model call per lookup. Adding a compose or query-expansion
   call is a design change.
   The model's job is to interpret the question: its guesses translate the
   user's words into likely tools and words (e.g. `ss` for "list open
   ports"). Its commands are a fallback for things the user has not run.
   Asking it for tools and words instead of commands (tried 2026-11-16: 28
   hits vs 27 at tool weight 0.3, one suggestion instead of three, the rsync
   example lost at weight 0.6) did not justify a prompt change.

   **Different tools when unsure.** The system message ends with "If you
   are not sure which tool fits, use a different tool on each line." With
   the prompt before it the model nearly always gave one command (121 of
   163 eval questions), so a wrong tool guess hid the user's row; a wrong
   tool guess was behind 26 of 30 misses (2026-11-18, benchmark and
   hold-out). With the sentence: 2 commands in most replies, the right tool
   among the guesses in 61 of 89 questions instead of 58, and 4 questions
   that showed nothing useful now do (none lost). The cost: 5 useful
   answers move down from the first line (3 move up), noise more in 14
   questions and less in 9. The model is not fully repeatable at
   temperature 0 (re-asking changed the guesses of 17 of 163 questions),
   so differences of a few questions are within noise.

   Tried and rejected 2026-11-18, same questions: "Use a different tool on
   each line" always (same 4 fixed, slightly more useful answers moved
   down and more noise); a worked example with 3 commands of 3 tools, with
   and without the sentence, and with a second example showing 3 forms of a
   named tool. The examples made the model fill all 3 lines, mostly with
   the same tool (replies repeating a tool 23 -> 56 to 100), fixed the
   same few questions and added noise (more in up to 27 questions); the
   second example lost "how do I shut down kubernetes".

   **When the model fails**, the two cases are reported differently:
   - **No connection** (Ollama not running, wrong host, timeout, or an
     error from Ollama such as an unknown model): hint says which, names
     the host and model, and exits 1. It is a setup problem, not a question
     to rephrase.
   - **Nothing usable** (empty reply, or nothing left after cleaning;
     cleaning drops prose such as "I'm sorry, but I can't assist with
     that", markdown bold and `#` comment lines: a line starting with `#`
     or `**`, or whose first word starts with a capital letter and is not
     an installed command, so `VBoxManage` stays; the first 3 lines left
     are the guesses): the
     lookup still runs on the query words alone, since the user's history
     comments may answer it. If nothing at all is printed, hint says
     "Sorry, I didn't understand your question, can you rephrase it?".
2. **Find.** The guesses are not templates the user's rows must resemble: they
   supply likely tools and words. The user's own words (query, history
   comments) carry the most weight, so a wrong tool guess does not hide the
   user's command.
   1. **Words.** Query terms (stopwords dropped); the guesses' tools (command
      words, in guess order); the guesses' literal words (not flags, not
      filler such as `path`, `user`, `server`).
   2. **Where words count.** In a row's command, arguments and note. Also in
      its paths and other values only when the query mentions a path: it
      contains `/` or `~`, or the word dir, directory, folder or path
      (singular or plural). Words match by stem (SQLite FTS5's porter
      stemmer): `tunnels` finds `tunnel`, `listing` finds `list`, but
      `dir` does not find `directory` and `post` does not find `postgres`.
      Matching by prefix (the first n-2 letters) was replaced 2026-11-17: it
      pulled in unrelated words (`post` -> `postgres`, `caps` -> `capture`).
      On the eval sets (see "What counts as a useful answer") porter vs
      prefix: benchmark useful first 54 vs 52, not shown 14 vs 16, junk 95
      vs 107; hold-out about the same; questions 8 vs 9 useful first.
   3. **Word weight.** Rarer words count more:
      `ln(1 + rows / (1 + rows containing the word))`. Used for the
      guesses' words and for "Who leads"; the query words are weighted by
      bm25 (below).
   4. **Candidates.** Every row that contains a query word OR is for a guessed
      tool. (Requiring both was tried 2026-11-16: it drops the rows where the
      model guessed the wrong tool, e.g. `setxkbmap` for "disable caps lock".)
      A guessed tool written `a-b` also counts as `a b` when the user's rows
      use that form: the model often writes `docker-compose up -d` where the
      user types `docker compose up -d`. The user's rows decide, not a list
      of tools (no `ssh keygen` rows, so `ssh-keygen` stays as it is). It
      changes scoring only; the guess is printed as written. Added
      2026-11-18: fixed "stop docker compose" (nothing useful -> exact first)
      with no other change; on the current index also "start docker compose".
   5. **Score**, starting values chosen on the eval set (65 queries), so
      fitted to it:

          1.0  x bm25 of the query words, divided by the best bm25 for this query
        + 0.3  x guessed tool (1.0 for the first guess's tool, 0.7 for later ones)
        + 0.3  x flag overlap with a guess for the same tool
        + 0.3  x weighted share of the guesses' words found
        + 0.02 x ln(use count)   (tie-breaker)

      bm25 is SQLite FTS5's standard ranking, over the columns command,
      arguments, history comment, notes text (and values and variants when
      a path is mentioned), any query word matching. The history comment
      column weighs 1.5, the others 1. It replaced our own "weighted share
      of query words found, + 0.5 x the share found in a history comment"
      2026-11-17: the results tied (benchmark useful first 55 vs 54,
      hold-out 48 vs 47, questions 7 vs 8), and bm25 is a standard rather
      than our own formula. Dividing by the best row keeps it in 0-1, so the
      other weights keep their meaning.

      Flag overlap: the share of option flags (`-x`, `--long`, `+opt`,
      values after `=` ignored) the row and the guess have in common. A
      `+` token is a flag only with a letter after it (`dig +short`, not
      `find -mtime +30`). Bundled short flags count as their letters
      (`grep -ri` as `-r -i`) when the user typed each letter alone with
      that tool: learned from the index, so `find -name` stays whole. Same
      for showing rows once. Added 2026-11-18: on the eval sets only two
      `usermod` rows changed places (11 of 7451 rows merge for display); a
      rule per tool (split all of a tool's tokens once one qualifies) split
      `find -name` inside `docker exec` rows, attached values (`-XPOST`)
      and typos, and was not taken. When
      the guess has no flags, the share of its plain words (subcommands such
      as `compose down`, `get pods`; not placeholders), and 0 when it has
      none. Until 2026-11-18 a guess without flags compared all tokens, so a
      guess `ssh user@remote_host` gave full credit to the user's most
      generic `ssh <USER@HOST>` row (x894, under "connect to postgres").
      Plain words only: benchmark exact first +4, useful first +3, none
      lost; hold-out one useful first answer lost ("generate random
      passwords": the user's `xkcdpass` row comes first and `pwgen` third,
      accepted); no flag credit at all for such guesses lost "stop docker
      compose" and "show pods".

      A history comment is written on purpose, about a command just run, in
      the user's own words: the same words they later type into hint. Text
      from notes files (headings, prose) counts as normal query words but gets
      no extra: notes vary in accuracy and staleness (extra for all note text
      tried 2026-11-16: 30 hits vs 29, within noise). The tool weight is low
      so a wrong tool guess does not outweigh the user's words (0.6 tried
      2026-11-16: 24 hits vs 27, and a model naming only `scp` pushed the
      user's rsync reminder down).

   Man NAME lines are not used for finding: as a tool bonus (tried
   2026-11-16) they changed nothing or made results worse; one-line
   summaries rarely use the user's words.
3. **Installed only.** A command is shown only if its tool is installed here
   (on PATH, or a just recipe). This applies to the user's rows and to model
   guesses alike, and is checked at lookup time, so installing a tool later
   brings its rows back without a rebuild. Asking about tools that are not
   installed is not hint's job; it says so and stops there.
4. **Output.** Two lines per result: the command, then a `#` status line
   saying where it came from. Nothing is executed. The groups below are
   placed as described under "Who leads" and "Model's guess second":
   1. **The user's rows** (case 1: "I've run this before"): the best-scoring
      rows, up to 5. Rows with the same tool, the same flags and the same
      literal words (not flags or placeholders) differ only in values and are
      shown once, the best-scoring one. So `ssh-keygen -f <PATH> -R <HOST>`,
      `-R oldhost` and `-R <HOST> -f <PATH>` show as one row, while
      `kubectl get pods`, `-A` and `--show-labels` show as separate rows.
      A path with a trailing `/` is not a value change (`du -sh dir/` and
      `du -sh dir` both show). Rows with equal scores are ordered by how
      many of their tokens they share with a guess for the same tool, so the
      row whose trailing `/` matches the guess comes first.
      This only hides rows for that lookup; the index keeps them all.

      **Tool-only rows once.** A row whose only link to the question is its
      tool (no question word other than the tool's name, no flag shared with
      a guess) is shown at most once per tool, the best-scoring one, and the
      places of the others are not refilled: when the evidence runs out the
      list gets shorter. Without this, a common tool fills the list with
      e.g. plain `ssh <host>` logins under "how do I create an ssh tunnel to
      postgres". Added 2026-11-18: noise (below) benchmark 291 -> 277,
      hold-out 231 -> 220, questions 52 -> 42 (lines per query 6.0 -> 5.7,
      5.8 -> 5.5, 6.0 -> 5.2), with exact first, useful first, position and
      not shown unchanged on every query. (Culling them while refilling the
      list, tried 2026-11-17, changed nothing: other rows took their place.)
      There is no minimum score: other weak rows can still fill the list.
   2. **Model suggestions** (case 2: "I don't know the command"): guesses
      whose shape is not one of the printed rows.
      When none of the user's rows are shown, the first is labelled "most
      likely" and the others "alternative"; below the user's rows they are
      labelled just "model suggestion". Then `see man <tool>(<section>):
      <summary>` once per suggested tool that has a man page.
   3. **Not installed**, as `#` comments only, never as commands:
      - rows from the user's sources that rank above the 5th printed row:
        `# found in <source>, but <tool> is not installed here:` then the rows
      - model guesses, when no installed command was printed at all:
        `# no installed command found; the model suggested the following:`
        then the guesses

   **Who leads.** The user's rows come first when the best row contains more
   than half of the query words (weighted by rarity as above, found where
   words count, without the history-comment extra). Otherwise nothing of the
   user's answers the question well, and the model's first installed guess
   is printed first, labelled "most likely (model suggestion)", then the
   user's rows, then the other guesses. The model's guess never leads
   because of its tool alone: the model guesses the wrong tool too often.

   **Model's guess second.** When the user's rows lead, the model's first
   installed guess comes right after the best row, then the other rows,
   then the other guesses:

       ssh -L 0.0.0.0:11434:localhost:11434 -i ~/.ssh/<PATH> ubuntu@<HOST>   (user's best row)
       ssh -L 5433:localhost:5432 user@postgres-server                       (model suggestion)
       ...the user's other rows, then the other guesses

   The user's form and the model's specific detail (here the postgres port
   for "ssh tunnel to postgres") sit together. It never changes the first
   line. Tried 2026-11-17: useful hint in the first 3 lines (see "What
   counts as a useful answer") +3 on the benchmark (59 -> 62), +2 on the
   hold-out (50 -> 52), +1 on the user's questions (10 -> 11), no losses.

   Tried and rejected 2026-11-17, for questions that name a tool:
   - Rows of the named tool first: no gain (they already lead: the query
     contains the tool word and the model usually guesses it). Counting any
     installed word as a named tool hurt (`last`, `dir`, `mount`, `find`
     are commands too): benchmark exact hits 32 -> 28.
   - Dropping the named tool's rows that match nothing but the tool word:
     drops the right row in follow-up questions, where the detail asked for
     is exactly what the user cannot name ("how do I use glow as a pager":
     `glow -p <PATH>` matches only "glow"), and junk from other tools takes
     its place.
   "More than half" is a meaning ("the row has most of what was asked"),
   not a value read off the eval set, and does not depend on the score
   weights.

   Tried 2026-11-17 on 77 queries (12 of them never run or added after the
   weights were chosen), hits with the right command first:
   user's rows always first 30; model always first 19; model leads unless
   the best row is for a guessed tool 27; half-words rule 34; best score
   < 0.7 36 and "not a guessed tool and score < 1.0" 36. The two score
   thresholds were rejected: both numbers were read off the eval set and
   change meaning whenever a weight changes. Model suggestions keep guess
   order.

   Hold-out check 2026-11-17: 79 of the user's own history comments (2+
   words) as queries, each hidden from the index while tested, expected =
   the rows carrying it. All are commands already run, so this measures what
   a rule costs, not what it gains. Hits: today's `hintdb match` 1; find
   with the user's rows always first 22; half-words rule 19 (4 lost, 1
   gained: wordy or label-like comments whose words are mostly not in the
   command); score < 0.7 22. The score threshold held up out of sample here;
   the half-words rule is kept for now because it has no fitted number,
   at a cost of about 3 hits in 79. Real use decides. Counted as useful
   answers (next section) the cost disappears: useful first 41 for both the
   half-words rule and the user's rows always first, 40 for score < 0.7.

## What counts as a useful answer

hint gives a hint, not always the exact command: `fc -ln -10` is a usable
answer to "show history without line numbers", and `glow` alone helps when
the user cannot remember `glow -p` (it gives them something to search for).
Results are judged on both:

- **exact:** the first line is the expected command (values may differ).
- **useful:** the first line (or one of the first 3) uses the right tool
  (with the subcommand for git, docker, kubectl). When the question names
  the tool ("how do I create an ssh tunnel to postgres"), the right tool is
  not enough: the line must also use mostly the same flags (`ssh -L`), since
  random examples of a tool the user already named do not help.

The user will scan about 6 lines when the first is not useful (as they
would scan `grep | sort | uniq` output), but unrelated lines above the one
they want make the tool annoying. So each change is also measured on all
printed lines, not only the first:

- **position:** `1 - i/6` for the first useful line at position i (0 = first
  line), 0 when no useful line is printed.
- **not shown:** no useful line printed at all.
- **junk:** lines that are not useful above the first useful one (all
  printed lines when none is useful).
- **noise:** lines that are not useful among the first 6 printed (added
  2026-11-18). Junk misses lines below the first useful one, which is where
  filler such as repeated rows of the same tool shows up.

Changes are compared query by query (which queries win, which lose), not
only by totals: on sets this small a difference of a few is noise.

Eval sets (outside the repo, real history): the benchmark (77 queries), the
hold-out (79 of the user's history comments, each hidden while tested) and
the user's questions phrased as they would really ask them (12). Tuning
stops where changes only trade a few hits between sets: real use decides
the rest.

Results with today's design (2026-11-18: a snapshot of the current index
and sources, with `psql` installed; guesses from the current prompt), exact
first / useful first / not shown / junk / noise: benchmark (77)
36 / 56 / 10 / 85 / 265, hold-out (82) 24 / 50 / 17 / 123 / 232, questions
(12) 7 / 9 / 0 / 6 / 38. These change with the index and with what is
installed: rows of a tool installed later show up. The hold-out is rebuilt
from the snapshot's history comments, and each comment is hidden from
history and notes text while tested (notes files may repeat it).

Where the misses are (same run; no useful line printed): benchmark 10. The
expected command is not in the index 4 (`iptables`, never used; two Slurm
questions; the `psql` connect forms the eval accepts); it is not a
candidate 2 (the model guessed the wrong tool and the row lacks the
question's words); it is a candidate ranked too low 4 (`docker` and
`kubectl` subcommands among many rows of the tool; `tail` guessed for a
`just` recipe). Hold-out 17, all with the wrong tool guessed: mostly
label-like comments the model cannot interpret.

## Tried and rejected

All 2026-11-17, on the three eval sets, against the design above. Numbers
are useful first and not shown unless said otherwise (benchmark 77,
hold-out 79, questions 12).

- **Two model calls** (call 1 says whether the question names a tool and
  lists candidate tools, the local rows for them are looked up, call 2
  picks from those rows): no gain on the benchmark, worse on the hold-out
  (useful first 44 vs 48), call 2 almost never answers "none", and 1.5-1.7 s
  per lookup.
- **Embeddings** (nomic-embed-text, fused with find by reciprocal rank
  fusion): benchmark useful first 55 vs 52, hold-out and questions mixed;
  a second model, and 273 s to embed the index.
- **The model's command as a grep key** (its tool and flags): finds mostly
  the rows find already finds.
- **Tool-only fallback** (rows of the guessed tool when no row has a query
  word): hold-out not shown 20 -> 18, otherwise unchanged; not taken up.
- **Culling rows** that match nothing but the tool: almost no change
  (hold-out not shown 20 -> 19), the list refills to 5 lines with the next
  rows.
- **Coordination** (score scaled by the share of query words matched):
  worse (benchmark not shown 14 -> 16, hold-out 20 -> 23).
- **Minimum should match** (keep only rows with more than half the query
  words, or matching a guess): fewer lines (4.6 per query) but hold-out not
  shown 20 -> 30.
- **Key words marked by the model** (a KEY line in the reply, used instead
  of the question's words): no gain; the model drops words that matter
  ("key" in "remove host key").
- **Extra for a history comment only when it holds more than half the
  query words:** worse (hold-out not shown 20 -> 23).
- **The model's guess leads only when no row was found:** benchmark useful
  first 54 -> 47 (hold-out exact first 19 -> 25); "no row found" almost
  never happens, so the guess leads too rarely.
- **Rarest query word required** (or the guessed tool): removes junk such as
  `pacman` rows from a comment mentioning its database, but not shown goes
  up (benchmark 14 -> 17, hold-out 20 -> 28).
- **Less weight for one-off comments:** no clear change (benchmark useful
  first 54, hold-out 47 -> 48, questions not shown 0 -> 1).
- **Frecency** (use count x recency; history recency from the line's
  position, notes from the file's date): worse (benchmark useful first
  54 -> 45, exact 32 -> 21).

2026-11-18, aimed at a common tool's rows scoring high just for being that
tool (the tool counts in bm25, as the guessed tool and as the guess's only
word):

- **The tool word left out of bm25:** benchmark useful first 55 -> 54,
  questions 7 -> 6 (losing "how do I use glow as a pager": the named tool
  is often the word that matters).
- **The tool's name not a guess word:** no change in useful first; hold-out
  junk 124 -> 129.
- **The tool counted once** (not in bm25 as the row's command, not a guess
  word): useful first a tie (benchmark -2, hold-out +1), noise slightly
  worse (benchmark 291 -> 300). Reordering cannot reduce noise while the
  list is always refilled; "Tool-only rows once" does.

2026-11-18, hosts without a dot (`ssh myserver` stays a literal word, so
each host is its own row): no source of host names separates hosts from
other words, so the limitation stays (README).

- **`~/.ssh/config` aliases (+ unhashed `known_hosts`):** precise, but much
  of the history is from older ssh configs whose aliases are gone.
- **Names typed as `user@NAME` in history, everywhere:** 277 rows -> 133,
  but the user's hosts include ordinary words (`ubuntu`, `gpu`, `github`),
  so `docker pull ubuntu` would become `docker pull <HOST>`.
- **Host positions learned from the user's `user@host` uses:** too broad
  (`user@1000.service` gives `systemctl` a "host" position) or, when a
  position must hold mostly hosts, circular (most `ssh` first arguments
  are dotless hosts, so `ssh` does not qualify: 4 rows).
- **Both together:** 136 rows -> 39, 84 of them `ssh`, but still `grep`,
  `ack`, `rm` rows and ordinary words.
- **A fixed rule (`ssh`'s first plain argument is the host):** exact, but a
  per-tool rule; not needed while "Tool-only rows once" already shows at
  most one plain `ssh <host>` per lookup.

## Index

- **Sources:** bash history, markdown and text notes, justfiles. Man NAME
  lines (sections 1 and 8, from `apropos .`) go into a separate `man.db`.
  Direction agreed 2026-11-18, not built yet: notes only when targeted
  (such as a Kubernetes cheatsheet), not folders of old notes from another
  platform; add recipe files (Makefiles, justfiles), bash and git aliases,
  and shell scripts. On the eval sets notes supply 5 benchmark answers;
  without them benchmark not shown goes 14 -> 16, the rest unchanged.
- **Cleaning:** drop trivial commands (unless annotated), lines that look like
  secrets, `hint`/`hintdb` lines plus `HINTDB_IGNORE`, and one-off history
  lines whose command is not on PATH.
- **Shapes:** values become placeholders (`<HOST>`, `<USER@HOST>`, `<PATH>`,
  `<FILE>`, `<STR>`, `<URL>`, `<HEX>`, `<N>`). Flags stay exactly as written.
  Quotes around a single token are ignored. A path's trailing `/` is kept
  (`<PATH>/`): it changes meaning (rsync source, symlinked directories), so
  `du -sh dir/` and `du -sh dir` stay separate rows and a merged row shows it.
  Commands with the same shape merge
  into one row with a use count, a display template (tokens that vary become
  placeholders) and two real examples. Rows are not merged any further in the
  index: grouping by flags alone (tried 2026-11-16) merged commands whose
  positional words matter (`docker exec -it ollama ollama list` / `... ps`,
  `mount -t cifs` / `-t nfs`, `git rev-parse --short HEAD` / `origin/main`).
- **Source:** each row records the source files it came from, for the
  "found in <source>" message, `--show`'s `# from` lines and `hintdb
  stats`, which counts per file the entries and those from that file
  only (what removing the source would drop). A first view of whether a
  source earns its place; which sources' rows actually answer questions
  needs the query log or the per-source eval.
- **Notes:** a note belongs to the variant it came from. It appears on a merged
  row only when variants carrying it make up at least half the uses; otherwise
  it is shown only next to its own example. All notes stay searchable:
  history comments and text from notes files go in separate columns, so
  bm25 can weigh history comments more.
- **Rebuilds:** always full, into a temp file, then an atomic replace. A
  rebuild is triggered automatically when a source file, the man-db index, the
  schema version or `HINTDB_IGNORE` changes.

## Query log

- **Purpose:** a record of real lookups, for looking up past answers
  (`hint history`, `hint search`), per-source usage and, later, which
  printed line was used.
- **Written by `hintdb find`** from the command line, after the answer is
  printed, one JSON line per lookup: `time` (local, ISO), `query`,
  `guesses` (as passed), `printed` (the lines exactly as shown) and `rows`
  (each of the user's printed rows, then the "not installed" ones, as
  `{"line", "sources"}`). Lookups that printed nothing are logged too. The
  `find()` function itself does not log, so eval runs that call it do not
  fill the log.
- **On by default** at `~/.local/share/hintdb/queries.jsonl` (`HINTDB_LOG`;
  `/dev/null` turns it off). Mode 0600. One `O_APPEND` write per lookup, so
  several terminals do not interleave. A failed write only warns. No
  rotation for now: one line per lookup stays small.
- **Read by `hintdb log`**, one line per match, the last N (`--last`,
  default 10), oldest first like `history | tail`; `--count` prints the
  number of lines instead. Matching: every word, case-insensitive plain
  substrings. Exit 1 when nothing matches, like grep. No model call.
  - history (default): one line per lookup whose question matches:
    number, time, question.
  - `--printed` (search): grep over past commands. One line per printed
    command line (not the `#` lines) whose text or note matches; the
    status labels ("your history xN", "your notes", "model suggestion")
    are not matched, or `search history` would match every row. A command
    printed by several lookups shows once, with the newest lookup's number,
    date and question and the count. Commands are never truncated.
  - `--show N`: the full entry N, as printed then, with `# from <files>`
    (home as `~`) after each of the user's rows, from the log's `rows`:
    bad rows are better fixed in their source than hidden, and this is
    how to find the source. `hint` accepts it after
    `history` and `-H` only: it shows a history entry, and after `search`
    it read as if it filtered the search.
  - `--delete N[,N|N-M]...`: blanks the entries' lines, so other numbers do
    not change (deleting 41 then 42 deletes the 42 that was shown). Every
    single number must be an entry or nothing is deleted (a mistyped
    number deletes nothing); a range deletes the entries in it. The file
    is rewritten in place under an exclusive `flock`, and every append
    takes the same lock, so a lookup in another terminal waits instead of
    being lost. No backup copy: it prints what it deleted. History only in
    `hint`, like `--show`. Agreed 2026-11-20 for lookups that went to the
    model by mistake; bad index rows are better fixed in their source.
  An entry's number is its line in the file: stable while the log is only
  appended to; damaged and deleted lines are skipped but keep their
  numbers. Agreed
  2026-11-20: printing every answer in full made the list unusable within
  a day, so lists are one line per item and the full answer is asked for
  by number.
- **`hint` forms.** `hint history [OPTIONS] [WORD|N]` (questions; a lone
  positive number is the last N) and `hint search [OPTIONS] WORD` (printed
  commands) are commands when at most one plain word follows, with the
  options `-n/--last N`, `-c/--count` and, for history only,
  `-s/--show NUM` or `-d/--delete NUMS` (alone) anywhere. `history` alone lists the last 10
  lookups, like bash `history`; `search` alone prints the usage, since it
  needs a word. Two or more plain words make the line a question, and an
  unknown option with at most one plain word prints the usage. `help` is a command only
  alone. Flags for several words: `-H/--history [WORD...]`,
  `-S/--search WORD...`, same options. Agreed 2026-11-20: a reserved word
  that swallowed questions would fail silently, giving the wrong kind of
  answer, so the word forms are kept to one plain word (a real question
  leads with words, "what does history -c do"); a miss there says how to
  ask it as a question instead. A known option marks a command: `hint
  history postgres --count` was first asked as a question, which the user
  found confusing. `hint history` alone first printed the usage too; once
  lists were one line per lookup, the user wanted it to list like bash
  (2026-11-20). `hint help` is the way to the usage.
- **Private:** like shell history it holds the user's commands; it stays
  local and is never committed. Tests point it into their scratch directory.

## Known limitations

Listed in README.md under "Limitations". Each is addressed only when a real
query is affected.
