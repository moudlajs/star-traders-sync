# The Go engine

`sts` has two implementations: the original bash script and a Go rewrite
(v2.0). The Go build passes the script's regression suite, every case that
is not about bash itself, and prints the same text. It is the base for the
Linux and Windows ports.

The app installs both, and a small launcher picks one. **The Go build is
the default** (since 1.8.0). The script stays installed as the fallback,
one command away.

## Where it lives

The app keeps the tool in `~/Library/Application Support/star-traders-sync/bin/`:

| File | What it is |
|---|---|
| `star-traders-sync` | the launcher: everything, including `~/bin/sts` and the nightly backup job, runs this |
| `star-traders-sync.bash` | the script |
| `star-traders-sync-go` | the Go build, for Apple silicon and Intel |

## Choosing the engine

```bash
echo bash > ~/.config/star-traders-sync/engine   # use the script
sts --version                                    # same version either way
```

The launcher reads the first word of that file: exactly `bash`, lower case,
runs the script, and anything else, or no file at all, runs the Go build. `STS_ENGINE=bash` or
`STS_ENGINE=go` in the environment overrides it for one command:

```bash
STS_ENGINE=bash sts status
```

Choose the same engine on both Macs. The two are compatible, because they
share the hub, the lock and the state file. One engine on both machines
just makes it clear which one a problem came from.

## Going back

```bash
echo bash > ~/.config/star-traders-sync/engine
```

Nothing else changes: the config, the state file, the hub and the safety
copies are the same for both engines. Deleting the file goes back to the
default, the Go build. If the Go build is ever missing, the launcher runs
the script and says so on stderr.

## The nightly backup job

It runs the launcher too, so it follows the same choice, and its Full Disk
Access grant still applies: the grant belongs to the backup job's own
launcher, which starts this one ([backups.md](backups.md)).

## Downloading it on its own

Each release attaches `star-traders-sync-go-darwin-universal`,
with a `.sha256` and a `.sig`. The `.sig` is signed with the same release
key as the app's update, so you can check the binary before using it:

```bash
shasum -a 256 -c star-traders-sync-go-darwin-universal.sha256
```
