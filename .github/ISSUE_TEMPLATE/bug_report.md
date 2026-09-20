---
name: Bug report
about: Something went wrong
labels: bug
assignees: moudlajs
---

<!--
Every failure in this tool has a distinct exit code and a log line. With
those two things a report is usually actionable immediately; without them
it is guesswork. Please fill in at least the first four.
-->

**What happened**

<!-- One or two sentences. What you ran, what you expected, what you got. -->

**Command and exit code**

```
$ sts <command>
...
exit code:
```

**Version**

```
$ sts --version

$ sw_vers -productVersion
```

**Which machine**

<!-- Is this the hub host, or a client? `sts status` prints which. -->

**Log excerpt**

<!--
From ~/Library/Logs/star-traders-sync/star-traders-sync.log
The last 20 lines around the failure is usually enough. Re-running with
--verbose mirrors the log to your terminal.
-->

```

```

**Anything relevant about the setup**

<!--
Optional, but often decisive. For example: the backup volume's filesystem
(exFAT has no hard links), whether MagicDNS resolves, whether a path
crosses a symlink, Homebrew vs App Store Tailscale.
-->
