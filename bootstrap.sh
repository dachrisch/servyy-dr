#!/usr/bin/env bash
# DR v3 — zero-knowledge bootstrap from ANY operator machine.
#
# Operator machine needs ONLY bash, curl and OpenSSH (Linux or macOS bash 3.2).
#   curl -fsSL https://raw.githubusercontent.com/dachrisch/servyy-dr/main/bootstrap.sh -o bootstrap.sh
#   bash bootstrap.sh --host <ip> --user <login-user> --server <inventory-host> [--rehearsal] [--snapshot <id>] [--branch <name>] [--port 22]
#
# The passphrase is prompted for once on the operator machine and sent ONLY
# over the SSH stdin to the remote age -d. Nothing secret is written locally.
# The private Forgejo repo carries no secrets: the DR snapshot restores the
# controller-only files and bootstrap overlays them before any playbook runs.
# All packages/restic/docker/ansible work runs on the TARGET as root.
#
# DR_DEFAULT_BRANCH is the ONE place the default checkout branch is defined.
# The switch is complete: master is the default. --branch overrides it for a
# rehearsal.
set -u
set -o pipefail
umask 077

RAW="https://raw.githubusercontent.com/dachrisch/servyy-dr/main"
DR_DEFAULT_BRANCH="master"

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://raw.githubusercontent.com/dachrisch/servyy-dr/main/bootstrap.sh -o bootstrap.sh
  bash bootstrap.sh --host <ip> --user <login-user> --server <inventory-host> [--identity <keyfile>] \\
    [--rehearsal] [--snapshot <id>] [--fresh] [--branch <name>] [--port 22]

Only bash, curl and the OpenSSH client tools (ssh, ssh-keygen) are needed on
this machine. The passphrase is prompted for once here, after the target host
key fingerprint is shown; everything else happens on the remote host as root.

