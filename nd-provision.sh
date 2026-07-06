#!/bin/bash
# nd-provision.sh — in-machine provisioning that needs the virtiofs home mount.
#
# Run as root INSIDE the nd-dev machine. setup.sh invokes it after machine
# create via:
#   container machine run -n nd-dev --root -- <repo>/nd-provision.sh <user> <home>
#
# Why this is not part of first-boot.sh: the machine runtime executes the
# first-boot script BEFORE mounting the macOS home (verified empirically —
# writes to ${CONTAINER_HOME} during first boot land on a root-owned local
# stub directory that the virtiofs mount then shadows). Everything here
# reads or writes the real macOS home, so it must run in a normal machine
# session, where the mount is guaranteed up.
#
# Idempotent — safe to re-run any time:
#   ndm sudo ~/nd-dev-machine/nd-provision.sh "$(whoami)" "$HOME"
set -euo pipefail

ND_USER="${1:?usage: nd-provision.sh <user> <home>}"
ND_HOME="${2:?usage: nd-provision.sh <user> <home>}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ND_PATH="${ND_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() { echo "[nd-provision] $*"; }

# Sanity: refuse to run against the shadowed local stub — everything below
# would silently land in the wrong place.
if ! grep -qs " ${ND_HOME} " /proc/mounts; then
    log "ERROR: ${ND_HOME} is not a mounted virtiofs home — aborting."
    log "Run this via 'container machine run' / ndm, not from first boot."
    exit 1
fi

ND_UID="$(id -u "${ND_USER}")"
ND_GID="$(id -g "${ND_USER}")"

# ── Guest DNS override (managed-host workaround) ───────────────────────────────
# setup.sh records ND_GUEST_DNS in ~/.config/nd-dev/guest-dns; apply it here
# so the apt/pipx steps below work on hosts whose vmnet NAT DNS proxy is
# blocked (see README "Troubleshooting"). The nd-dns-override path/timer
# units keep it applied across boots.
DNS_CONF="${ND_HOME}/.config/nd-dev/guest-dns"
if [ -f "${DNS_CONF}" ]; then
    GUEST_DNS="$(cat "${DNS_CONF}")"
    log "Applying guest DNS override: ${GUEST_DNS}"
    mkdir -p /etc/nd-dev
    printf 'nameserver %s\n' "${GUEST_DNS}" > /etc/nd-dev/dns-override
    # Machines created from a pre-nd-dns-override image lack the units —
    # install them from the repo dir so the override survives reboots.
    if [ ! -f /etc/systemd/system/nd-dns-override.timer ]; then
        cp "${REPO_DIR}/nd-dns-override.service" \
           "${REPO_DIR}/nd-dns-override.path" \
           "${REPO_DIR}/nd-dns-override.timer" /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable nd-dns-override.service nd-dns-override.path \
            nd-dns-override.timer
    fi
    # Units were enabled but not started if the override file didn't exist
    # at boot (ConditionPathExists) — start them now that it does.
    systemctl start nd-dns-override.path nd-dns-override.timer
    rm -f /etc/resolv.conf
    cp /etc/nd-dev/dns-override /etc/resolv.conf
    log "Guest DNS override active"
fi

# ── Podman containers.conf ─────────────────────────────────────────────────────
# Four settings required for ansible-test --docker inside the machine:
#   pasta            — rootless network backend; avoids slirp4netns fallback
#                      which tries to move netns into systemd user.slice via
#                      D-Bus before the session is available
#   cgroupfs         — explicit cgroup manager; prevents "no systemd user
#                      session" warnings and failed systemd cgroup setup
#   seccomp=         — the default-test-container runs /sbin/init (systemd)
#   unconfined         as PID 1, which needs syscalls blocked by the default
#                      seccomp profile (pivot_root, unshare, etc.)
# Written to the virtiofs-mounted macOS home so it survives image rebuilds.
CONTAINERS_CONF="${ND_HOME}/.config/containers/containers.conf"
if ! grep -q 'nd-dev container machine' "${CONTAINERS_CONF}" 2>/dev/null; then
    log "Writing ${CONTAINERS_CONF}..."
    mkdir -p "${ND_HOME}/.config/containers"
    cat > "${CONTAINERS_CONF}" << EOF
# Written by nd-dev container machine provisioning (nd-provision.sh)
# Required for ansible-test --docker default inside Apple container machine VM

[network]
default_rootless_network_cmd = "pasta"

[engine]
cgroup_manager = "cgroupfs"

[containers]
seccomp_profile = "unconfined"
EOF
    chown "${ND_UID}:${ND_GID}" "${CONTAINERS_CONF}"
else
    log "${CONTAINERS_CONF} already configured — skipping"
fi

# ── podman system migrate ──────────────────────────────────────────────────────
# Flushes Podman's storage state so it picks up the subuid/subgid mappings
# written by first-boot.sh. Needs the real home (storage under ~/.local).
log "Running podman system migrate..."
su - "${ND_USER}" -c "export HOME='${ND_HOME}'; podman system migrate" \
    || log "WARNING: podman system migrate failed — run manually: ndm podman system migrate"

# ── pipx + Python CLI toolchain ────────────────────────────────────────────────
# pipx manages isolated venvs for the CLI tools (installed under ~/.local on
# the virtiofs home, so they survive machine rebuilds). pydantic must be
# injected into every venv that imports the collection's code — each pipx
# venv is isolated, so a system/user pydantic is NOT visible inside them.
# Version floor matches the collection's requirements.txt pin (the old <2.12
# cap for issue #344 was dropped after CiscoDevNet/ansible-nd#377).
PYDANTIC_PIN='pydantic>=2.12.5'
# black / isort — the collection's pre-commit formatters (issue #23). Unlike the
# pydantic tools they do NOT import the collection, so they need no inject. They
# ARE exact-pinned (not floored) to the versions the collection's uv.lock
# resolves, so the machine formats code identically to the editor venv
# (.venv-Darwin-arm64) and CI — formatter output drifts across releases. Keep
# these in sync with nddoctor.sh (BLACK_PIN/ISORT_PIN) and the collection's
# uv.lock; nddoctor.sh enforces the exact version and heals any drift.
BLACK_PIN='black==26.5.1'
ISORT_PIN='isort==8.0.1'

if ! command -v pipx > /dev/null 2>&1; then
    log "Installing pipx via apt..."
    apt-get install -y pipx > /dev/null 2>&1 || log "WARNING: pipx apt install failed"
fi

# Run pipx as the target user with HOME pinned to the real macOS home (su -
# alone may resolve a stale /etc/passwd path). Each install is guarded so
# re-runs are fast; injects are cheap and re-run unconditionally.
log "Installing Python CLI tools via pipx..."
su - "${ND_USER}" -c "
    export HOME='${ND_HOME}'
    export PATH='${ND_PATH}'
    have() { pipx list --short 2>/dev/null | grep -q \"^\$1 \"; }
    have ansible-lint || pipx install ansible-lint
    have pylint       || pipx install pylint
    pipx inject pylint '${PYDANTIC_PIN}'
    have mypy         || pipx install mypy
    pipx inject mypy '${PYDANTIC_PIN}'
    have pytest       || pipx install pytest
    pipx inject pytest pytest-ansible '${PYDANTIC_PIN}'
    have black        || pipx install '${BLACK_PIN}'
    have isort        || pipx install '${ISORT_PIN}'
" || log "WARNING: pipx installs failed — re-run: ndm sudo ${REPO_DIR}/nd-provision.sh ${ND_USER} ${ND_HOME}"

# ── Shell environment additions (home-side rc files) ──────────────────────────
# /etc/bash.bashrc is patched by first-boot.sh (rootfs); the home rc files
# live on the virtiofs mount, so they are handled here.
MARKER="# --- nd-dev container machine ---"
patch_rc() {
    RC="$1"
    [ -f "$RC" ] || return 0
    grep -qF "$MARKER" "$RC" && return 0
    cat >> "$RC" << EOF

${MARKER}
export ANSIBLE_TEST_PREFER_PODMAN=1
export PATH="\$HOME/.local/bin:\$PATH"
# Per-platform uv venv — see /etc/bash.bashrc block for rationale.
export UV_PROJECT_ENVIRONMENT=".venv-\$(uname -s)-\$(uname -m)"
# ---------------------------------
EOF
    log "Patched ${RC}"
}
patch_rc "${ND_HOME}/.bashrc"
patch_rc "${ND_HOME}/.zshrc"

log "Done."
