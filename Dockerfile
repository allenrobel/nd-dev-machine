FROM ubuntu:24.04

# Consumed by systemd-inside-container and our first-boot script
ENV container=container
ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update && \
    # Apply latest security patches to base-image packages at build time so a
    # stale base snapshot can't leave known-vulnerable packages in the image.
    apt-get upgrade -y && \
    apt-get install -y \
        # systemd + minimal OS services
        dbus systemd openssh-server net-tools iproute2 \
        iputils-ping curl wget sudo \
        # udev — required so the 99-tun.rules udev rule written by first-boot
        # takes effect on container restarts (makes /dev/net/tun world-readable
        # persistently, needed for rootless Podman networking via pasta)
        udev \
        # Python toolchain
        python3 python3-pip python3-venv \
        # git (collection dev + ansible-test needs it)
        git \
        # Node.js + npm (required for Claude Code install via npm)
        nodejs npm \
        # Podman + rootless prerequisites
        # Note: pasta is pulled in automatically as a podman dependency
        podman uidmap slirp4netns && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Restore man pages etc. stripped from the minimal Ubuntu image
    yes | unminimize

# ── systemd housekeeping (required for container machine init) ─────────────────
RUN >/etc/machine-id && \
    >/var/lib/dbus/machine-id && \
    systemctl set-default multi-user.target && \
    systemctl mask \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount \
        systemd-update-utmp.service \
        systemd-tmpfiles-setup.service \
        console-getty.service && \
    systemctl disable networkd-dispatcher.service && \
    # Suppress locale forwarding warnings from SSH
    sed -i 's/^AcceptEnv LANG LC_\*$/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config

# ── ansible-core (system-wide so it's available before user bootstrap) ─────────
# --break-system-packages is required on Ubuntu 24.04 (PEP 668)
RUN pip3 install --break-system-packages ansible-core

# ── Claude Code + markdownlint (system-wide via npm) ──────────────────────────
# The native installer (claude.ai/install.sh) requires bash, but Dockerfile RUN
# uses /bin/sh (dash on Ubuntu), causing a syntax error. npm install is
# Anthropic's recommended approach for Dockerfiles and works in any POSIX shell.
# Running as root here — no sudo needed, do NOT prefix with sudo.
#
# markdownlint-cli is baked into the image (not first-boot.sh) because the
# machine's outbound network can silently go stale (see README
# "Troubleshooting") — the image build happens on macOS where the registry
# is reachable. The collection's CLAUDE.md documents
# `ndm markdownlint <file>.md`, which needs this binary on PATH.
#
# Pinned at 0.44.0: Ubuntu 24.04's apt nodejs is 18.x, and markdownlint-cli
# >=0.45.0 requires Node >=20 (npm only WARNS on the engine mismatch, then the
# tool can fail at runtime). Keep this pin in sync with MDL_PIN in nddoctor.sh;
# bump both together if the image ever moves to a newer Node.
RUN npm install -g @anthropic-ai/claude-code markdownlint-cli@0.44.0

# ── First-boot user bootstrap ──────────────────────────────────────────────────
# Called ONCE on first boot by the container machine runtime (as root), with
# CONTAINER_USER / CONTAINER_UID / CONTAINER_GID / CONTAINER_HOME set to match
# the host macOS account. Handles user creation, Podman rootless configuration,
# and dev toolchain installation.
COPY first-boot.sh /etc/machine/create-user.sh
RUN chmod +x /etc/machine/create-user.sh
