# gitcross

Detect textual conflicts between the open pull requests of a GitHub
repository, before merging them.

GitHub tells you whether a PR conflicts with its base branch, but not
whether two PRs conflict with each other: you only find out after merging the
first one. gitcross checks every open PR against its base branch **and against
every other PR** targeting the same base, lists the conflicting files, and
shows which PRs can be merged now and in which order problems will appear.

Results are written as an HTML page and a LibreOffice spreadsheet (`.fods`).

## Sample reports

Reports produced for [ACCORD-NWP/IAL](https://github.com/ACCORD-NWP/IAL) on
2026-10-25 (29 open PRs):

- [samples/IAL.html](https://pmarguinaud.github.io/gitcross/samples/IAL.html): HTML report,
  served by GitHub Pages ([source](samples/IAL.html))
- [samples/IAL.fods](samples/IAL.fods): spreadsheet; download it and open it
  with LibreOffice Calc

They are a snapshot: the PRs have changed since.

## Requirements

- git >= 2.38 (for `git merge-tree --write-tree`)
- [gh](https://cli.github.com/), logged in (`gh auth login`); used only to
  list the open PRs
- perl 5 with core modules only (no CPAN install)

## Usage

```
bin/gitcross --repo OWNER/NAME [options]
```

| Option | Meaning |
|---|---|
| `--repo OWNER/NAME` | GitHub repository (required) |
| `--base BRANCH` | only PRs targeting BRANCH (repeatable) |
| `--pr N` | only these PRs (repeatable) |
| `--no-drafts` | skip draft PRs (included by default) |
| `--sort problem\|number` | matrix order: least to most problematic PR (default), or PR number |
| `--mirror DIR` | local bare clone (default `./NAME.git` in the current directory) |
| `--no-fetch` | do not update the mirror; reuse the PR list of the previous run |
| `--out PREFIX` | write `PREFIX.html` and `PREFIX.fods` (default `./NAME-gitcross`) |
| `-v` | progress messages (`-v -v`: show git commands) |
| `--help` | full help |

For [ACCORD-NWP/IAL](https://github.com/ACCORD-NWP/IAL), `run_ial.sh` checks
the prerequisites and runs everything:

```
./run_ial.sh [WORKDIR] [gitcross options]   # e.g. ./run_ial.sh ~/reports --no-drafts
```

The first run downloads the base branches and the PR heads (about 620 MB for
IAL, under a minute). Later runs only fetch what changed; the analysis takes a
few seconds and merge results are cached.

## How it works

1. List open PRs with `gh pr list`.
2. Fetch into a bare mirror only the base branches (`refs/heads/<base>`) and
   the PR heads (`refs/pull/<N>/head`, stored as `refs/pr/<N>`; this also
   works for PRs from forks).
3. Merge each PR with its base in memory with `git merge-tree`: nothing is
   checked out, nothing is pushed.
4. For each pair of PRs with the same base and at least one changed file in
   common: simulate "A merged into the base" (a temporary commit that only
   exists in the mirror), then merge B on top of it. When A conflicts with
   the base, B is merged first instead; when both do, A and B are merged
   directly. These two cases are flagged as *approximate*.
5. Write the reports.

## Reports

**HTML** (`NAME-gitcross.html`), self-contained:

- per base branch: PRs that can be merged now in any order, groups of PRs
  linked by conflicts, and a colour matrix PR x PR:
  - green: clean, orange: same files but merges cleanly, red: conflict,
    grey: no common file;
  - diagonal: PR against its base; numbers are counts of conflicting files;
  - rows sorted from the least to the most problematic PR, with title,
    contributor and a summary of problems on the right;
- table of PR pairs, with links to GitHub: direct diff of the two PR heads,
  and for each file, the changes of each PR to that file;
- table of all PRs (status against the base, how far behind the base,
  conflicting files);
- most conflicting files.

**Spreadsheet** (`NAME-gitcross.fods`, opens in LibreOffice Calc), same
information with colours: `Summary`, one `Matrix <base>` sheet per base
branch, `PRs`, `Pairs`, `Pair files` (one row per pair and common file, with
GitHub links, handy for filtering), `Files`.

## Files kept in the mirror

- `refs/heads/<base>` and `refs/pr/<N>`: list them with
  `git -C NAME.git for-each-ref`; any git command works on them, e.g.
  `git -C IAL.git diff refs/pr/674 refs/pr/698 -- bundle/bundle.yml`
- `gitcross-prs.json`: PR list of the last run (used by `--no-fetch`)
- `gitcross-cache.json`: merge results, keyed by commit SHAs

A working copy of any PR can be created without downloading anything:
`git -C IAL.git worktree add ../IAL-688 refs/pr/688`.

## Limitations

- Only textual (git) conflicts are detected. Two PRs that merge cleanly but
  break the build together are not; when they change the same file they are
  shown as "same files, merges cleanly".
- Pair results are approximate when one of the PRs already conflicts with
  its base; they become exact once the PR is rebased.
- The GitHub "diff A..B" link compares the two PR heads directly: when the
  PRs are not based on the same commit, it also contains the base branch
  changes between their starting points.
- Results reflect the state at the time of the run.

## Layout and tests

```
bin/gitcross                  command line
lib/GitCross/Git.pm           git wrapper (merge-tree, commit-tree, fetch)
lib/GitCross/GitHub.pm        PR listing, GitHub URLs
lib/GitCross/Analyze.pm       conflict analysis, cache, ordering
lib/GitCross/Report/HTML.pm   HTML report
lib/GitCross/Report/FODS.pm   spreadsheet report
run_ial.sh                    one-command run for ACCORD-NWP/IAL
t/analyze.t                   tests on a synthetic repository
DESIGN.md                     design notes and discussion
samples/                      sample reports for ACCORD-NWP/IAL
```

Run the tests with `prove t/`.