SSH authentication:
  --server <host>       inventory host to rebuild (REQUIRED in both modes)
  --fresh               re-restore into a new staging dir even if the snapshot ID matches
  --identity <keyfile>  use exactly that private key (the agent is ignored)
  Without it, the agent is ignored and a password is asked before any key;
  the usual ~/.ssh/id_* files are only a fallback if no password is offered.
  If the server reports "Too many authentication failures", use --identity or
  run the script with SSH_AUTH_SOCK= . The remote phase forces LANG/LC_ALL to
  C.UTF-8, so an operator locale that is absent on the target is harmless.
  Only a dropped SSH connection (reboot) is retried; a real failure stops with
  a hint to fix it and re-run (the remote phase resumes).
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_remote() {
  set -e
  # The operator may forward de_DE.UTF-8 (or any other locale) via SendEnv.
  # C.UTF-8 exists on Ubuntu 24.04 and Debian 12; force it before any command
  # so Ansible cannot fail with "unsupported locale setting".
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
  STEP=0
  STAGING="/srv/dr-restore"
  CHECKOUT="/home/cda/servyy-container"
  RESTIC_HOST=""   # set from the encrypted bundle's production endpoints below
  IS_CONTAINER=false
  if command -v systemd-detect-virt >/dev/null 2>&1 \
     && systemd-detect-virt --container >/dev/null 2>&1; then
    IS_CONTAINER=true
  fi

  step() {
    STEP=$((STEP + 1))
    printf '\n[remote %d/12] %s\n' "$STEP" "$*" >&2
  }
  remote_die() {
    printf 'DR-REMOTE-FAILED: %s\n' "$*" >&2
    exit 1
  }

  WORK="$(mktemp -d /tmp/dr-remote.XXXXXX)"
  chmod 700 "$WORK"
  # shellcheck disable=SC2329  # invoked via the EXIT trap
  cleanup_remote() {
    local rc=$?
    find "$WORK" -type f -exec shred -u -- {} + 2>/dev/null || rm -rf -- "$WORK"
    [ "$rc" -eq 0 ] || printf 'DR-REMOTE-FAILED: remote phase exited %d\n' "$rc" >&2
    exit "$rc"
  }
  trap cleanup_remote EXIT

  # Read the passphrase FIRST; apt-time helpers can consume stdin later.
  PASS=""
  if [ -t 0 ] && [ -r /dev/tty ]; then
    printf 'DR bundle passphrase: ' > /dev/tty
    IFS= read -r -s PASS < /dev/tty || true
    printf '\n' > /dev/tty
  else
    IFS= read -r PASS || true
  fi
  [ -n "$PASS" ] || remote_die "empty passphrase"

  step "Install tooling on the target"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  # A reboot injected during package installation leaves dpkg half-configured.
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get -f install -y >/dev/null 2>&1 || true
  # A previous interrupted attempt may have left an incompletely signed
  # Docker repo. Remove only that file so apt update stays functional.
  if [ -f /etc/apt/sources.list.d/docker.list ] \
     && grep -q 'download.docker.com/linux' /etc/apt/sources.list.d/docker.list 2>/dev/null; then
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
  fi
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg jq sqlite3 rsync openssh-client patch nftables \
    python3 python3-yaml age restic git ansible docker.io bsdutils >/dev/null
  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y -qq --no-install-recommends docker-compose-v2 >/dev/null 2>&1 || true
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y -qq --no-install-recommends docker-compose-plugin >/dev/null 2>&1 || true
  fi
  # Ubuntu 24.04 ships docker-compose-v2 and Debian 12 ships
  # docker-compose-plugin. No third-party repo is needed (and a half-imported
  # signing key would break every later apt run).
  docker compose version >/dev/null 2>&1 || remote_die "docker compose plugin unavailable"
  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || remote_die "docker daemon is not running"
  printf 'tools: %s\n' "$(age --version) | $(restic version | head -1) | $(git --version)"

  step "Download and decrypt the public minimal bundle"
  curl -fsSL "$RAW/bundle.age" -o "$WORK/bundle.age"
  curl -fsSL "$RAW/bundle.inputs.sha256" -o "$WORK/bundle.inputs.sha256"
  printf 'bundle sidecar: %s\n' "$(tr -d '\n' < "$WORK/bundle.inputs.sha256")"
  printf '%s\n%s\n' "$PASS" "$PASS" \
    | script -qec "cd '$WORK' && age -d -o bundle.tar.gz '$WORK/bundle.age'" /dev/null >/dev/null 2>&1 \
    || remote_die "age decryption failed (wrong passphrase?)"
  PASS=""
  tar -xzf "$WORK/bundle.tar.gz" -C "$WORK"
  [ -f "$WORK/values.json" ] || remote_die "bundle has no values.json"

  step "Load bundle values and set up Storage Box SSH"
  python3 - "$WORK" <<'PY'
import base64, json, sys
from pathlib import Path
w = Path(sys.argv[1])
v = json.loads((w / "values.json").read_text())
if v.get("schema") != "dr-bundle-inputs-v3":
    raise SystemExit("ERROR: unexpected bundle schema")
inputs = v["inputs"]
# The bundle carries 10 labels; these are the ones this bootstrap needs.
required = {"storagebox.host", "storagebox.user", "storagebox.share",
            "storagebox.password", "ssh.storagebox_private",
            "ssh.storagebox_public", "restic.password_home",
            "dr.production_endpoints"}
missing = required - set(inputs)
if missing:
    raise SystemExit("ERROR: bundle missing labels: %s" % ", ".join(sorted(missing)))


def decode(label, single=False):
    meta = inputs[label]
    raw = meta["data"].encode() if meta["encoding"] == "text" else base64.b64decode(meta["data"], validate=True)
    return raw.decode().strip() if single else raw


(w / "values.env").write_text("".join(
    "%s='%s'\n" % (name, base64.b64encode(decode(label, True).encode()).decode())
    for label, name in (("storagebox.host", "SB_HOST"), ("storagebox.user", "SB_USER"),
                        ("storagebox.share", "SB_SHARE"), ("storagebox.password", "SB_PASS"),
                        ("restic.password_home", "RESTIC_PASSWORD"),
                        ("dr.production_endpoints", "PROD_ENDPOINTS"))))
(w / "id_storagebox").write_bytes(decode("ssh.storagebox_private"))
(w / "id_storagebox.pub").write_bytes(decode("ssh.storagebox_public"))
print("bundle labels: %s" % ", ".join(sorted(inputs)))
PY
  # shellcheck source=/dev/null
  . "$WORK/values.env"
  v() { printf '%s' "$1" | base64 -d; }
  SB_HOST=$(v "$SB_HOST"); SB_USER=$(v "$SB_USER"); SB_SHARE=$(v "$SB_SHARE")
  SB_PASS=$(v "$SB_PASS"); RESTIC_PASSWORD=$(v "$RESTIC_PASSWORD")
  PROD_ENDPOINTS="$(v "$PROD_ENDPOINTS")"
  # The first bundle endpoint names the restic host directory on Storage Box.
  RESTIC_HOST="$(printf '%s\n' "$PROD_ENDPOINTS" | cut -d, -f1 | tr -d '[:space:]')"
  [ -n "$RESTIC_HOST" ] || remote_die "bundle has no production endpoints"

  if [ "$REHEARSAL" = "true" ]; then
    step "Block bundle production endpoints (rehearsal only, DNS-resolved)"
    # Resolve every endpoint from the encrypted bundle at runtime (A + AAAA).
    # The Storage Box is not among them and stays reachable; without
    # --rehearsal this block never runs.
    BLOCK_IPS=""
    OLDIFS="$IFS"
    IFS=','
    set -- $PROD_ENDPOINTS
    IFS="$OLDIFS"
    for name in "$@"; do
      name="$(printf '%s' "$name" | tr -d '[:space:]')"
      [ -n "$name" ] || continue
      BLOCK_IPS="$BLOCK_IPS
$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}')
$(getent ahostsv6 "$name" 2>/dev/null | awk '{print $1}' | sed 's/%.*//')"
    done
    BLOCK_IPS="$(printf '%s\n' "$BLOCK_IPS" | sed '/^$/d' | sort -u)"
    nft delete table inet dr_rehearsal_block 2>/dev/null || true
    nft add table inet dr_rehearsal_block
    nft add chain inet dr_rehearsal_block block '{ type filter hook forward priority 0; }'
    count=0
    for ip in $BLOCK_IPS; do
      case "$ip" in
        *:*)
          nft add rule inet dr_rehearsal_block block iifname eth0 ip6 daddr "$ip" drop
          nft add rule inet dr_rehearsal_block block oifname eth0 ip6 saddr "$ip" drop;;
        *)
          nft add rule inet dr_rehearsal_block block iifname eth0 ip daddr "$ip" drop
          nft add rule inet dr_rehearsal_block block oifname eth0 ip saddr "$ip" drop;;
      esac
      count=$((count + 1))
    done
    printf 'rehearsal block applied: %d production address(es)\n' "$count"
  fi

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  install -m 600 "$WORK/id_storagebox" /root/.ssh/id_storagebox
  install -m 644 "$WORK/id_storagebox.pub" /root/.ssh/id_storagebox.pub
  {
    printf 'Host storagebox\n'
    printf '  HostName %s\n' "$SB_HOST"
    printf '  User %s\n' "$SB_USER"
    printf '  Port 23\n'
    printf '  IdentityFile /root/.ssh/id_storagebox\n'
    printf '  IdentitiesOnly yes\n'
  } > /etc/ssh/ssh_config.d/99-dr-storagebox.conf
  ssh-keyscan -p 23 "$SB_HOST" 2>/dev/null >> /root/.ssh/known_hosts || true
  # Informational only: nothing is pinned or enforced for the Storage Box.
  ssh-keygen -lf /root/.ssh/known_hosts 2>/dev/null \
    | grep -F "$SB_HOST" \
    | sed 's/^/[remote] storagebox host key (informational): /' >&2 || true

  step "Verify the backup is reachable (read-only probe, no lock)"
  export RESTIC_REPOSITORY="sftp://storagebox/$SB_SHARE/$RESTIC_HOST/restic-home"
  export RESTIC_PASSWORD
  # STRICTLY READ-ONLY towards the backup repository. `snapshots --no-lock`
  # takes no lock and touches nothing. Never use check/unlock/prune/forget:
  # the repo may be shared with a live old host or another operator.
  restic snapshots --no-lock --latest 1 --tag home >/dev/null \
    || remote_die "backup repository is not reachable with the bundled credentials"
  printf 'restic repository reachable (no lock taken): %s\n' "$RESTIC_REPOSITORY"

  step "Restore restic-home into a staging tree (snapshot-aware resume)"
  # Resolve the snapshot we actually want. "latest" is resolved read-only;
  # an explicit --snapshot is used verbatim. The ID is recorded in the marker
  # so a resumed host notices that the private repo has moved on.
  WANT="$SNAPSHOT"
  if [ "$WANT" = "latest" ]; then
    WANT="$(restic snapshots --no-lock --latest 1 --tag home --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["short_id"])' || true)"
    [ -n "$WANT" ] || remote_die "cannot resolve the latest home snapshot"
  fi

  BASE_STAGING="$STAGING"
  MARK="$STAGING/.dr-restore-complete"
  REFRESH=false
  if [ -f "$MARK" ]; then
    OLD="$(tr -d '\r\n' < "$MARK")"
    if [ "$OLD" != "$WANT" ] || [ "$FRESH" = "true" ]; then
      printf '[remote] staging has snapshot %s but %s is wanted; refreshing\n' "$OLD" "$WANT"
      REFRESH=true
      STAGING="$STAGING.$WANT"
      MARK="$STAGING/.dr-restore-complete"
    fi
  fi

  if [ ! -f "$MARK" ]; then
    # Only staging is ever wiped; the final checkout is never deleted.
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    # --no-lock keeps the restore from taking even a non-exclusive repo lock.
    # Both the checkout (bare repo + controller-only secret files) and the
    # deploy user's .ssh tree are restored; the private repo itself carries no
    # secrets any more.
    restic --no-lock restore "$WANT" --target "$STAGING" \
      --include /home/cda/servyy-container --include /home/cda/.ssh
    printf '%s\n' "$WANT" > "$MARK"
    # Keep the base marker current too: a later resume without --fresh
    # must recognise that the already-refreshed staging is up to date.
    printf '%s\n' "$WANT" > "$BASE_STAGING/.dr-restore-complete"
  fi
  BARE="$STAGING/home/cda/servyy-container/ci/data/git/repositories/cda/servyy-container.git"
  [ -d "$BARE" ] || remote_die "restored bare repo not found"
  printf 'snapshot: %s (staging %s)\n' "$WANT" "$STAGING"

  if [ "$REFRESH" = "true" ] && [ -d "$CHECKOUT" ]; then
    step "Refresh the checkout from the newer bare repo (old one kept aside)"
    docker compose -f "$CHECKOUT/ci/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
    docker compose -f "$CHECKOUT/pass/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
    mv "$CHECKOUT" "${CHECKOUT}.prev.$(date +%s)"
  fi

  step "Clone servyy-container from the restored bare repo (--no-local)"
  git config --global --add safe.directory "$BARE"
  git config --global --add safe.directory '*'
  if [ ! -d "$CHECKOUT/.git" ]; then
    git clone --no-local -b "$BRANCH" "$BARE" "$CHECKOUT"
  fi
  printf 'checkout: %s (branch %s)\n' "$CHECKOUT" "$(git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD)"

  step "Prepare the deploy user (uid 1000)"
  if ! id cda >/dev/null 2>&1; then
    uid1000="$(getent passwd 1000 | cut -d: -f1 || true)"
    if [ -n "$uid1000" ]; then
      oldgrp="$(id -gn "$uid1000")"
      [ "$oldgrp" = "cda" ] || groupmod -n cda "$oldgrp" 2>/dev/null || true
      usermod -l cda -d /home/cda "$uid1000"
    else
      gid1000="$(getent group 1000 | cut -d: -f1 || true)"
      if [ -n "$gid1000" ]; then
        [ "$gid1000" = "cda" ] || groupmod -n cda "$gid1000" 2>/dev/null || true
      else
        groupadd -g 1000 cda
      fi
      useradd -u 1000 -g 1000 -M -d /home/cda -s /bin/bash cda
    fi
  fi
  usermod -aG sudo cda 2>/dev/null || true
  usermod -aG docker cda 2>/dev/null || true
  chown cda:cda /home/cda 2>/dev/null || true
  id cda >/dev/null 2>&1 || remote_die "no deploy user cda (uid 1000)"

  step "Overlay restored secrets into the fresh checkout and home"
  # The private Forgejo repo is secret-free. Every credential used by Ansible
  # is copied from the restic home snapshot staged above, BEFORE dr/bootstrap.yml
  # or the glue phase runs. Nothing secret is ever written on the operator.
  S="$STAGING/home/cda/servyy-container"
  D="$CHECKOUT"
  [ -f "$S/ansible/plays/vars/secrets.yml" ] \
    || remote_die "restored snapshot has no ansible/plays/vars/secrets.yml"
  overlay_files() {
    # shellcheck disable=SC2086  # the pattern must expand as a glob
    for f in "$1"/$3; do
      [ -f "$f" ] || continue
      mkdir -p "$2"
      install -m 600 -o cda -g cda "$f" "$2/$(basename "$f")"
    done
  }
  mkdir -p "$D/ansible/plays/vars/keys"
  install -m 600 -o cda -g cda "$S/ansible/plays/vars/secrets.yml" \
    "$D/ansible/plays/vars/secrets.yml"
  overlay_files "$S/ansible/plays/vars" "$D/ansible/plays/vars" '.[!.]*'
  overlay_files "$S/ansible/plays/vars/keys" "$D/ansible/plays/vars/keys" '*'
  overlay_files "$S/ansible/plays/roles/ls_app/vars" \
    "$D/ansible/plays/roles/ls_app/vars" 'secret_*.yaml'
  overlay_files "$S/ansible/plays/roles/ls_demo/vars" \
    "$D/ansible/plays/roles/ls_demo/vars" 'secret_*.yaml'
  overlay_files "$S/finance/import" "$D/finance/import" 'eb.pem'
  mkdir -p /home/cda/.ssh
  chmod 700 /home/cda/.ssh
  for name in vw.key ci_lehel id_storagebox id_storagebox.pub eb.pem \
              ls_ssh_key_bigservy ls_ssh_key_bigservy.pub \
              ls_ssh_key_lehel ls_ssh_key_lehel.pub \
              ls_ssh_key_servy ls_ssh_key_servy.pub \
              ls_ssh_key_servyy-test ls_ssh_key_servyy-test.pub; do
    [ -f "$S/ansible/plays/vars/keys/$name" ] || continue
    install -m 600 -o cda -g cda "$S/ansible/plays/vars/keys/$name" "/home/cda/.ssh/$name"
  done
  chown -R cda:cda "$D/ansible/plays/vars" 2>/dev/null || true
  printf 'secrets overlaid from snapshot %s (checkout + /home/cda/.ssh)\n' "$WANT"

  step "Generate a localhost inventory"
  mkdir -p "$WORK/ansible"
  sed 's/^rehearsal /rehearsal ansible_host=127.0.0.1 /' \
    "$CHECKOUT/dr/inventory.example" > "$WORK/ansible/inventory"
  INVENTORY="$WORK/ansible/inventory"
  grep -q '^rehearsal ' "$INVENTORY" || remote_die "inventory example has no rehearsal host"

  step "Hand over to dr/bootstrap.yml"
  cd "$CHECKOUT"
  ANSIBLE_LIBRARY="$CHECKOUT/ansible/library" \
  ansible-playbook -i "$INVENTORY" dr/bootstrap.yml \
    -e "dr_staging=$STAGING" -e "dr_checkout=$CHECKOUT" -e "dr_branch=$BRANCH" \
    -e "dr_snapshot=$SNAPSHOT" -e "dr_rehearsal_container=$IS_CONTAINER"

  cd "$CHECKOUT/ansible"
  step "Final phase: production servyy.yml glue for $SERVER"
  # The normal production path, exactly as an operator would run it. The
  # repo inventory is NOT edited: extra-vars point the chosen host at this
  # machine, and all secrets/seeds were overlaid from the restic snapshot
  # into the checkout/home above.
  # servyy.yml needs Galaxy roles (e.g. sebthebert.ubuntu_pro) even for a
  # syntax check; install them from the restored repo's requirements file.
  # Install into the deploy user's paths: the playbook runs with HOME=/home/cda.
  HOME=/home/cda USER=cda ansible-galaxy role install -r requirements.yml >/dev/null
  HOME=/home/cda USER=cda ansible-galaxy collection install -r requirements.yml >/dev/null

  SERVE_ARGS=(
    servyy.yml
    -i production
    --limit "$SERVER"
    -e ansible_host=127.0.0.1
    -e ansible_connection=local
    -e ansible_python_interpreter=/usr/bin/python3
  )
  if [ "$REHEARSAL" = "true" ]; then
    ANSIBLE_LIBRARY="$CHECKOUT/ansible/library" USER=cda HOME=/home/cda \
      ansible-playbook "${SERVE_ARGS[@]}" --syntax-check
    hosts="$(ANSIBLE_LIBRARY="$CHECKOUT/ansible/library" USER=cda HOME=/home/cda \
      ansible-playbook "${SERVE_ARGS[@]}" --list-hosts 2>&1)"
    printf '%s\n' "$hosts"
    case "$hosts" in
      *"$SERVER"*) ;;
      *) remote_die "--list-hosts did not include $SERVER";;
    esac
    printf 'rehearsal: full servyy.yml skipped (would act on production); glue verified\n'
  elif [ "$RUN_SERVER" = "true" ]; then
    ANSIBLE_LIBRARY="$CHECKOUT/ansible/library" USER=cda HOME=/home/cda \
      ansible-playbook "${SERVE_ARGS[@]}"
    printf 'full servyy.yml completed for %s\n' "$SERVER"
  else
    printf 'full servyy.yml not requested; skipped\n'
  fi

  step "Remote phase finished"
  printf 'DR-REMOTE-DONE\n'
}


