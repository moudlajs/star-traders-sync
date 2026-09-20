# Contributing

Small repo, one maintainer, high stakes: the tool moves irreplaceable save
files. The conventions exist so that a change which loses data is hard to
make by accident, not to add ceremony.

## The one rule that matters

**Running the wrong command at the wrong time may refuse to work, but must
never lose a save.** Any change that weakens that is wrong, however
convenient it is. Refusing with a clear message and an exit code always
beats guessing correctly most of the time.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/). The type
prefix is what makes the history readable and what a changelog generator
keys on.

```
<type>(<optional scope>): <subject>

<body: why, not what - the diff already says what>
```

Types used here:

| Type | For |
|---|---|
| `feat` | new capability |
| `fix` | corrected behaviour |
| `docs` | README, help text, config comments |
| `test` | the regression suite |
| `ci` | workflows |
| `refactor` | no behaviour change |
| `chore` | plumbing, deps, repo config |

Scopes worth using: `sync`, `lock`, `backup`, `snapshot`, `config`, `play`.

```
fix(lock): release the hub lock on every early return
feat(backup): mark completed backups so partials cannot join the rotation
docs: cut config.example from 190 lines to 97
```

Explain *why* in the body. `fix(lock): fix lock bug` tells a future reader
nothing; the bodies in this repo's history are the model.

## Branches

`<type>/<short-description>`, lowercase. CI rejects anything else.

```
feat  fix  hotfix  docs  test  ci  refactor  chore  infra  release
```

```
fix/hub-lock-leak
feat/sts-update
infra/ci-and-release
```

## What CI enforces

Both of the conventions above are checked, not just documented:

- **PR title** must match Conventional Commits. It becomes the squash
  commit subject on `main`, so it is the thing that actually matters.
- **Branch name** must match the pattern above.

`main` is protected: the `check` job must pass, the branch must be up to
date, and force-pushes and deletions are blocked.

## Issues

**Every change gets an issue first, including small ones.** The issue says
what is wrong and why it matters; the pull request says what was done about
it. Splitting them that way means the reasoning survives even when the diff
is later rewritten, and `git log` stays a record of decisions rather than
of keystrokes.

Assign it to yourself. With one maintainer an unassigned issue is an
oversight, so the template and a workflow both do this automatically.

A typo fix does not need this. Anything that changes behaviour, adds a
guard, or touches CI does.

## Pull requests

- One logical change per PR.
- Reference the issue in the body: `Closes #12`. That auto-closes it on
  merge and cross-links both ways. There is no separate ticket numbering.
- **Squash merge only.** The repo is configured for it; merge commits and
  rebase merges are disabled. One PR becomes one commit on `main`, and the
  PR title becomes the commit subject, so the title must follow the
  Conventional Commits format above.
- The PR body should say what was verified, not just what was changed.

## Review comments

Every review comment gets a reply, and the thread gets resolved. Both, not
one or the other: a reply with the thread left open reads as unfinished,
and a resolve with no reply reads as dismissal.

Three outcomes, all acceptable, none silent:

- **Fixed** - reply saying what changed, and in which commit. Resolve.
- **Not fixing** - reply saying why. Resolve.
- **Fixing later** - open an issue, reply with its number. Resolve.

This holds for review comments from Claude as much as from a person. A
review that finds a real bug and gets no response is worse than no review,
because the next one is easier to ignore.

## Testing

```bash
./tests/regression.sh        # must pass before opening a PR
./tests/regression.sh -v     # show output of failures
```

Every case in that suite corresponds to a bug that was actually found, or
to a guarantee the README makes. **If you fix a bug, add the case that
would have caught it.** Three adversarial reviews found real data-loss
defects in code that looked careful; the suite is the only thing that stops
them coming back.

The suite runs entirely in a sandbox under `$TMPDIR` and never touches a
real save directory, hub, or backup volume. Keep it that way.

## CI

Runs on macOS runners, deliberately. The tool depends on BSD behaviour -
`stat -f`, BSD `find`, openrsync, `cpio`, `shlock` - and a Linux runner
would pass green while the real target broke. Two bugs found during
development were exactly that shape: BSD `find` cannot parse
`-newermt @epoch`, and `cpio` exits 0 without copying anything when the
destination sits under a symlink.

`shellcheck` is advisory for now. It is not silenced, and its backlog is
worth triaging deliberately rather than blanket-disabling.

## Compatibility

Plain bash **3.2** - what macOS actually ships. No associative arrays, no
`${x^^}`, no `mapfile`, no `&>>`. CI enforces this; do not rely on the
runner's newer bash.

Dependencies are limited to `rsync`, `ssh`, `tailscale`, and `python3` for
JSON only.

## Releases

Tag `vX.Y.Z` matching `STS_VERSION` in the script. The release workflow
refuses to publish if they disagree or if the suite fails.
