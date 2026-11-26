# DESIGN.md

Design decisions for `hint` and `hintdb`. README.md covers usage and
docs/ARCHITECTURE.md how it works; this file records what the system must
do and why.

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

**The model and the search together** (2026-11-22, the same snapshot and
recorded guesses, today's find): useful first / exact first with the
question's words alone (no guesses), with the model's guesses alone (no
search), and with both. Benchmark (77) 32/24, 46/14, 57/37; hold-out (82)
45/24, 39/4, 50/24; questions (12) 6/4, 7/5, 9/7. Both is best on every set
and measure, except hold-out exact, where it ties the words alone. The model
alone names the right tool often but rarely the user's exact command; the
words alone find the user's commands but miss questions worded unlike them.
The guess mainly guides the search: of the 29 questions where it put the
useful line first, the user's row was also printed in all 29, and in 21 it
was not printed at all without the guess. The README's evidence line quotes
the benchmark figures.

Where the misses are (the 2026-11-18 run; no useful line printed): benchmark 10. The
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
- **A stronger model** (Claude Haiku 5.5 through the Anthropic API instead
  of qwen2.5-coder:3b, 2026-11-20; same prompt, worked example and
  cleaning, same index snapshot; exact / useful first / not shown):
  benchmark 37 / 57 / 9 -> 35 / 57 / 8, hold-out 24 / 50 / 17 -> 24 / 49 /
  18, questions 7 / 9 / 0 -> 8 / 10 / 0. No gain, though the guesses read
  better (fewer junk lines on the user's own questions, 6 -> 3). The misses
  are not a weak model's: in every hold-out miss (17 of 17, and 18 of 18
  with Haiku) the wrong tool was guessed because the question does not
  name the tool and the user used a less common one than the obvious
  guess. No model can know that; only the user's words in the index can
  (a `# comment` on the command, or naming the tool in the question). An
  API model would only help on a machine without Ollama, at about $0.00005
  and 0.9 s per lookup; not built.
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

- **Sources:** bash history, markdown and text notes, justfiles, Makefiles,
  git and bash aliases, and the built-in answers file (see Remember). Man NAME lines (sections 1 and 8, from `apropos .`)
  go into a separate `man.db`. Direction agreed 2026-11-18: notes only when
  targeted (such as a Kubernetes cheatsheet), not folders of old notes from
  another platform; add recipe files, git aliases and bash aliases (done).
  Shell scripts are parked (2026-11-20): a script's lines are mostly
  plumbing (variables, tests, loops, echo), repo scripts are written for
  their project, and scripts on PATH are already in history when run. If
  a real lookup misses something in a script, the cheap form is the one
  used for aliases: the row is the script name, the note its header
  comments, for registered scripts only. On the eval sets notes supply 5 benchmark answers;
  without them benchmark not shown goes 14 -> 16, the rest unchanged.
- **Recipe files** (justfiles, Makefiles; agreed 2026-11-20): a recipe line
  ending in `\` is joined with the lines it continues on; the recipe
  prefixes (`@ -`, and `+` in Makefiles) are stripped once, from the start
  of the joined command; in Makefiles `$$` becomes `$` and `$(VAR)` is
  left as written. Only single simple commands are kept: a joined line
  that starts with a shell keyword (if, for, while, ...) or has an
  unquoted `;`, `&&` or `||` is dropped whole, not split (a real Makefile
  tested 2026-11-18 gave 86 rows, ~60 of them shell fragments like `fi`).
  Splitting such lines into their commands was the other option; not
  needed so far (shell scripts, its main use, are parked). `echo` lines are dropped too: progress
  messages, and merged with history echoes they made a top row (`echo
  <STR> x11`, 2026-11-20). The note is `just|make <recipe>` plus the doc: a
  `## doc` on a Makefile target line, else the comment line directly above
  the recipe (a blank line in between ends it, so section dividers are not
  taken). Makefile pattern rules (`%.o:`) and special targets (`.PHONY:`)
  are skipped.
- **Git aliases** (agreed 2026-11-20): the `[alias]` section of a git
  config file (`.gitconfig`, `.git_aliases`, `git/config`; `[include]` is
  not followed, so an included file is registered itself). The row is what
  you type, `git <alias>`, not the body: in a real aliases file the most
  used and most useful aliases were `!` shell functions (`!f() { ...; };
  f`), which the recipe rule would drop and which are not commands to
  recall anyway. The note is the comment lines directly above the alias
  (joined; a blank line ends them), the `#---` section heading the alias is
  under, then the body, then the value's own trailing comment, so an alias
  is found by what it does. A heading is context for every alias under it
  (as markdown headings are for notes), until the next heading or
  `[section]`: taken as the first alias's doc it gave `default` the words
  of `#--- fork/upstream workflow`; applied to all, "sync my fork with
  upstream" moved `git sync` from 10th to 5th (2026-11-20; not taking it
  at all: 9th). Weighing alias bodies lower was tried for that query and
  dropped: without bodies `git sync` only went 10th -> 8th; the helpers
  rank above it on their own comments. Git's quoting,
  `\` escapes and `\` continuations are decoded. All aliases are indexed,
  not only those in this machine's history: the file is shared with other
  machines, and recalling commands used elsewhere is the point. An alias
  also in history merges with that row, so its uses still count.
- **Bash aliases** (agreed 2026-11-20): `alias name='body'` lines in
  `.bash_aliases` or `.bashrc`, also inside if-blocks or after `[ -x ... ]
  &&`. As for git aliases the row is the alias name, what you type. The
  note is the comment lines above the block the alias is in (a blank line
  ends a block, so "# safety aliases" covers rm, mv and cp; bash alias
  files group by blank lines rather than `#---` headings), then the body
  and the line's trailing comment. A comment with no space after the `#`
  (`#alias x=...`, `#if ...`) is commented-out code, not a comment. An
  alias whose body starts with its own name (`ls='ls --color=auto'`,
  `rm='rm -i'`) is skipped: it only adds options, nothing to recall. Alias
  names count as installed, like commands on PATH, both when building
  (a one-off history line `histgrep ssh` is kept) and at lookup (an alias
  also typed in history merges into a history row, which must still be
  shown). They are stored with the index.