MODE="operator"
HOST=""
LOGIN_USER=""
PORT="22"
REHEARSAL=false
SNAPSHOT="latest"
BRANCH="$DR_DEFAULT_BRANCH"
IDENTITY=""
SERVER=""
RUN_SERVER=false
FRESH=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      MODE="remote"; shift;;
    --host)
      [ "$#" -ge 2 ] || die "--host needs an address"; HOST="$2"; shift 2;;
    --user)
      [ "$#" -ge 2 ] || die "--user needs a login name"; LOGIN_USER="$2"; shift 2;;
    --port)
      [ "$#" -ge 2 ] || die "--port needs a number"; PORT="$2"; shift 2;;
    --rehearsal)
      REHEARSAL=true; shift;;
    --snapshot)
      [ "$#" -ge 2 ] || die "--snapshot needs an id"; SNAPSHOT="$2"; shift 2;;
    --branch)
      [ "$#" -ge 2 ] || die "--branch needs a name"; BRANCH="$2"; shift 2;;
    --identity)
      [ "$#" -ge 2 ] || die "--identity needs a private key file"; IDENTITY="$2"; shift 2;;
    --fresh)
      FRESH=true; shift;;
    --server)
      [ "$#" -ge 2 ] || die "--server needs an inventory host"; SERVER="$2"; shift 2;;
    --run-server)
      RUN_SERVER=true; shift;;
    -h | --help)
      usage; exit 0;;
    *)
      die "unknown argument: $1";;
  esac
