# Notes for Claude

Read `CONTRIBUTING.md` first - it has the commit format, branch naming,
squash-merge rule and test requirement, and they apply to you too.

## What this repository is

A bash CLI that syncs Star Traders: Frontiers saves between two Macs over
Tailscale, through a hub directory that is the single source of truth. The
files it moves are irreplaceable and encrypted blobs that cannot be
inspected, diffed or merged.

## The rule

**Running the wrong command at the wrong time may refuse to work, but must
never lose a save.**

When a change could plausibly destroy data, the correct behaviour is to
refuse with a distinct exit code and an explanation, never to guess. Every
such refusal already has a row in the docs/troubleshooting.md table; add one
if you introduce a new state.

## Before you change `bin/star-traders-sync`

- **Never edit it while `sts play` may be running.** Bash reads scripts
  lazily off disk; editing a running script makes it execute garbage.
- Never point a test config at `~/Library/StarTradersFrontiers`,
  `~/star-traders-sync-hub`, or `/Volumes/Backup`. Those hold real saves. Use a
  sandbox, as `tests/regression.sh` does.
- Run `./tests/regression.sh` before and after. 104 cases; all must pass.

## Things that have already bitten, verified on this machine

Do not re-derive these the hard way:

- macOS ships **bash 3.2**. No bash 4 features.
- `/usr/bin/rsync` is **openrsync**, not GNU rsync. `-E` means
  `--extended-attributes` here but `--executability` in GNU rsync, so it is
  deliberately unused.
- BSD `find` **cannot parse `-newermt @epoch`**. Use `stat -f%m` and
  compare.
- `cpio` refuses to extract through a symlinked parent **and exits 0 having
  copied nothing**. macOS has `/var` and `/tmp` as symlinks, so snapshot
  paths are resolved with `pwd -P` first.
- macOS `shlock` **does not break stale locks** - it refuses even for a
  confirmed-dead pid. The local lock is a `mkdir` plus a pid file checked
  with `kill -0`.
- `set -e` does not fire for a failing `A && B` list **unless it is a
  function's last statement**, where it becomes the return value.
- The `ERR` trap is not inherited into functions without `set -E`.
- Two save files can have **identical sizes and different contents**
  (`core.db` is 12288 bytes on both machines), so decisions are made on
  SHA-256 manifests, never on size or mtime.

## Architecture invariants

- The hub host is a client of its own hub, using local paths instead of
  ssh. Same code path otherwise.
- Every overwrite snapshots the target first, and the snapshot's file count
  is asserted against the source. `rsync --delete` is only reachable after
  that.
- Transfers stage into a temp directory on the receiving side and are moved
  into place only on exit 0.
- Files in `SYNC_EXCLUDE` are machine-local and must be carried across the
  swap by hand, or the swap deletes them.
- The hub lock lives *beside* `HUB_PATH`, not inside it, because the swap
  replaces the whole directory.
- The hub lock must be released before `sts play` waits for the game, or
  the other machine is blocked for the whole session.

## Before you open a pull request here

Open an issue first and reference it with `Closes #N`, for anything beyond
a typo. This was applied inconsistently early on - PRs #11, #12, #13 and
#17 went up with no issue behind them - and the result is a history where
some decisions have their reasoning recorded and others do not.

## When you write an issue here

Read the `Issues` section of `CONTRIBUTING.md` and follow it exactly. The
headings are a **closed set** - `## Problem`, `## Proposal`,
`## Acceptance criteria`, then optionally `## Out of scope` and
`## References` - in that order. Bug reports use their own set.

This rule exists because the issues written before it were individually fine
and collectively unreadable: #42, #40, #34 and #22 invented four different
heading sets, and #22 used none at all. With 14 issues in one milestone,
triage means reading the first screen of each, and that only works if the
first screen is the same thing every time.

What not to do, specifically:

- **Do not invent a heading** because it fits this particular issue better.
  `## What it should look like`, `## The two real ones`,
  `## Why this is milestoned to v2.0` were all reasonable in isolation. The
  set of them is the problem.
- **Do not open by restating the title.** The first line of `## Problem` is
  the first new information in the issue.
- **Evidence, not assertion.** `file:line`, real command output, a real exit
  code. "This is confusing" is not a problem statement; 277 lines with the
  everyday path at line 24 is.
- **No filler.** No "Here's what this does", no "Let's", no emoji, no
  sentence whose content is that a section follows.
- **Acceptance criteria must be checkable by someone else.** "Improve the
  docs" is not a criterion; "`README.md` is under 110 lines" is.
- One issue, one branch, one pull request. If the acceptance criteria split
  cleanly into two sets that could merge separately, it is two issues.

The v1.3 issues (#43-#50) are the worked examples - match their shape.

## When you open a pull request here

Open it as a **draft** and mark it ready when it is finished:

```bash
gh pr create --draft --title "fix(scope): ..." --body "..."
gh pr ready <n>
```

Review fires on open and on every push, so a non-draft PR is reviewed
half-finished and again after each fix.



Answer every review comment and resolve the thread - see CONTRIBUTING.md.
Replying at top level while leaving the inline threads open does not count;
it looks answered from a distance and unfinished up close.

```bash
# list threads and whether they are resolved
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO") {
  pullRequest(number:N) { reviewThreads(first:20) {
    nodes { id isResolved path line } } } } }'

# reply in-thread, then resolve it
gh api graphql -f query='mutation { addPullRequestReviewThreadReply(
  input:{pullRequestReviewThreadId:"THREAD_ID", body:"..."}) { comment { id } } }'
gh api graphql -f query='mutation { resolveReviewThread(
  input:{threadId:"THREAD_ID"}) { thread { isResolved } } }'
```

## When reviewing your own work here

Three independent adversarial reviews found real data-loss bugs in code
that looked careful, including one regression introduced while fixing
another. Assume the same is true of anything you write. Prefer adding a
test case that would have caught it over asserting that it is correct.
