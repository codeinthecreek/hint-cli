# eval

Scripts used to measure `hint` on your own queries. They run the real `hint`
and `hintdb` against your real index, so their input (your query file) and
output (results JSON) contain your own commands and hosts. Keep both outside
the repo; only the scripts and the example query file belong here.

| File | What it does |
|---|---|
| `run_hint.py` | runs `hint` over every row of a query file, saves what it printed |
| `classify.py` | sorts a run into hits and misses (guess problems vs match problems) |
| `best_case.py` | checks each row without the model: could hint get it right at all? |
| `score_tiers.py` | scoring levels shared by the other scripts |
| `example-queries.tsv` | format example |

## Query file

One row per line: the query, a tab, the expected first printed line, and
optionally more accepted lines separated by tabs. Lines starting with `#` are
comments.

- Write the query as you would ask it; values in it may be anything.
- Write the expected line in your own form, with `<placeholders>` for values
  you would fill in (`ssh-keygen -f "$HOME/.ssh/known_hosts" -R <host>`).
- For a tool that is not installed here, use `not-installed: <command>`.

See `example-queries.tsv`.

## Running

Needs Ollama with the model pulled, and `hint`/`hintdb` on PATH. Run a
benchmark (writes `./last-run.json`):

```
python3 eval/run_hint.py --queries ~/path/to/my-queries.tsv
```

Sort the results:

```
python3 eval/classify.py last-run.json
```

Check which rows can be hits at all, without calling the model:

```
python3 eval/best_case.py --queries ~/path/to/my-queries.tsv
```

## Reading the results

`classify.py` puts each row in one bucket:

| Bucket | Meaning |
|---|---|
| hit | the first printed line is the expected line (exact, or same tokens with each `<placeholder>` standing for a value, never a flag) |
| order | the expected line was printed, but not first |
| match-lost | a guess was closer to the expected line than anything printed |
| match-improved | the printed line is closer than the guess, still not a hit |
| guess-args | the right tool was guessed, the arguments differ |
| guess-no-tool | no guess used the expected tool |

`anywhere` is hit + order: the expected line appears somewhere in the output.

## Caveats

- Ollama's replies vary from run to run even at temperature 0, also after a
  cold start. Compare changes by bucket counts over at least 2 runs, and treat
  differences of 1-2 rows as noise. Changes that do not involve the model can
  be checked exactly with `best_case.py`.
- A placeholder stands for part or all of one token: the text around it must
  match (`user@<host>` does not match `root@example.org`), and it never stands
  for a flag. A command typed with its arguments in another order is not a hit;
  add that form as another accepted line if it is the way you type it.
- `score_tiers.py` has a small table of tools with subcommands (for the
  "cmd" level). It is used only for scoring here, not by hint.