done

# Both modes require an explicit inventory host; no production hostname is
# hardcoded in this script (endpoints come from the encrypted bundle).
[ -n "$SERVER" ] || die "missing --server <inventory-host>; re-run with --server <host> from your inventory (no default is baked in)"

if [ "$MODE" = "remote" ]; then
  run_remote
  exit $?
fi

# ---------------------------------------------------------------------------
# OPERATOR SIDE
# ---------------------------------------------------------------------------
[ -n "$HOST" ] || die "missing --host"
[ -n "$LOGIN_USER" ] || die "missing --user"
for c in curl ssh; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' is required on the operator machine"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dr-operator.XXXXXX")" || die "mktemp failed"
chmod 700 "$TMP"
PASS=""
# shellcheck disable=SC2329  # invoked via the EXIT/INT/TERM trap
cleanup_operator() {
  PASS=""
  rm -rf "$TMP"
}
trap cleanup_operator EXIT INT TERM

TARGET="$LOGIN_USER@$HOST"

# A foreign machine may have a full ssh-agent. Never offer agent keys: with
# --identity use exactly that key, otherwise ask for a password first and only
# fall back to the default ~/.ssh/id_* files if no password auth is offered.
if [ -n "$IDENTITY" ]; then
  SSH_AUTH_OPTS=(-o IdentitiesOnly=yes -o IdentityAgent=none -i "$IDENTITY" \
    -o PreferredAuthentications='publickey,keyboard-interactive,password')
