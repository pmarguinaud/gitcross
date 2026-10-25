# gitcross — PR cross-merge diagnostics

Goal: compare open pull requests against each other (and against their base),
report which pairs conflict, list the conflicting files, and help decide a
merge order.

## 1. Existing tools (state of the art)

Nothing mainstream does exactly this. Here is what does part of it:

### Single PR vs. its base branch only
- **GitHub / GitLab / Bitbucket mergeability**: each PR shows "has conflicts"
  against its target branch. They don't compare PRs with each other.
- **Merge queues**: GitHub merge queue, GitLab merge trains, Mergify,
  Aviator, Trunk, Graphite, Kodiak, bors-style bots. They merge PRs one
  after another and re-test. A conflict between PRs only shows up when the
  later PR fails in the queue, not ahead of time.
- **Label Actions** (e.g. `eps1lon/actions-label-merge-conflict`): they add a
  "conflict" label when a PR stops merging cleanly into its base.

### PR vs. PR (proactive detection)
- **GitKraken / GitLens "Conflict Prevention"**: warns when your branch and a
  teammate's branch edit the same files. It's tied to the IDE or desktop
  client, it's per-user, and it can't be scripted into a CI report.
- **Research prototypes** (Crystal, Palantír, Cassandra, and others):
  they validated the idea but aren't tools you can deploy.

### Building block
- **`git merge-tree --write-tree`** (git >= 2.38) runs a real three-way merge
  in memory, with no checkout and no worktree. It prints the conflicted files
  and the conflict types (content, modify/delete, rename/rename...). It's fast
  and safe, and it's the core of the proposed tool.

**Conclusion:** no tool takes N open PRs, builds a conflict matrix, lists the
problematic files per pair, and suggests a merge order. That is gitcross's
niche.

## 2. Proposed design

1. **Collect PRs**: `gh pr list --json number,headRefName,baseRefName,files`
   (or the REST/GraphQL API), then
   `git fetch origin '+refs/pull/*/head:refs/pr/*'`
   (GitLab: `refs/merge-requests/*/head`).

2. **Check each PR against its base**:
   ```
   git merge-tree --write-tree --name-only --messages origin/main pr/42
   ```
   Exit code 1 means it conflicts; the output gives the file list and a
   message for each file.

3. **Filter the pairs cheaply**: two PRs can only conflict textually if their
   changed-file sets overlap (track renames with `--find-renames`). This
   avoids most of the O(n²) merges.

4. **Simulate the pairs realistically**: the question is "once A is merged,
   does B still merge?"
   ```
   T=$(git merge-tree --write-tree main pr/A)
   C=$(git commit-tree $T -p main -p pr/A -m sim)
   git merge-tree --write-tree --name-only $C pr/B
   ```
   Check both orders when needed, since the results can differ.

5. **Diagnostics beyond hard conflicts**:
   - overlapping hunks that merged cleanly: "risky" warning (possible
     semantic conflict);
   - stale base: how many commits behind the base each PR is;
   - optional `--build` mode: check out the combined merge and run a build
     or tests.

6. **Merge-order advice**: build a conflict graph (PRs are nodes, conflicts
   are edges). Report the independent PRs and suggest an order for each
   conflicting cluster.

7. **Output**: terminal table/matrix, JSON (CI), Markdown comment on each PR
   ("conflicts with #51 in `src/foo.c`, `include/bar.h`"), optional
   scheduled run (cron / GitHub Action).

**Stack**: Python (or Go) wrapping the `git` and `gh` CLIs; `merge-tree` does
all the merging. Results are cached by `(sha_A, sha_B)` so repeated runs
are incremental.

## 3. Questions (please answer below each one)

**Q1. Forge**: GitHub only, GitLab too, or plain local branches (no forge)?

> Answer: https://github.com/ACCORD-NWP/IAL and other repos of ACCORD-NWP

**Q2. Language**: Python, Go, or shell?

> Answer: perl

**Q3. First version scope**: CLI report only, or also PR comments / a GitHub
Action?

> Answer: I do not understand the question

**Q4. Scale**: roughly how many open PRs at once (10? 100? 500+)?

> Answer: < 100

**Q5. Semantic checks**: do you want the build/test mode, or textual conflicts
only for now?

> Answer: textual conflict

**Q6. Target repository**: which repo(s) will you run it on first? Should
`/home/marguina/gitcross` be initialized as a git repo for the tool itself?

> Answer: https://github.com/ACCORD-NWP/IAL

**Q7. Anything else** (output format preferences, constraints, git version
available on your machines, ...):

> Answer: something I can open with libreoffice or maybe html

---

## 4. Elaborated design (from your answers)

### 4.1 Facts about the target (ACCORD-NWP/IAL, surveyed 2026-10-25)

- 29 open PRs, 9 of them drafts.
- **All 29 come from forks.** Their branches don't exist in IAL itself; they
  can only be fetched via `refs/pull/<N>/head`, which GitHub exposes for
  every PR, fork or not.
