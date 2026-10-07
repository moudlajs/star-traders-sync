# The Go engine

`sts` has two implementations: the original bash script and a Go rewrite
(v2.0). The Go build passes the script's regression suite, every case that
is not about bash itself, and prints the same text. It is the base for the
Linux and Windows ports.

The app installs both, and a small launcher picks one. **The script is the
default.** The Go build runs only when you choose it.

## Where it lives

The app keeps the tool in `~/Library/Application Support/star-traders-sync/bin/`:

| File | What it is |
|---|---|
| `star-traders-sync` | the launcher: everything, including `~/bin/sts` and the nightly backup job, runs this |
| `star-traders-sync.bash` | the script |
| `star-traders-sync-go` | the Go build, for Apple silicon and Intel |

## Choosing the engine

```bash
echo go > ~/.config/star-traders-sync/engine     # use the Go build
sts --version                                    # same version either way
```

The launcher reads the first word of that file. `STS_ENGINE=go` or
`STS_ENGINE=bash` in the environment overrides it for one command:

```bash
STS_ENGINE=go sts status
```

Choose the same engine on both Macs. The two are compatible, because they
share the hub, the lock and the state file. One engine on both machines
just makes it clear which one a problem came from.

## Going back

```bash
echo bash > ~/.config/star-traders-sync/engine
```

Or delete the file. Nothing else changes: the config, the state file, the
hub and the safety copies are the same for both engines. If `go` is chosen
but the Go build is missing, the launcher runs the script and says so on
stderr.

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