- **Labels:** a row from a recipe file or aliases is labelled "your
  Makefile", "your justfile", "your git aliases" or "your aliases" instead
  of "your notes"; history comes first when a row is in both.
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
  (`hint history`, `hint search`), per-source usage, and the question that
  `hint remember` answers (see Remember).
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
    status labels ("your history xN", "your notes", "your Makefile",
    "your justfile", "model suggestion")
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
  history postgres --count` was first asked as a question, which the author
  found confusing. `hint history` alone first printed the usage too; once
  lists were one line per lookup, the author wanted it to list like bash
  (2026-11-20). `hint help` is the way to the usage.
- **Private:** like shell history it holds the user's commands; it stays
  local and is never committed. Tests point it into their scratch directory.

## Remember

Agreed and built 2026-11-26. Named `hint answer` at first; renamed the
same day to `hint remember`, which pairs with `hint forget` and says what
it does (the author). The file and `HINTDB_ANSWERS` keep their name: they hold
answers to questions.

- **Purpose:** when a lookup missed and the user found the command some
  other way, `hint remember` saves the question as a comment on that
  command, so the next similar question finds it. A wrong tool guess was
  behind most misses (26 of 30, 2026-11-18); with the question's words on
  the user's row, the row is found even when the model guesses the same
  wrong tool again. It works like a `# comment` the user writes in
  history: the user's own words on the user's own command.
- **Not a change to the guess.** The model's prompt and reply are
  untouched, and there is no extra model call. Past (question, command)
  pairs as worked examples in the prompt were considered and not taken:
  worked examples were tried and rejected (see Lookup), and examples that
  change with every lookup would be hard to measure. This is a match
  change and is measured as one.
- **Explicit, never automatic.** Learning from whatever was run after a
  lookup was rejected: a mistyped flag would be remembered, and with
  several terminals writing to one history file the lines after a lookup
  may come from another terminal.
- **Form:** `hint remember [TOOL]`. Same rule as `history` and `search`: a
  command when at most one plain word follows, a question with two or
  more (`hint remember my ssh key passphrase` is a question).
