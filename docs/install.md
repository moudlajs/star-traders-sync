# Installing

One-time setup, per machine. Once `sts doctor` reports everything green you
should not need this page again — the everyday commands are in the
[README](../README.md).

## On each machine

```bash
git clone <this repo> ~/Repos/star-traders-sync
cd ~/Repos/star-traders-sync
./install.sh
$EDITOR ~/.config/star-traders-sync/config
sts status
```

`install.sh` symlinks `star-traders-sync` and the short alias `sts` into
`~/bin`, creates the config directory, and copies `config.example` into
place **only if no config exists** — it never overwrites one. If `~/bin`
is not on your `PATH` it warns and carries on rather than failing.

Every config key is documented in `config.example`.

## One-time SSH setup on each client

The hub must accept a non-interactive key-based login. `BatchMode=yes`
cannot type a password, so a key is required, not a convenience.

```bash
# 1. ON THE HUB - print its real host key fingerprint
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

# 2. ON THE CLIENT - confirm the same fingerprint comes back over the wire
ssh-keyscan -t ed25519 <hub-tailnet-ip> 2>/dev/null | ssh-keygen -lf -

# 3. ON THE CLIENT - only if they match
ssh-keyscan -t ed25519 <hub-tailnet-ip> >> ~/.ssh/known_hosts
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -C "sts@$(hostname -s)"
ssh-copy-id -i ~/.ssh/id_ed25519.pub <hubuser>@<hub-tailnet-ip>

# 4. ON THE CLIENT - prove it is non-interactive
ssh -o BatchMode=yes <hubuser>@<hub-tailnet-ip> 'echo OK'
```

`ssh-copy-id` asks for the **hub account's** password, not the client's.
If it keeps rejecting you, that is almost always the cause. You can skip
it entirely by appending the client's `~/.ssh/id_ed25519.pub` to the hub's
`~/.ssh/authorized_keys` by hand.

Remote Login must be on at the hub: System Settings → General → Sharing →
Remote Login. Check that your user is permitted:

```bash
dseditgroup -o checkmember -m <hubuser> com.apple.access_ssh
```

After installing, run `sts doctor` — it will tell you what is still missing
and exactly how to fix it, which is quicker than following a checklist. What
it checks, and which repairs `--fix` will and will not make, is in
[troubleshooting.md](troubleshooting.md#what-doctor-checks).

## What has to match across the two machines

| | Must match? | |
|---|---|---|
| **Tailscale tailnet** | **yes** | the machines have to see each other |
| Steam account | practically | you need the game installed on both |
| **Apple ID** | **no** | nothing here touches iCloud |
| macOS version | no | tested on 15.x |
| Username | no | `HUB_USER` is the hub's account; `~/` expands per machine |

## First time: seeding the hub

The hub starts empty, and filling it is a one-way decision, so it is never
done silently. From the machine that holds your real saves:

```bash
sts push --force=local
```

Then on the **other** machine, the first `sts pull` will report a
**conflict**. That is correct, not a bug: the game creates `core.db` and
the templates the first time it launches, even with no campaigns, so that
machine genuinely has a save directory of its own and the tool will not
guess which one you meant. Resolve it once:

```bash
sts pull --force=hub
```

After that, `sts play` handles everything and you should never need a
`--force` flag again unless you forget to push before switching machines.

**Getting these backwards overwrites real saves with an empty directory.**
The rule: `--force=local` on the machine whose saves you want to keep;
`--force=hub` on the machine you want to overwrite. `sts status` tells you
which side has what before you commit to either.

## Next

- Scheduled backups to an external disk, on the hub host: [backups.md](backups.md)
- Every exit code and a row per failure: [troubleshooting.md](troubleshooting.md)
- Why the tool is shaped this way: [design.md](design.md)
