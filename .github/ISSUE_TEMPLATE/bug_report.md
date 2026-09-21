---
name: Bug report
about: Something went wrong
labels: bug
assignees: moudlajs
---

<!--
A report has evidence to collect rather than a proposal to make, so the
headings here differ from the Task template on purpose. They are still a
closed set: use these, in this order.

Every failure in this tool has a distinct exit code and a log line. With
those two things a report is usually actionable immediately; without them it
is guesswork. Please fill in at least the first four.

Title: "<what goes wrong>", or "fix(<scope>): <what goes wrong>" if you
already know where it lives. Describe the symptom, not your guess at the
cause.
-->

## What happened

<!-- One or two sentences. What you ran, what you expected, what you got. -->

## Command and exit code

```
$ sts <command>
...
exit code:
```

## Version

```
$ sts --version

$ sw_vers -productVersion
```

## Which machine

<!-- Is this the hub host, or a client? `sts status` prints which. -->

## Log excerpt

<!--
From ~/Library/Logs/star-traders-sync/star-traders-sync.log
The last 20 lines around the failure is usually enough. Re-running with
--verbose mirrors the log to your terminal.
-->

```

```

## Setup

<!--
Optional, but often decisive. For example: the backup volume's filesystem
(exFAT has no hard links), whether MagicDNS resolves, whether a path crosses
a symlink, Homebrew vs App Store Tailscale.
-->

## Cause

<!--
Optional, and usually filled in later rather than by the reporter. Once the
cause is known, record it here with the file:line - the issue is where the
reasoning is kept, and a diff alone does not preserve it.
-->