- **Several base branches**: `develop` (24), `accord_CY50T1_bf` (2),
  `accord_CY46T1_bf` (1), `merge_CY50T2_50R1` (1), `merge_CY50T1_50R1` (1).
  Comparing two PRs only makes sense when they target the **same base**, so
  the tool groups PRs by base and builds one matrix per group.
- Changed files per PR: min 1, median 7, max 40. So the file-overlap
  pre-filter will remove most pairs. With fewer than 100 PRs, even the
  remaining merges take seconds.
- Local tools: git 2.43 (has `merge-tree --write-tree`), gh 2.101,
  perl 5.38 with core JSON::PP. Excel::Writer::XLSX is **not** installed.

### 4.2 About Q3 (rephrased)

The question was where the results should go:
- (a) **Local report only**: you run `gitcross` on your machine and open
  the generated file. Nothing is written on GitHub.
- (b) **Also on GitHub**: the tool posts a comment on each PR, like "this PR
  conflicts with #123 in `arpifs/phys_dmn/foo.F90`". It needs write access
  to the repo and is visible to everybody.
- (c) **Automatic**: a GitHub Action runs it every night or on every PR
  update. It must be installed in the ACCORD-NWP repo.

**Proposal: (a) only for v1.** (b) and (c) can be added later without
changing the core.

### 4.3 Workflow

```
gitcross --repo ACCORD-NWP/IAL [--base develop] [--no-drafts] [--out report]
```

1. **Mirror**: keep a bare clone in a cache dir (e.g. `~/.cache/gitcross/IAL.git`).
   The first clone of IAL is large; after that, updates are incremental:
   ```
   git fetch origin '+refs/heads/*:refs/heads/*' '+refs/pull/*/head:refs/pr/*'
   ```
2. **List PRs**: `gh pr list -R <repo> --state open --json
   number,title,author,baseRefName,headRefOid,isDraft,url,updatedAt`.
3. **Changed files per PR**: computed locally rather than through the API:
   `git diff --name-status --find-renames <merge-base>..pr/N`.
4. **PR vs base**: `git merge-tree --write-tree --name-only --messages
   -z <base> pr/N`. Exit 0 means clean, 1 means conflict. Parse the
   conflicted file list and conflict types (CONFLICT (content),
   (modify/delete), (rename/delete), (add/add)...).
5. **PR vs PR** (same base, overlapping files only):
   - simulate A merged into base: `merge-tree base A` -> tree ->
     `commit-tree` -> temporary commit C (never pushed; only lives in the
     cache repo);
   - `merge-tree C B` -> conflicted files.
   - If A itself conflicts with base, the simulation is impossible. The
     pair is then reported as "unknown, rebase A first". The fallback is a
     direct `merge-tree A B` (relative to their own merge-base), flagged as
     approximate.
   - Textual conflicts are symmetric in practice, so only one order is
     checked (A<B by PR number). A `--both-orders` option can be added
     later if needed.
6. **Overlap-only warnings**: pairs that touch the same files but merge
   cleanly. Reported as "same file, no conflict", which is useful for
   reviewers even with textual checks only.
7. **Cache**: results keyed by `(base_sha, sha_A, sha_B)` in a JSON file, so
   a re-run only recomputes PRs that changed.
8. **Merge-order hints**: conflict graph per base; list PRs with no
   conflicts ("can be merged now in any order") and the connected clusters
   of conflicting PRs.

### 4.4 Reports (Q7)

Two outputs, both generated with core Perl only (no CPAN install needed):

- **`report.html`**: a single self-contained file, works offline:
  - summary per base branch (number of PRs, clean, conflicting with
    base, conflicting pairs);
  - **colour matrix** PR x PR (green: clean, orange: same files but
    clean, red: conflict, grey: not tested). Clicking a cell jumps to the
    detail;
  - table per PR: title, author, link, status vs base, conflicting
    files;
  - table per conflicting pair: files plus conflict type;
  - "most conflicting files" ranking (files involved in the most
    conflicts, typically hot spots in IAL).
- **`report.fods`**: a LibreOffice spreadsheet. It's flat OpenDocument XML,
  readable by LibreOffice Calc, and plain XML so it can be written without
  modules. Sheets: `PRs`, `Pairs`, `Files`, `Matrix` (with cell colours).
  CSV files can be produced too if you prefer something simpler (one file
  per sheet).

### 4.5 Perl code layout

```
gitcross/
  bin/gitcross              # CLI entry (Getopt::Long)
  lib/GitCross/Git.pm       # mirror, fetch, merge-tree / commit-tree wrappers
  lib/GitCross/GitHub.pm    # gh pr list -> JSON::PP
  lib/GitCross/Analyze.pm   # base checks, pair filter, pair merges, cache
  lib/GitCross/Report/HTML.pm
  lib/GitCross/Report/FODS.pm
  t/                        # tests on small synthetic repos built on the fly
  DESIGN.md
```

Dependencies: core Perl only (Getopt::Long, JSON::PP, File::Temp, IPC::Open3,
POSIX), plus `git` >= 2.38 and an authenticated `gh` (only needed for the PR
listing; IAL is public).

