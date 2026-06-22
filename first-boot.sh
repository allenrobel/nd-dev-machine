#!/bin/sh
# /etc/machine/create-user.sh
#
# Called ONCE on first boot by the container machine runtime (as root).
# Environment variables provided by the runtime:
#   CONTAINER_USER        — matches your macOS username
#   CONTAINER_UID         — matches your macOS uid
#   CONTAINER_GID         — matches your macOS gid
#   CONTAINER_HOME        — e.g. /Users/<your-macos-username> (virtiofs-mounted from macOS $HOME)
#   CONTAINER_MACHINE_ID
#
# IMPORTANT: This script completely replaces Apple's built-in user creation.
# We must successfully create the user or the machine create command fails.
# Using /bin/sh (not bash) for maximum portability inside the VM.

set -e

echo "[create-user] CONTAINER_USER=${CONTAINER_USER} UID=${CONTAINER_UID} GID=${CONTAINER_GID}"
echo "[create-user] CONTAINER_HOME=${CONTAINER_HOME}"

# ── Group ──────────────────────────────────────────────────────────────────────
# ubuntu:24.04 ships with a pre-existing 'ubuntu' group (gid=1000).
# Rename it if our GID matches, otherwise create fresh.
if getent group "${CONTAINER_GID}" > /dev/null 2>&1; then
    existing_group=$(getent group "${CONTAINER_GID}" | cut -d: -f1)
    if [ "${existing_group}" != "${CONTAINER_USER}" ]; then
        echo "[create-user] Renaming group '${existing_group}' -> '${CONTAINER_USER}'"
        groupmod -n "${CONTAINER_USER}" "${existing_group}"
    fi
else
    echo "[create-user] Creating group '${CONTAINER_USER}' gid=${CONTAINER_GID}"
    groupadd --gid "${CONTAINER_GID}" "${CONTAINER_USER}"
fi

# ── User ───────────────────────────────────────────────────────────────────────
# ubuntu:24.04 ships with uid=1000 'ubuntu'. Rename if needed.
if getent passwd "${CONTAINER_UID}" > /dev/null 2>&1; then
    existing_user=$(getent passwd "${CONTAINER_UID}" | cut -d: -f1)
    if [ "${existing_user}" != "${CONTAINER_USER}" ]; then
        echo "[create-user] Renaming user '${existing_user}' -> '${CONTAINER_USER}'"
        usermod \
            -l "${CONTAINER_USER}" \
            -d "${CONTAINER_HOME}" \
            -g "${CONTAINER_GID}" \
            "${existing_user}"
    fi
else
    echo "[create-user] Creating user '${CONTAINER_USER}' uid=${CONTAINER_UID}"
    useradd \
        --uid "${CONTAINER_UID}" \
        --gid "${CONTAINER_GID}" \
        --home-dir "${CONTAINER_HOME}" \
        --no-create-home \
        --shell /bin/bash \
        "${CONTAINER_USER}"
fi

usermod --shell /bin/bash "${CONTAINER_USER}"
usermod -aG sudo "${CONTAINER_USER}" || true

echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" \
    > "/etc/sudoers.d/${CONTAINER_USER}"
chmod 440 "/etc/sudoers.d/${CONTAINER_USER}"

# ── /dev/net/tun permissions ───────────────────────────────────────────────────
# The Apple container machine VM exposes /dev/net/tun owned by root:root 0600.
# Both slirp4netns and pasta need world-readable access for rootless networking.
# We make this permanent via a udev rule so it survives container restarts.
echo "[create-user] Fixing /dev/net/tun permissions..."
chmod 0666 /dev/net/tun 2>/dev/null || true
mkdir -p /etc/udev/rules.d
echo 'KERNEL=="tun", MODE="0666"' > /etc/udev/rules.d/99-tun.rules
echo "[create-user] udev rule written: /etc/udev/rules.d/99-tun.rules"

# ── Subordinate UID/GID mappings (required for Podman rootless) ───────────────
# ubuntu:24.04 ships with subuid/subgid entries for 'ubuntu'. After rename,
# those entries still reference 'ubuntu', causing Podman to fail with
# "insufficient UIDs or GIDs available in user namespace" when pulling images
# that contain files owned by non-root UIDs (e.g. /etc/shadow at 0:42).
echo "[create-user] Configuring subuid/subgid for Podman rootless..."

fix_subfile() {
    SUBFILE="$1"
    sed -i "/^${CONTAINER_USER}:/d" "${SUBFILE}"
    if [ "${CONTAINER_USER}" != "ubuntu" ]; then
        sed -i '/^ubuntu:/d' "${SUBFILE}"
    fi
    echo "${CONTAINER_USER}:100000:65536" >> "${SUBFILE}"
    echo "[create-user] ${SUBFILE}: set ${CONTAINER_USER}:100000:65536"
}

fix_subfile /etc/subuid
fix_subfile /etc/subgid

# ── Podman rootless configuration ─────────────────────────────────────────────
# Four settings are required for ansible-test --docker to work inside the
# Apple container machine VM:
#
#   pasta           — rootless network backend; avoids slirp4netns fallback
#                     which tries to move netns into systemd user.slice via
#                     D-Bus before the session is available
#   cgroupfs        — explicit cgroup manager; prevents repeated "no systemd
#                     user session" warnings and failed systemd cgroup setup
#   seccomp=        — the default-test-container runs /sbin/init (systemd)
#   unconfined        as PID 1, which requires syscalls blocked by the default
#                     seccomp profile (pivot_root, unshare, etc.)
#
# Written to the virtiofs-mounted macOS home so it survives image rebuilds.
echo "[create-user] Writing Podman containers.conf..."
CONTAINERS_CONF="${CONTAINER_HOME}/.config/containers/containers.conf"
mkdir -p "${CONTAINER_HOME}/.config/containers"

