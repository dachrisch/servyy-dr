# Disaster recovery — `servyy-container`

If the server is lost, this is the whole procedure. You need ONE other machine
(Linux or macOS), the new server's address and login, the passphrase, and the
inventory host name to rebuild. No production hostname or endpoint is baked
into the bootstrap: the production endpoints and the bundle's contents come
from the encrypted bundle.

## What you need

- **The passphrase**: the Vaultwarden item named **DR bundle - servyy-dr
  passphrase**. Unlock your password manager with the master password from
  your offline copy. Never paste the passphrase into chat, CI logs or a shell
  history.
- The new server's address (or DNS name), its login user (`root`, or a sudo
  user such as `ubuntu`) and that user's password **or** a provider-installed
  SSH key.
- The inventory host name to rebuild, passed explicitly with `--server`. There
  is no default, and no production name is implied.
- On the operator machine: only `bash`, `curl` and the OpenSSH client tools
  (`ssh` and `ssh-keygen`). No repo, no keys from elsewhere, no Vaultwarden
  CLI, no `age`/`restic`/`ansible`, no admin rights needed. Works with macOS
  bash 3.2.

## The two commands

```bash
curl -fsSL https://raw.githubusercontent.com/dachrisch/servyy-dr/main/bootstrap.sh -o bootstrap.sh
bash bootstrap.sh --host <new-host> --user <login-user> --server <inventory-host> [--identity <keyfile>] \\
  [--rehearsal] [--snapshot <id>] [--fresh] [--branch <name>] [--port 22]
```

`--server <inventory-host>` is **required** in both operator and remote mode;
the script refuses to run without it and has no default. The production
endpoints it needs (the repository path and the rehearsal blocking list) come
from the encrypted bundle, not from the script or this document.

`--identity <keyfile>` makes SSH use exactly that private key. Without it, the
agent is ignored and a password is requested before any key; the usual
`~/.ssh/id_*` files are only a fallback when the server offers no password
auth. If the server reports "Too many authentication failures", use
`--identity` or run the script with `SSH_AUTH_SOCK=`. These options are used
for every SSH connection, including reconnects after a reboot. The remote
phase forces `LANG=C.UTF-8 LC_ALL=C.UTF-8` before doing anything, so a locale
forwarded from the operator that does not exist on the target cannot break
Ansible. Only a genuinely dropped SSH connection (exit 255, i.e. a target
reboot) is retried; a real remote failure stops immediately with a "fix and
re-run, it resumes" hint, so a deterministic error is not repeated (and the
password is not asked again).

A rehearsal against a fresh root-only host has the same form:

```bash
bash bootstrap.sh --host <new-host> --user root --server <inventory-host> --rehearsal
```

The operator side first establishes one SSH ControlMaster (a password is typed
at most once). It then prints the target host key fingerprint read from its
dedicated temporary `known_hosts` with `ssh-keygen -lf`. **Compare that
fingerprint with the provider console if one is available.** Pinning is
deliberately not used: the script uses `StrictHostKeyChecking=accept-new`, so a
rebuilt host with a new key is not blocked by a stale pin.

You are prompted for the bundle passphrase **once**, hidden, after that
fingerprint line. If `<login-user>` is not `root`, the script also caches
`sudo` over the SSH tty (one password prompt) and then uses `sudo -n` for all
remote work. All packages, `age`, `restic`, Docker, Ansible and the restore run
**on the target as root**. The passphrase travels only over the SSH stdin to
the remote `age -d`; it is never in argv, an environment variable, a file or a
log on either machine.

`--snapshot <id>` pins a restic snapshot (default `latest`). `--branch <name>`
overrides the checkout branch. The branch default has one home:
`DR_DEFAULT_BRANCH` in `bootstrap.sh`, now `master`. `--port` defaults to 22.

## What `--rehearsal` does

It resolves the production endpoints **from the encrypted bundle** to their
current A and AAAA records **at runtime** with `getent`, then installs an
nftables forward-chain rule on the target dropping all traffic to/from those
addresses. No address is hardcoded, the Storage Box is not among those
endpoints and stays reachable, and the rule is re-applied after every reconnect
(it does not survive a reboot). Without `--rehearsal`, nothing is blocked.

## What happens on a reboot or dropped SSH

The operator side keeps one SSH ControlMaster so a password is typed once. If
the target reboots (the Docker-group reboot) or the SSH connection drops, the
operator side waits for SSH to return, reconnects and re-runs the remote phase.
The remote phase is idempotent and resumable (restore marker, clone-once,
idempotent playbook); it does not wipe restored data. The passphrase is kept in
memory and re-sent from there — you will not be asked again. A real remote
failure is reported and stops the loop.

### Resume vs fresh

The staging marker records the restored snapshot ID. On a resume the remote
phase compares it with the snapshot it now wants: the latest home snapshot, or
the ID given with `--snapshot`. If they match, the existing staging tree and
checkout are reused (the normal resume). If they differ, the bootstrap restores
into a **new staging directory**, stops the compose stacks, moves the old
checkout aside (kept, not deleted), re-clones from the new bare repo, and takes
the data trees from the new staging. This is how a fix pushed to the private
Forgejo repo reaches a host that was resumed from an older snapshot. Pass
`--fresh` to force that path even when the IDs are equal (e.g. after a code fix
without a new backup). `--snapshot <id>` pins an older snapshot; re-running
without it detects the newer one and refreshes.