- **Usual sequence:** `hint QUESTION`, then the user tries commands until
  one works, then `hint remember`. The user is not expected to do other work
  in between, so the answer is taken to belong to the last lookup.
- **The question:** the last lookup in the query log, as hint received it.
  It is shown at the prompt, so a lookup made from another terminal in the
  meantime is seen and cancelled.
- **The history file read** is the one bash is writing now: `$HISTFILE` if
  it is exported, else `~/.bash_history` (the rule `hintdb` uses to
  register history on first use). It is never chosen from the registered
  sources: other history files there (old ones, other machines') are for
  reference, not the current session. A history file elsewhere needs
  `export HISTFILE` in `.bashrc`. Reading it does not require it to be a
  registered source.
- **Not written yet:** a script cannot read the shell's history in memory,
  only the file. If the file was last modified before the last lookup's
  time, the commands run since are not in it; hint says so, suggests
  `history -a; hint remember`, and exits 1 without a prompt. With `history
  -a` in `PROMPT_COMMAND` (the README's setup) the file is always current.
  Without it (servers), the documented form is `history -a; hint remember`,
  not an alias: an alias line would itself be taken as the last command.
  The check can miss: if another shell writes the file (e.g. on exit)
  between the lookup and the answer, the file is newer but this session's
  lines are not in it, and the prompt offers an older command, which the
  user sees and cancels.
- **Which line.** The file is read from the end. Timestamp lines
  (`#1700000000`) are skipped. Each line is split into its commands as the
  index does (`|`, `;`, `&&`, `||`; `sudo`, `env` and the like skipped; a
  command's path dropped, so `/usr/sbin/ss` is `ss`), except that an
  unquoted `;`, `|` or `&` also separates when it touches a word: the
  index's tokens keep `-a;` whole, so `history -a;hint remember` was not
  seen as running `hint` (found by the tests). The index is unchanged.
  - **After the question** (changed 2026-11-26, from real use): only the
    lines after the question's own `hint` line count. The question is the
    last line whose words, split as the shell does (`shlex`), are `hint`
    followed by the logged question (hint logs `"$*"`, so quotes and
    spacing do not matter). `hint remember` takes the **last** of those lines
    (what finally worked), `hint forget` the **first** (the suggestion run
    right after asking). Nothing run since the question: says so, exit 1;
    lines from before the question are never offered.
    Why: the first version took the newest line anywhere, skipping
    `history`/`fc` lines (so the `history -a` typed before `hint remember`
    was not taken). In real use, after `hint show me the last history
    items`, `history -n 10` (wrong), `man history`, `history --help`, plain
    `hint forget` skipped every history line and offered `docker stop ...`
    from before the question, and `hint forget history` offered `history
    --help`. Matching the question's line was first rejected as fragile;
    splitting it as the shell does makes it reliable.
  - Always skipped: lines that run `hint` (the `hint remember` line itself,
    in case `history -a` wrote it; not checked on a real terminal), and,
    without TOOL, trivial lines by the index's rule (`cd /etc`, `man
    history`). History and `fc` lines count: `history -n 10` and `fc -ln
    -10` are lines one forgets or answers with, and the `history -a` before
    `hint remember` is on the same line as hint or comes after the answer.
    When only trivial lines follow the question, the message lists them,
    each with the command that takes it (`history 10   hint remember
    history`): in real use the answer was `history 10`, followed by `vim
    ~/.bash_history`, and "no command since you asked" did not say why
    (2026-11-26). The rule stays: without it `vim ~/.bash_history` would
    have been offered.
  - With TOOL: the last (answer) or first (forget) line after the question
    in which any command is TOOL, with nothing else skipped: naming the
    tool means that tool is wanted, so `hint remember history` finds
    `history -d 1234` and `hint remember grep` finds `ps aux | grep nginx`.
  - **Question not in the file** (asked in another terminal, or quotes
    `shlex` cannot split): the newest line anywhere, skipping also lines
    made only of `history` and `fc` commands, as in the first version. The
    prompt says the question was not found and this is the newest command.
- **Prompt:** the question, then the command on an editable line (`read -e
  -i` from the terminal), so a typo or a one-off value can be fixed before
  saving. Enter saves, Ctrl-C or an empty line cancels. A line under the
  question says so, and how to reach another line: edit it, or (when no
  TOOL was given) `hint remember TOOL` (the author, 2026-11-26). `hint forget`
  says the same, with "Enter lists where it is".
- **Saved:** the whole line as edited, not only the TOOL part, so it has
  the shape of the user's existing row and merges with it. One line
  `COMMAND  # QUESTION` appended to the answers file: `HINTDB_ANSWERS`,
  default `~/.local/share/hintdb/answers` (`/dev/null` turns answers off).
  Mode 0600, one `O_APPEND` write under `flock`, as for the query log.
  Answers are per machine, like the index. To undo one, edit the file.
- **In the index:** built in, like the query log, not registered in the
  sources file: hint does not edit the user's sources, and a missing
  answers file means no answers yet rather than a "source missing"
  warning. `hintdb` includes the file whenever it exists, parsed as
  history: its comment is searched as a history comment (weight 1.5), it
  merges with the row of the same shape, and the row is labelled "your
  history xN"; the answer adds 1 to the use count (a tie-breaker only;
  accepted). `hintdb sources` lists it on a line of its own, marked as
  built in; `hintdb stats` and `hint history --show` name it like any
  source. It is part of the fingerprint, so the next lookup rebuilds. No
  cleaning, shape or note rule changes, so no schema bump.
- **Limits:** it helps only when a similar question is asked again; the
  first miss is still a miss. A command typed over several lines is one
  line in the history file with bash's defaults (`cmdhist` on: a loop is
  joined with `;`, a `\` continuation is joined too; checked with bash
  5.3). Only with `shopt -s lithist` is it written as several lines, so
  the last line may be a fragment (`done`); the prompt shows it, to be
  fixed there or cancelled. The index has the same limit.
- **Tests** point `HINTDB_ANSWERS`, `HINTDB_LOG`, `HISTFILE` and the index
  into the scratch directory, like the other checks.

## Forget

First built 2026-11-26 as read-only (it listed where the command is, for
the user to delete or mark it); changed the same day to save a WRONG mark
to hint's own file (agreed and built). Both are described below,
since the second rests on what the first found.

- **Purpose:** a wrong line that keeps coming up (`history -n 10`: `-n`
  takes no count) feeds itself. It looks right, so it gets run, so it is
  in history once more, with a higher use count and a more trusted
  `xN`. Bash history has the same loop for up-arrow and Ctrl-R. The typo
  rule cannot catch it: the command is installed, and wrong flags cannot
  be told without per-tool flag tables. `hint forget` marks the command
  WRONG (see "WRONG marker"), so hint stops showing it.
- **Saves the mark to hint's own file, never edits a source.** `hint
  forget` appends one line, `COMMAND  # WRONG!` or `COMMAND  # WRONG:
  REASON`, to the wrong file: `HINTDB_WRONG`, default
  `~/.local/share/hintdb/wrong` (`/dev/null` turns it off). Mode 0600, one
  `O_APPEND` write under `flock`, as for the answers file. It is built in
  like the answers file (included whenever it exists, read as history,
  listed by `hintdb sources`), so the existing marker rule applies with no
  new rule: the command is dropped from every source, and a model guess of
  it is labelled. Undo: delete its line.
  - **Why a file of its own**, not the answers file: each file holds what
    one command saved (`cat` shows what was marked), no "answers" file
    holding marks, and no remembered and marked copy of one command in
    the same file.
  - **How it got here:** first read-only, because the author chose safety
    over convenience; considered then and not taken: a stored forget
    list (a line wrong for one question may be right for another, and a
    mistaken forget would hide it with no sign), and printing a `sed -i`
    command to remove the line from history (it worked when tested, but a
    generated pattern must escape every special character). The
    read-only version listed the lines and printed the steps for editing
    bash history safely; real use then showed that deleting the first of
    several listed lines shifted the others, and the WRONG marker made
    marking possible. With the marker, the stored list's objection no
    longer holds: a mark says the command is wrong in itself, is listed
    by `hintdb stats`, labels a model guess of it, and is undone by
    deleting a line. Saving it to hint's own file needs no editing of
    bash history at all (the author, 2026-11-26: "save the mark to hint's own
    file").
- **Form:** `hint forget [TOOL]`, parsed like `hint remember`: a command
  when at most one plain word follows, a question with two or more.
- **Picking the line:** as for `hint remember` (see "Which line"), but the
  **first** line after the last question, or the first TOOL line: the
  suggestion that looked right and was run right after asking. Also the
  check that the history file was written since the last lookup, when
  there is one. A question is not required: with none in the log, or none
  found in the file, the newest line is offered. The prompt says where it
  started: `which command? the first after "hint QUESTION":`. The line is
  editable, so `hint forget history` plus an edit reaches a line that was
  not run this time. Enter goes on; an empty line or Ctrl-C cancels.
- **From the last lookup's output** (added 2026-11-26; user: "I see
  something is wrong and mark it without adding it to my history"): when
  nothing was run after the question (no line, or only trivial ones), or
  the history file was not written since it (a server without `history
  -a`), `hint forget` lists the commands the last lookup printed,
  numbered, from the query log, and asks for a number; the chosen command
  then goes to the editable line as usual. Listed: the user's rows and the
  model's guesses (also "not installed" ones), in printed order, once
  each; not status lines, not rows shown as templates (`user@<HOST>`: a
  mark needs one exact command), not commands already marked. A number
  not in the list, or an empty answer, saves nothing. With a TOOL the
  list is not offered: a TOOL names a line in the history. A `hint forget
  N` form (the Nth printed command, without the list) was considered and
  not taken: the author found it confusing next to `hint forget TOOL`.
- **Reason:** a second prompt, `reason (optional, Enter for none):`. Enter
  saves `# WRONG!`; a reason saves `# WRONG: REASON`. Ctrl-C cancels, and
  nothing is saved.
- **Already marked:** if the command is marked in any history-kind file
  (the wrong file, bash history, another history, the answers file), hint
  says where (`history -n 10 is already marked WRONG: ~/.bash_history line
  43870`) and saves nothing.
- **Exact line only.** The index merges lines of the same shape into one
  row, and hint may show the row as a template (`ssh ... user@<HOST>`).
  `hint forget` marks one exact command (runs of spaces as one); other
  commands of the same shape stay.
- **Output after saving, short:**

      saved: history -n 10  # WRONG: -n takes no count
      hint now hides it. It is still in your history (up-arrow, Ctrl-R):
        ~/.bash_history  lines 2, 4
      Delete those lines to clean it up there too; see the README for
      editing history safely.

  One file per line, as in the `--where` listing: wrapped as running
  text, a long path broke the sentence (seen in testing, 2026-11-26).

  The "still in" lines list the copies in the live history and in the
  registered sources, found as the read-only version did: in history-kind
  files a line whose command (comment dropped, runs of spaces as one)
  equals the chosen one; in other files a line containing it (notes put
  commands in code blocks or after `$ `). The live history comes first,
  registered or not. With no copies anywhere, only the first two lines
  are printed. The full steps for editing bash history moved to the
  README: printed after every mark they were long for something optional.
- **Editing bash history safely** (now in the README; tested 2026-11-26,
  two interactive bash 5.3 shells under pseudo-terminals sharing one file,
  `histappend`, `PROMPT_COMMAND="history -a"`):
  1. `history -a` first, or the session's unwritten lines are lost by the
     reload;
  2. edit the file and save it soon: an editor open on the file overwrites
     lines other terminals append meanwhile (vim warns, other editors may
     not);
  3. in this terminal and every other open one, ` history -a; history -c;
     history -r` (leading space: not saved, with `ignorespace`). A shell
     keeps a removed line in memory until reloaded, but with `histappend`
     does not write it back. Bash counts the lines of the file it has
     read: after k lines were deleted, `history -n` in another terminal
     skipped the next k new lines (they stay in the file but never reach
     that terminal), while `history -c; history -r` loaded every line and
     none of the deleted ones. Delete from the last listed line up, so the
     other line numbers stay right.
  The steps name plain bash commands, not aliases a user may have.
- **Afterwards:** the wrong file has changed, so the next lookup rebuilds
  the index without the command. `hintdb forget --where` stays for the
  listing (debugging, and the "still in" line).
- **Limits:** a Makefile recipe joined from `\` lines is not found in the
  listing (the file holds it in pieces). Matching other files by
  substring can list a longer line that contains the command.
- **Tests** use fixture sources, a scratch history file, and
  `HINTDB_WRONG` in the scratch directory.

## WRONG marker

Agreed and built 2026-11-26.

- **Purpose:** a command that is wrong in itself (`history -n 10`: `-n`
  takes no count) is marked where it is, and hint stops showing it for
  every question. A command that is right but not for this question is a
  different case: `hint remember` puts the question's words on the right
  command instead, and nothing is hidden (the author, 2026-11-26).
- **The mark:** a trailing comment on a line in a history-kind file (bash
  history, other history files, the answers file, and the wrong file that
  `hint forget` writes) whose text starts with
  `WRONG` as a whole word, in capitals: followed by the end of the
  comment, punctuation or a space. So `history -n 10  # WRONG!`, `# WRONG`
  and `# WRONG: -n takes no count` mark the command, with room for a
  reason; `# fix wrong permissions` and `# Wrong!` do not. `# WRONG
  permissions fixed` does: capitals at the start of a comment are the
  signal, not the words after.
- **Not taken:**
  - free words such as "wrong", "broken", "doesn't work" anywhere in a
    comment: `chmod -R u+w dir  # fix wrong permissions` uses the word
    for the problem, not the command;
  - a comment line typed at the prompt (`# WRONG: history -n 10`; tested:
    bash saves it and runs nothing, not even `$(...)` or redirections in
    it): the author found it unnatural, and marks are added while editing
    the history file anyway, from `hint forget`'s line numbers;
  - marks in notes files: notes are the user's own files, and deleting
    the line there is simple;
  - pushing a marked command down instead of dropping it: a command wrong
    in itself has no good place in the list.
- **Effect** (a cleaning rule, so `SCHEMA_VERSION` is bumped): the build
  first collects the marked commands (the command part of each marked
  line, runs of spaces as one), then skips every line, from every source
  and of every kind, whose command is marked. Exact command only: other
  commands of the same shape stay (`history -n` when `history -n 10` is
  marked). Copies run later are dropped too, which breaks the loop of a
  wrong line coming back every time it is run.
- **Why mark rather than delete:** the mark stays next to the command,
  with its reason (Ctrl-R shows it); running it again does not bring it
  back; one marked copy is enough; and the line numbers `hint forget`
  printed stay right. Deleting a line shifts every later line up: the
  user deleted the first of several listed lines and the others were then
  wrong (2026-11-26).
- **A trace:** `hintdb stats` lists the marked commands, each with the
  file and line of its mark and the reason. Undo: remove the comment.
- **When the model suggests a marked command** (added 2026-11-26, from
  real use: the mark removed the user's row, and the model then printed
  `history -n 10` second, as a plain suggestion): the guess is printed
  after the other guesses, never first or second, labelled with the mark's
  comment first, so it reads as a verdict and a reason shows: `# WRONG!
  (model suggestion, marked by you)`, `# WRONG: -n takes no count (model
  suggestion, marked by you)`. Its tool, flags and words still guide the search: the tool is
  usually right, only the command is wrong. When no installed command was
  found, the model's list says `(WRONG!, marked by you)` after it.
  `--debug` names marked guesses. The marks are kept in the index's meta.
- **In `hint forget`:** it saves the mark to hint's own wrong file (see
  Forget). When the command is already marked anywhere, it says where, so
  the mark can be found to undo it, and saves nothing. (The read-only
  version suggested adding `# WRONG!` to a history line by hand, or
  deleting the lines from the last one up.) A mark added by hand to a
  history line works the same as one saved by `hint forget`.
- **Tests:** marks in fixture history lines (`# WRONG`, `# WRONG!`,
  `# WRONG: reason`, and the near misses above), a copy of the command in
  a notes file and another history file, `hintdb stats`, `hint forget`.

## Known limitations

Listed in README.md under "Limitations". Each is addressed only when a real
query is affected.