### 4.6 Limitations (textual mode)

- Only git-level conflicts are detected. Two PRs that each compile alone
  but break together (e.g. one renames a Fortran subroutine argument while
  the other adds a call) are not detected. They are at best flagged as
  "same file, no conflict" when the change is in a shared file.
- The results show the state at the time of the run; PRs move.
- Very large binary or generated files aren't treated specially.

## 5. Follow-up questions

**F1.** v1 = local report only (4.2 option a). OK?

> Answer: yes

**F2.** Include draft PRs by default, or skip them (`--drafts` to include)?

> Answer: include drafts by default

**F3.** Spreadsheet format: `.fods` (one file, several sheets, colours) or
plain CSV files? Or both?

> Answer: something with colors -> .fods

**F4.** "Other repos of ACCORD-NWP": should one run handle several repos
(`--repo A --repo B`, one report section each), or one report per repo?

> Answer: one repo at a time

**F5.** Where should the cache/mirror live (default
`~/.cache/gitcross/`)? Do you already have a local IAL clone the tool
could reuse to avoid a second big clone?

> Answer: clone in current directory

**F6.** Should I `git init` `/home/marguina/gitcross` and start coding?

> Answer: yes

---

## 6. Decisions and implementation (v1, 2026-10-25)

### 6.1 Decisions from the follow-up answers

| Topic      | Decision |
|------------|----------|
| Scope      | Local report only, nothing written on GitHub |
| Drafts     | Included by default; `--no-drafts` skips them |
| Spreadsheet| `.fods` with colours (plus the HTML page) |
| Repos      | One repository per run (`--repo OWNER/NAME`) |
| Mirror     | Bare clone `./NAME.git` in the current directory (`--mirror` to override) |
| Repo       | `/home/marguina/gitcross` initialized as a git repo (first commit 3fcb03b) |
| Matrix     | Extra columns with the PR title and the contributor (GitHub login) |
| Sort       | Matrix sorted from the least to the most problematic PR (conflicts with base + conflicting PRs, then conflicting files, then overlaps), with a "Problems" column; `--sort number` for PR order |

### 6.2 Usage

For IAL, `run_ial.sh [WORKDIR] [gitcross options]` checks the prerequisites (git, gh, perl, gh login) and runs everything; reports go to WORKDIR (default: current directory).

```
bin/gitcross --repo ACCORD-NWP/IAL                 # list, fetch, analyze, report
bin/gitcross --repo ACCORD-NWP/IAL --no-fetch      # re-analyze offline (saved PR list)
bin/gitcross --repo ACCORD-NWP/IAL --base develop  # only PRs on develop
bin/gitcross --repo ACCORD-NWP/IAL --pr 683 --pr 688 -v
bin/gitcross --help
```

Outputs: `./IAL-gitcross.html` and `./IAL-gitcross.fods` (`--out PREFIX` to change).

The mirror holds the base branches and the open PR heads only (refs/pr/N).
It also keeps two files: `gitcross-prs.json` (last PR list) and
`gitcross-cache.json` (merge results keyed by commit SHAs).

### 6.3 Files

- `bin/gitcross`: CLI, option parsing, fetch, report generation
- `lib/GitCross/Git.pm`: git wrapper (`merge-tree -z` parser, `commit-tree`...)
- `lib/GitCross/GitHub.pm`: `gh pr list`
- `lib/GitCross/Analyze.pm`: base checks, pair filter and simulation, cache,
  "mergeable now" list, conflict clusters, hot files
- `lib/GitCross/Report/HTML.pm` and `Report/FODS.pm`: the two reports
- `run_ial.sh`: one-command run for ACCORD-NWP/IAL
- `t/analyze.t`: 21 tests on a synthetic repository (`prove t/`)

### 6.4 First run on ACCORD-NWP/IAL

- First run 49 s (download of about 620 MB); analysis alone about 2 s;
  cached re-run 0.2 s.
- **Status against the base is identical to GitHub's mergeability for all
  29 PRs.**
- `develop`: 24 PRs, 8 conflicting with develop, 9 conflicting pairs,
  12 mergeable now. One conflict cluster: #550 #660 #674 #683 #688 #695
  #698 #710.
- Hottest files: `bundle/bundle.yml` (7 conflicts),
  `arpifs/phys_dmn/aro_turb_mnh.F90` (4),
  `arpifs/phys_dmn/apl_arome_surface.F90` (3).
- Checked by hand: #674 and #698 each merge cleanly into develop but
  conflict with each other in `bundle/bundle.yml`, as reported.
- The `.fods` opens in LibreOffice (9 sheets, colours kept).

### 6.5 Known limitations / possible next steps

- Many pairs are "approximate" because one of the two PRs already conflicts
  with develop (8 of 24). Such results become exact once the PR is rebased.
- `bundle/bundle.yml` (version pins) conflicts very often. An option to list
  such files apart, or to ignore them, could make the report easier to read.
- Possible later additions: PR comments or a scheduled GitHub Action (4.2 b/c),
  testing both merge orders, a build check of combined merges.
