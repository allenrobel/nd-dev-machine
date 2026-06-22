# nd-dev Container Machine

A persistent Ubuntu 24.04 Linux development environment for the
[cisco/nd Ansible collection](https://github.com/CiscoDevNet/ansible-nd),
built on Apple's [container](https://github.com/apple/container) tool.

## What this is

`nd-dev` is an Apple **container machine** — a lightweight VM with a real
init system (systemd), your macOS home directory auto-mounted at the same
path inside Linux, and sub-second restart times. It is not a Docker/Podman
container; it is closer to WSL on Windows.

The goal is to run `ansible-test` (both `--venv` and `--docker default`)
on real Linux while continuing to edit code in your macOS IDE. Because the
collection path is identical inside and outside the machine via virtiofs,
there is no sync step and no path translation.

```
Edit in VS Code on macOS  →  test with 'ndtest' in the machine  →  commit on macOS
```

## Prerequisites

| Requirement | Notes |
|---|---|
| Apple Silicon Mac (M1 or later) | Intel not supported by Apple's container tool |
| macOS 26 (Tahoe) or macOS 27 | Earlier versions have networking limitations |
| [Apple container CLI](https://github.com/apple/container/releases) installed | Download `container-1.0.0-installer-signed.pkg` from the [releases page](https://github.com/apple/container/releases) (scroll to Assets) or use the [direct link](https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg). Works on macOS 26+, no developer version required. |
| Claude Code (`claude`) authenticated | Required for agentic sessions inside the machine |
| ~12 GB free disk space | Ubuntu base + ansible-test Docker images |

## Repository layout

All files live flat in one directory (no subdirectories required):

```
nd-dev-machine/
├── README.md                           ← you are here
├── setup.sh                            ← one-time setup script
├── Dockerfile                          ← Ubuntu 24.04 + systemd + Podman + Claude Code
├── first-boot.sh                       ← user provisioning, runs once on first machine boot
├── nd-dev.sh                           ← shell aliases (ndm, ndtest, ndlint, …)
├── ndm-env.sh                          ← env shim used by nd-dev.sh (auto-created by setup.sh)
├── CLAUDE.md                           ← Claude Code instructions for the ND collection
├── com.apple.container.system.plist    ← LaunchAgent: start container system at login
├── com.user.container.nd-dev.plist     ← LaunchAgent: boot nd-dev machine at login
├── .gitignore                          ← ignores .tmp/ and ndm-env.sh
└── .tmp/                               ← temp scripts (gitignored, auto-created at runtime)
```

## Setup

Clone or copy this directory to your Mac, then:

```bash
cd ~/nd-dev-machine
bash setup.sh
```

`setup.sh` is idempotent — safe to re-run. It will:

1. Start the container system service
2. Build the `local/nd-dev:latest` image (~5 min first run, cached after)
3. Create the `nd-dev` container machine (6 CPU, 8 GB RAM)
4. Verify the home mount and `ansible-test` are working
5. Install LaunchAgents for auto-start at login
6. Wire shell aliases into `~/.zshrc` / `~/.bashrc`
7. Install `CLAUDE.md` into the ND collection root

After setup, reload your shell:

```bash
source ~/.zshrc
```

## Daily usage

```bash
# Drop into an interactive Linux shell inside the machine
# (your prompt changes to <username>@nd-dev; type 'exit' to return to macOS)
ndm

# Run all sanity checks (--venv, recommended for local dev)
ndtest

# Run a specific sanity test
ndtest --test validate-modules

# Target a specific file
ndtest --test validate-modules plugins/modules/nd_my_module.py

# Run with the full Docker container (matches CI exactly)
ndtest-docker --test validate-modules

# Linting and type checking
ndlint plugins/
ndmypy plugins/modules/
ndpylint plugins/modules/nd_my_module.py

# Check machine status and LaunchAgent boot logs
ndstatus
ndlogs
```

All commands run inside the machine against your macOS collection path.
You never need to copy files or change directories differently from how
you work today.

## Claude Code

Run Claude Code from macOS for most work:

```bash
cd ~/ansible_collections/cisco/nd
claude
```

Claude Code on macOS edits files natively (no virtiofs overhead) and
delegates test/lint execution into the machine via the `ndtest` /
`ndlint` wrappers defined in `CLAUDE.md`.

For long agentic sessions where Claude is running tests, inspecting
failures, and patching code in a tight loop, run Claude Code from
inside the machine instead.

**NOTES**

- Currently you need to define HOME before running `claude`.
- If you need to connect to Apple's Xcode mcpbridge, this won't work within
  the machine since it uses xcrun which isn't available on Ubuntu.

```bash
ndm   # drops you into the machine
HOME=/Users/<your-macos-username>; claude
```

Claude Code credentials are stored in `~/.claude/` on your macOS home,
which is auto-mounted inside the machine — no re-authentication needed,
but remember to define HOME first!

## pyproject.toml configuration

The ND collection's `pyproject.toml` must use `ansible-core` (not the
`ansible` community metapackage) and a Python version compatible with
the ansible-core series you are targeting:

```toml
[project]
# requires-python governs the controller/dev toolchain Python.
# ansible-core 2.18 requires >=3.11. The collection supports Python
# >=3.10 as a *target* — enforced via ansible-test matrix in CI.
requires-python = ">=3.11"

dependencies = [
    # Pin to match CI (see .github/workflows/ansible-test.yml)
    "ansible-core>=2.18,<2.19",
    ...
]
```

Create and activate the venv inside the machine. Because your macOS `$HOME`
and the Linux machine share the collection tree via virtiofs, the venv path
is suffixed by platform/arch so the macOS and Linux venvs never collide
(a venv's `bin/python` and compiled `.so` files are platform-specific):

```bash
ndm
cd ~/ansible_collections/cisco/nd
VENV=".venv-$(uname -s)-$(uname -m)"          # e.g. .venv-Linux-aarch64 here
uv venv --python 3.12 "$VENV" --prompt ansible-nd --clear
source "$VENV/bin/activate"
UV_PROJECT_ENVIRONMENT="$VENV" uv sync
```

`UV_PROJECT_ENVIRONMENT` is set for you inside the machine, so `uv` targets the
right per-platform venv without the inline prefix — two mechanisms cover the
two shell types:

- **Interactive `ndm` sessions** (a non-login interactive bash) read it from
  `/etc/bash.bashrc`, which `first-boot.sh` patches.
- **Non-interactive `nd*` wrappers** (`ndm uv sync`, `ndmypy`, …) run a script
  directly rather than a login/interactive shell, so `nd-dev.sh` exports the
  var into that script itself.

(`/etc/profile.d` is *not* used: the interactive session is not a login shell,
so it never sources `/etc/profile`.)

If you want editor/LSP support on **macOS** (Pylance, ansible-lint in VS Code),
create the host counterpart and point your editor at it explicitly — do not
symlink `.venv`, or the machine would follow it and get the macOS binaries:

```bash
# On macOS, from the collection root:
uv venv --python 3.12 ".venv-$(uname -s)-$(uname -m)" --prompt ansible-nd   # .venv-Darwin-arm64
```

```jsonc
// .vscode/settings.json
"python.defaultInterpreterPath": "${workspaceFolder}/.venv-Darwin-arm64/bin/python"
```

Both `.venv` and `.venv-*/` are gitignored, which also keeps `ansible-test`
from scanning them (it enumerates files via git).

## How it works (architecture notes)

### virtiofs home mount

Your macOS `$HOME` is mounted read-write inside the machine at the same
path (e.g. `/Users/<your-macos-username>`). This is a virtiofs share managed by the
Apple Virtualization framework — edits on either side are immediately
visible on the other. No rsync, no Docker volume, no path difference.

### Podman inside the machine

`ansible-test --docker` runs Podman *inside* the container machine to
pull and run the ansible-test containers. Four configuration changes are
required for this to work in the Apple VM environment, all applied
automatically by `first-boot.sh`:

| Setting | Why |
|---|---|
| `pasta` rootless network backend | `slirp4netns` requires a D-Bus user session that isn't available early in boot; `pasta` avoids this |
| `cgroupfs` cgroup manager | The VM doesn't expose a systemd user session for cgroup v2 management |
| `seccomp=unconfined` | The ansible-test controller runs systemd as PID 1, which requires syscalls blocked by the default seccomp profile |
| `loginctl enable-linger` | Creates a persistent systemd user session with D-Bus, required for Podman to place the rootless netns process into `user-UID.slice` |

### `/dev/net/tun` permissions

The Apple VM exposes `/dev/net/tun` as `root:root 0600`. Both `pasta`
and `slirp4netns` need to open it for rootless networking. `first-boot.sh`
sets it to `0666` and writes a udev rule to make this persistent across
container restarts.

### Auto-start at login

Two LaunchAgents handle startup sequencing:

1. `com.apple.container.system.plist` — starts `container-apiserver`
2. `com.user.container.nd-dev.plist` — waits 15 seconds, then boots the machine

The 15-second delay is intentional: `container-apiserver` needs time to
fully initialize before a machine boot attempt. You can tune this down
in the plist once you've confirmed it's reliably working on your hardware.

Boot logs are written to `/tmp/container-system.log` and
`/tmp/container-nd-dev-boot.log` — check these with `ndlogs` if the
machine doesn't come up after login.

## Rebuilding the machine

If you need to rebuild from scratch (e.g. after updating `Dockerfile`
or `first-boot.sh`):

```bash
# Stop and remove the existing machine
container machine stop nd-dev
container machine rm nd-dev

# Rebuild the image (uses layer cache — only changed layers rebuild)
cd ~/nd-dev-machine
container build -t local/nd-dev:latest .

# Re-run setup from STEP 3 onward
bash setup.sh
```

Your collection files, venv, and dotfiles are untouched — they live on
the virtiofs-mounted macOS home, not inside the machine.

## Troubleshooting

**`setup.sh` STEP 3 fails with "hostname(s) already exist"**

This happens after `container machine rm` — the runtime doesn't always clean
up its internal DNS/hostname records. Fix by restarting the container system
to flush stale state:

```bash
container system stop
container system start
bash setup.sh
```

If that doesn't work, reset the runtime state entirely (images are cached so
the subsequent build will be fast):

```bash
container system stop
rm -rf ~/Library/Application\ Support/container
container system start
bash setup.sh
```

**Machine doesn't start at login**

```bash
ndlogs   # check /tmp/container-nd-dev-boot.err
# If the 15s delay isn't enough, edit the plist:
# ~/Library/LaunchAgents/com.user.container.nd-dev.plist
# Increase the sleep value and reload:
launchctl bootout gui/$(id -u)/com.user.container.nd-dev
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.container.nd-dev.plist
```

**`ansible-test --docker default` fails with "dbus" or "user session" errors**

```bash
# Re-enable user lingering inside the machine
ndm sudo loginctl enable-linger $(whoami)
```

**`ansible-test --docker default` fails with "insufficient UIDs/GIDs"**

```bash
# Check subuid/subgid inside the machine
ndm cat /etc/subuid /etc/subgid
# Should show: <your-macos-username>:100000:65536 (not ubuntu:...)
# If wrong, fix and migrate:
ndm sudo sed -i "s/^ubuntu:/$(whoami):/" /etc/subuid /etc/subgid
ndm podman system migrate
```

**`/dev/net/tun: Permission denied`**

```bash
ndm sudo chmod 0666 /dev/net/tun
```

**`uv sync` fails with Python version conflicts**

Ensure `requires-python` in `pyproject.toml` is `>=3.11` (not `>=3.10`)
and the dependency is `ansible-core>=2.18,<2.19` (not the `ansible`
community metapackage). See [pyproject.toml configuration](#pyprojecttoml-configuration) above.

## Resource usage

Default allocation is 6 vCPU / 8 GB RAM, tuned for M4 MacBook Air.
Adjust with:

```bash
container machine stop nd-dev
container machine set -n nd-dev cpus=4 memory=6G
container machine run -n nd-dev
```