# Only write if not already present (guard for re-runs)
if ! grep -q 'nd-dev container machine' "${CONTAINERS_CONF}" 2>/dev/null; then
    cat > "${CONTAINERS_CONF}" << EOF
# Written by nd-dev container machine first-boot provisioning
# Required for ansible-test --docker default inside Apple container machine VM

[network]
default_rootless_network_cmd = "pasta"

[engine]
cgroup_manager = "cgroupfs"

[containers]
seccomp_profile = "unconfined"
EOF
    chown "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINERS_CONF}"
    echo "[create-user] Written: ${CONTAINERS_CONF}"
else
    echo "[create-user] ${CONTAINERS_CONF} already configured — skipping"
fi

# ── Podman system migrate + user linger ───────────────────────────────────────
# migrate: flushes Podman's storage state to pick up new subuid/subgid mappings
# enable-linger: creates a persistent systemd user session with D-Bus, required
#   for Podman to move the rootless netns process into user-UID.slice. Without
#   this, --docker default fails with "dbus: couldn't determine address of
#   session bus" even with pasta configured.
echo "[create-user] Running podman system migrate..."
su - "${CONTAINER_USER}" -c "podman system migrate" \
    || echo "[create-user] WARNING: podman system migrate failed — run manually"

echo "[create-user] Enabling user linger for ${CONTAINER_USER}..."
loginctl enable-linger "${CONTAINER_USER}" \
    || echo "[create-user] WARNING: loginctl enable-linger failed — run manually: sudo loginctl enable-linger ${CONTAINER_USER}"

echo "[create-user] User '${CONTAINER_USER}' ready."

# ── Per-user Python toolchain ──────────────────────────────────────────────────
# Ubuntu 24.04 enforces PEP 668 — pip install --user is blocked outside a venv.
# Strategy:
#   pipx  — manages isolated venvs for standalone CLI tools (pytest, pylint, etc.)
#           Installs binaries to ~/.local/bin, which is on PATH.
#   apt   — installs pipx itself (cleanest approach on Ubuntu 24.04)
# Everything lands in ~/.local on the virtiofs-mounted macOS home, so it
# survives image rebuilds without re-provisioning.
echo "[create-user] Installing pipx..."
apt-get install -y pipx > /dev/null 2>&1     || echo "[create-user] WARNING: pipx apt install failed"

echo "[create-user] Installing Python CLI tools via pipx..."
# Run pipx as the target user but with HOME explicitly set to CONTAINER_HOME
# (the virtiofs-mounted macOS home). We cannot rely on 'su -' to set the
# correct HOME because /etc/passwd may still reflect the pre-rename path
# (/home/<user>) at the point this runs. Explicit HOME ensures pipx venvs
# and binaries land in /Users/<user>/.local, which persists across rebuilds.
su - "${CONTAINER_USER}" -c "
    export HOME='${CONTAINER_HOME}'
    export PATH='${CONTAINER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    pipx install ansible-lint &&
    pipx install pylint &&
    pipx inject pylint pydantic &&
    pipx install mypy &&
    pipx inject mypy pydantic &&
    pipx install pytest &&
    pipx inject pytest pytest-ansible &&
    echo '[create-user] pipx installs complete'
" || echo "[create-user] WARNING: pipx installs failed — run manually inside the machine:
    sudo apt install -y pipx
    export HOME=/Users/\$(whoami)
    pipx install ansible-lint
    pipx install pylint && pipx inject pylint pydantic
    pipx install mypy && pipx inject mypy pydantic
    pipx install pytest && pipx inject pytest pytest-ansible"

# ── Shell environment additions ────────────────────────────────────────────────
MARKER="# --- nd-dev container machine ---"

patch_rc() {
    RC="$1"
    [ -f "$RC" ] || return 0
    grep -qF "$MARKER" "$RC" && return 0
    cat >> "$RC" << EOF

${MARKER}
export ANSIBLE_TEST_PREFER_PODMAN=1
export PATH="\$HOME/.local/bin:\$PATH"
# Per-platform uv venv: the macOS host and this Linux machine share the
# collection tree via virtiofs, so one .venv path can't serve both (bin/python
# and compiled .so files are platform-specific). \$(uname ...) is evaluated at
# shell startup inside the machine -> e.g. .venv-Linux-aarch64. uv resolves a
# relative UV_PROJECT_ENVIRONMENT per project root, so this is safe for any uv
# project in the machine.
export UV_PROJECT_ENVIRONMENT=".venv-\$(uname -s)-\$(uname -m)"
# ---------------------------------
EOF
    echo "[create-user] Patched ${RC}"
}

# ${CONTAINER_HOME}/.bashrc usually does NOT exist (the macOS home has no bash
# rc), so that patch is typically a no-op. The interactive `ndm` session is a
# non-login interactive bash — the runtime does NOT start a login shell, so
# /etc/profile and /etc/profile.d/*.sh are never sourced there. /etc/bash.bashrc
# IS read by interactive bash (login and non-login), so patching it is what
# actually gets these vars into interactive `ndm` shells.
patch_rc "${CONTAINER_HOME}/.bashrc"
patch_rc "${CONTAINER_HOME}/.zshrc"
patch_rc /etc/bash.bashrc

echo "[create-user] Done."