else
  SSH_AUTH_OPTS=(-o IdentitiesOnly=yes -o IdentityAgent=none \
    -o PreferredAuthentications='keyboard-interactive,password,publickey')
fi

auth_hint() {
  printf '[operator] hint: the server rejected too many authentication attempts. Use --identity <keyfile> or run with SSH_AUTH_SOCK= (no agent).\n' >&2
}

# Newer OpenSSH can remove the default LANG/LC_* SendEnv list. Probe support
# so older macOS clients still work; the remote phase forces C.UTF-8 anyway.
if ssh -G -o 'SendEnv=-LC_*' -o 'SendEnv=-LANG' localhost >/dev/null 2>&1; then
  SSH_ENV_OPTS=(-o 'SendEnv=-LC_*' -o 'SendEnv=-LANG')
else
  SSH_ENV_OPTS=()
fi

ssh_cmd() {
  ssh \
    "${SSH_AUTH_OPTS[@]}" \
    "${SSH_ENV_OPTS[@]}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$TMP/known_hosts" \
    -o ControlMaster=auto \
    -o ControlPath="$TMP/cm-%C" \
    -o ControlPersist=10m \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=15 \
    -p "$PORT" \
    "$@"
}

printf '[operator] opening SSH ControlMaster to %s (password asked at most once)\n' "$TARGET"
ssh_cmd -M -N -f "$TARGET" 2>&1 | tee "$TMP/ssh-init.err" >&2
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  if grep -q 'Too many authentication failures' "$TMP/ssh-init.err" 2>/dev/null; then
    auth_hint
  fi
  die "cannot establish SSH connection"