## What the run does

1. Installs tooling on the target (`age`, `restic`, `git`, Docker + compose,
   `ansible`, `sqlite3`, `curl`, `jq`, `nftables`, `python3-yaml`).
2. Downloads the minimal `bundle.age` from this public repo and decrypts it.
   Its contents — including the production endpoints and everything needed to
   reach the backup — come from the encrypted bundle; they are not listed here
   or hardcoded in the script. Controller configuration and secrets are not in
   any git repo: they are restored from the home backup and copied into the
   fresh checkout during DR. This public repo never holds plaintext secrets.
3. Sets up Storage Box SSH and probes the repository with
   `restic snapshots --no-lock --latest 1 --tag home`. The Storage Box host key
   is printed from the target's `known_hosts` for information only; nothing is
   pinned or enforced. **The bootstrap is strictly read-only towards the backup
   repository**: it never runs `check`, `prune`, `forget`, `unlock`,
   `rebuild-index` or any snapshot-removal flag, and the restore uses
   `--no-lock`. The
   repository may be shared with a still-running old host, another operator, or
   a backup timer from the old host; the bootstrap must never lock or mutate it.
   `dr/test-readonly-repo.sh` in the private repo is a grep guard that fails if
   any of those operations appear in DR code.
4. Restores `restic-home` into `/srv/dr-restore` (never the final checkout).
5. Clones `servyy-container` from the restored bare repo with `--no-local`.
6. Creates the uid-1000 `cda` user (renaming an existing uid-1000 user, or
   creating it on root-only VPS images without clobbering the checkout).
7. Runs `dr/bootstrap.yml` from the restored checkout: full data trees, newest
   hourly `.backup` dumps with `-wal`/`-shm` deleted, `integrity_check`, fixups,
   Forgejo/Vaultwarden on `127.0.0.1:3000`, `git fsck`, `forgejo doctor`, a fresh
   CLI token, and a full `plays/user.yml` against the restored local Forgejo.
   `dr_mode=true` skips the controller-only setup-home skills/plugin and all
   user-scope timer starts (timers/backups are a later `servyy.yml` job, and
   `docker-photo-index` belongs to PhotoPrism, which DR does not deploy).
   `dr_rehearsal_container`, set automatically inside a container, only skips
   the Docker-group reboot; on a real host it is false and that reboot runs.

**Backups are NOT configured yet.** The restic timers come from `servyy.yml`
(system + restic), which this bootstrap does not run. The user-scope units in
the restored repo (e.g. `docker-photo-index.timer`) are installed/enabled, but
they are not restic backup timers. Configure backups by running `servyy.yml`
against the new host after the rest of the stack is verified.

## How to verify

On the target:

```bash
curl -fsS http://localhost:3000/api/v1/version
docker exec ci.forgejo forgejo doctor check --all
for d in /home/cda/servyy-container/ci/data/git/repositories/cda/*.git; do \
  git -c safe.directory='*' --git-dir="$d" fsck --full --no-dangling || exit 1; done
sqlite3 /home/cda/servyy-container/pass/vw-data/db.sqlite3 'PRAGMA integrity_check;'
git -C /home/cda/servyy-container remote -v
```

`plays/user.yml` must end with `failed=0`. Mirror refs must equal the restored
bare repo's refs (the bootstrap checks and reports this).

From the operator machine, reach the restored Forgejo UI/API with:

```bash
ssh -L 3000:localhost:3000 <user>@<host>
```

then open `http://localhost:3000`.

## What is next (after the restore) — glue phase

As its final phase, the bootstrap hands over to the normal production playbook
from the restored checkout: `ansible-playbook servyy.yml -i production --limit
<server>`, where `<server>` is exactly the host given with `--server`. It is
explicit and has no default. The checked-in inventory is not edited; extra-vars
point that host at the target (`ansible_host=127.0.0.1`, `ansible_connection=local`),
and all seeds/secrets come from the restored repo. `--rehearsal` runs only
`--syntax-check` and `--list-hosts` and prints "rehearsal: full servyy.yml
skipped (would act on production); glue verified". Without `--rehearsal` it asks
`Run full servyy.yml for <server> on <host>? [yes/NO]` (default NO) and, on yes,
streams the full run to the operator; a failure stops with the resume hint.
Afterwards the only manual steps are DNS: point the names at the new IP with
`dns-master`/Porkbun, and check the Traefik certificates.
- Forgejo **can adopt** bare repos that exist on disk but are absent from its
  database via `/admin/repos/unadopted`; this is not needed after a clean
  restore (the hourly dumps include every repo).
- Remove the token minted for the bootstrap (`dr-restore-v3`) when finished.

## References

- [credentials-sources.md](credentials-sources.md) — where each credential
  comes from.
- `bundle.inputs.sha256` — hash of the minimal bundle inputs; the offline
  staleness guard in the private repo is
  `scripts/secrets-bundle.sh --check`.