fi

# Show the key we just accepted, from the dedicated known_hosts file, BEFORE
# asking for the secret. Pinning is deliberately not used (accept-new); compare
# this fingerprint with the provider console if one is available.
[ -s "$TMP/known_hosts" ] || die "no target host key recorded"
ssh-keygen -lf "$TMP/known_hosts" 2>/dev/null \
  | awk '{printf "[operator] target host key: %s (%s) — compare with provider console if available\n", $2, $4}' >&2 || true

# Real machines have a controlling /dev/tty; a container exec may only have a
# pty on stdin. Both paths use `read -s` so the passphrase is never echoed.
if (: < /dev/tty) >/dev/null 2>&1; then
  printf 'DR bundle passphrase: ' > /dev/tty
  IFS= read -r -s PASS < /dev/tty || true
  printf '\n' > /dev/tty
else
  printf 'DR bundle passphrase: ' >&2
  IFS= read -r -s PASS || true
  printf '\n' >&2
fi
[ -n "$PASS" ] || die "empty passphrase"

# Cache sudo credentials interactively over the master tty for a non-root login.
SUDO=""
if [ "$LOGIN_USER" != "root" ]; then
  printf '[operator] caching sudo credentials over the SSH tty\n'
  ssh_cmd -tt "$TARGET" "sudo -v" || die "sudo -v failed"
  SUDO="sudo -n"
fi

printf '[operator] uploading the remote phase to the target\n'
ssh_cmd "$TARGET" "$SUDO sh -c 'mkdir -p /root/.dr-bootstrap'" || die "cannot create remote dir"
SELF="$0"
case "$SELF" in /*) ;; *) SELF="$(pwd)/$SELF";; esac
[ -f "$SELF" ] || die "cannot find the downloaded bootstrap.sh to upload"
if [ -n "$SUDO" ]; then
  UPLOAD_CMD="sudo -n sh -c 'cat > /root/.dr-bootstrap/bootstrap.sh && chmod 700 /root/.dr-bootstrap/bootstrap.sh'"
else
  UPLOAD_CMD="sh -c 'cat > /root/.dr-bootstrap/bootstrap.sh && chmod 700 /root/.dr-bootstrap/bootstrap.sh'"
fi
cat "$SELF" | ssh_cmd "$TARGET" "$UPLOAD_CMD" || die "upload failed"

# Real mode asks before running the full production playbook. Rehearsals never
# ask and never run it (it would touch backups/DNS/mail/runners).
if [ "$REHEARSAL" = "false" ]; then
  answer=""
  printf 'Run full servyy.yml for %s on %s? [yes/NO] ' "$SERVER" "$TARGET" >&2
  if [ -t 0 ] && [ -r /dev/tty ]; then
    IFS= read -r answer < /dev/tty || true
  else
    IFS= read -r answer || true
  fi
  case "$answer" in
    yes | YES | Yes) RUN_SERVER=true;;
    *) RUN_SERVER=false; printf '[operator] full servyy.yml not requested; skipped\n' >&2;;
  esac
fi

REMOTE_ARGS="--remote --snapshot $SNAPSHOT --branch $BRANCH --server $SERVER"
if [ "$REHEARSAL" = "true" ]; then
  REMOTE_ARGS="$REMOTE_ARGS --rehearsal"
fi
if [ "$RUN_SERVER" = "true" ]; then
  REMOTE_ARGS="$REMOTE_ARGS --run-server"
fi
if [ "$FRESH" = "true" ]; then
  REMOTE_ARGS="$REMOTE_ARGS --fresh"
fi
if [ -n "$SUDO" ]; then
  RUN_CMD="sudo -n bash /root/.dr-bootstrap/bootstrap.sh $REMOTE_ARGS"
else
  RUN_CMD="bash /root/.dr-bootstrap/bootstrap.sh $REMOTE_ARGS"
fi

reconnect() {
  # sshd can accept TCP before it is ready for authentication after a reboot.
  n=0
  while [ "$n" -lt 20 ]; do
    rm -f "$TMP"/cm-* 2>/dev/null || true
    if ssh_cmd -M -N -f "$TARGET" 2>&1 | tee "$TMP/ssh-reconnect.err" >&2; then
      return 0
    fi
    if grep -q 'Too many authentication failures' "$TMP/ssh-reconnect.err" 2>/dev/null; then
      auth_hint
    fi
    n=$((n + 1))
    sleep 5
  done
  return 1
}

wait_for_ssh() {
  # Pure TCP probe (bash /dev/tcp): no auth, so polling never eats a password
  # prompt and works on macOS bash 3.2 without nc or GNU tools.
  n=0
  while [ "$n" -lt 120 ]; do
    if (: > "/dev/tcp/$HOST/$PORT") >/dev/null 2>&1; then
      return 0
    fi
    n=$((n + 1))
    sleep 3
  done
  return 1
}

printf '[operator] starting remote phase\n'
attempt=1
OK=false
while [ "$attempt" -le 6 ]; do
  printf '[operator] remote attempt %d/6\n' "$attempt"
  # PASS goes only through ssh stdin. printf is a builtin: no argv/env exposure.
  # tee streams the remote run live to the operator while keeping the output
  # for the done/failure checks; the passphrase never appears in this output.
  out="$(printf '%s\n' "$PASS" | ssh_cmd "$TARGET" "$RUN_CMD" 2>&1 | tee /dev/stderr)"
  rc=$?

  case "$out" in
    *DR-REMOTE-DONE*)
      printf '[operator] remote phase completed successfully\n'
      OK=true
      break;;
    *DR-REMOTE-FAILED*)
      # A deterministic remote failure must not be retried: re-running would
      # re-prompt for the password and still fail the same way.
      printf '[operator] remote phase failed deterministically (ssh rc=%d); stopping.\n' "$rc" >&2
      printf '[operator] fix the cause and re-run: the remote phase is idempotent and resumes.\n' >&2
      exit 1;;
  esac

  # Retry ONLY when SSH itself died (exit 255, typically a target reboot).
  if [ "$rc" -ne 255 ]; then
    printf '[operator] remote command exited %d without an SSH drop; stopping.\n' "$rc" >&2
    printf '[operator] fix the cause and re-run: the remote phase is idempotent and resumes.\n' >&2
    exit 1
  fi

  printf '[operator] SSH connection dropped (target rebooted); waiting for SSH to return\n'
  attempt=$((attempt + 1))
  [ "$attempt" -le 6 ] || { printf '[operator] too many reconnects\n' >&2; exit 1; }
  rm -f "$TMP"/cm-* 2>/dev/null || true
  wait_for_ssh || { printf '[operator] target did not come back in time\n' >&2; exit 1; }
  reconnect || { printf '[operator] cannot re-authenticate after reconnect\n' >&2; exit 1; }
  printf '[operator] reconnected; remote phase is idempotent and resumes\n'
done

[ "$OK" = true ] || { printf '[operator] remote phase did not complete\n' >&2; exit 1; }

printf '\n=== DR bootstrap summary ===\n'
printf 'Target: %s@%s (rehearsal=%s)\n' "$LOGIN_USER" "$HOST" "$REHEARSAL"
printf 'The restored Forgejo is listening on the target at localhost:3000.\n'
printf 'To reach it from here: ssh -L 3000:localhost:3000 %s@%s\n' "$LOGIN_USER" "$HOST"
printf 'Backups are NOT configured yet: the restic timers come from servyy.yml (system + restic), which this bootstrap does not run.\n'
printf 'Remaining manual steps: point DNS at the new IP (dns-master / Porkbun), then check the Traefik certificates.\n'
exit 0

