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

```text
Edit in VS Code on macOS  →  test with 'ndtest' in the machine  →  commit on macOS
```

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Apple Silicon Mac (M1 or later) | Intel not supported by Apple's container tool |
| macOS 26 (Tahoe) or macOS 27 | Earlier versions have networking limitations |
| [Apple container CLI](https://github.com/apple/container/releases) installed | Download `container-1.0.0-installer-signed.pkg` from the [releases page](https://github.com/apple/container/releases) (scroll to Assets) or use the [direct link](https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg). Works on macOS 26+, no developer version required. |
| Claude Code (`claude`) authenticated | Required for agentic sessions inside the machine |
| ~12 GB free disk space | Ubuntu base + ansible-test Docker images |

## Repository layout

All files live flat in one directory (no subdirectories required):

```bash
nd-dev-machine/
├── README.md                           ← you are here
├── setup.sh                            ← one-time setup script
├── Dockerfile                          ← Ubuntu 24.04 + systemd + Podman + Claude Code + markdownlint
├── first-boot.sh                       ← rootfs-only setup, runs once on first machine boot
├── nd-provision.sh                     ← home-side provisioning, run by setup.sh
├── nddoctor.sh                         ← verify/self-heal the dev tools (pipx venvs, black/isort, markdownlint)
├── nd-dev.sh                           ← shell aliases (ndm, ndtest, ndlint, nddoctor, …)
├── nd-dns-override.service             ← guest unit: apply DNS override
├── nd-dns-override.path                ← guest watcher: re-apply on rewrite
├── nd-dns-override.timer               ← guest boot sweep for the override
├── ndm-env.sh                          ← env shim used by nd-dev.sh (auto-created by setup.sh)
├── CLAUDE.md                           ← Claude Code instructions for the ND collection
├── com.apple.container.system.plist    ← LaunchAgent: start container system at login
├── com.user.container.nd-dev.plist     ← LaunchAgent: boot nd-dev machine at login
├── .gitignore                          ← ignores .tmp/ and ndm-env.sh
└── .tmp/                               ← temp scripts (gitignored, auto-created at runtime)
```

## Setup

### Install Apple's container machine framework

See Prerequisites above

### Clone or copy this directory to your Mac

```bash
cd $HOME
git clone https://github.com/allenrobel/nd-dev-machine.git
cd $HOME/nd-dev-machine
bash setup.sh
```

`setup.sh` is idempotent — safe to re-run. It will:

1. Start the container system service
2. Build the `local/nd-dev:latest` image (~5 min first run, cached after)
3. Create the `nd-dev` container machine (6 CPU, 8 GB RAM)
4. Verify the home mount and `ansible-test` are working
5. Install LaunchAgents for auto-start at login
6. Wire shell aliases into `~/.zshrc` / `~/.bashrc`
7. Install `CLAUDE.md` into the ND collection root (skipped if `CLAUDE.md` already exists in the ND collection root)
8. Provision the macOS editor venv (`.venv-Darwin-arm64`) with the collection's deps via `uv sync`, so VS Code / Pylance resolves third-party imports (editor IntelliSense only — see [pyproject.toml configuration](#pyprojecttoml-configuration))
9. Add `.ansible/`, `collections/`, and the per-platform uv venvs (`.venv`, `.venv-*/`) to your global git ignore (see [Git: ignoring machine-generated artifacts](#git-ignoring-machine-generated-artifacts))

After setup, reload your shell:

```bash
source ~/.zshrc
```

### Git: ignoring machine-generated artifacts

Working the collection on this machine leaves a few regenerable, per-developer
trees that are untracked and deliberately **not** in the collection's tracked
`.gitignore`:

- **`collections/`** — pytest-ansible's collection symlink farm, created by
  `ndpytest` (the wrapper now passes `--ansible-unit-inject-only`, which avoids
  it; the ignore entry is a safety net).
- **`.ansible/`** — ansible-lint's galaxy/cache tree. ansible-lint hardcodes
  `Runtime(isolated=True)`, so it always writes `<project>/.ansible` regardless
  of `ANSIBLE_HOME` — there is no wrapper/env knob to relocate it.
- **`.venv`, `.venv-*/`** — per-platform uv venvs, suffixed by `uname` (e.g.
  `.venv-Darwin-arm64`, `.venv-Linux-aarch64`) so the macOS host and the Linux
  machine never collide on the shared virtiofs tree.

Left un-ignored, `collections/` and `.ansible/` block `git rebase` (the "move
aside the untracked symlink loop" dance). STEP 9 of `setup.sh` adds all of these
to your **global** git ignore (`core.excludesfile`, or git's XDG default
`~/.config/git/ignore`) — idempotently, so re-runs are safe. This keeps each
collection's own tracked `.gitignore` aligned with the team's. To do it by hand:

```bash
printf '%s\n' '.ansible/' 'collections/' '.venv' '.venv-*/' >> ~/.config/git/ignore
```

The directory patterns only ignore *untracked* dirs of those names; a repo that
tracks one is unaffected.

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

# Run with the full Docker container (closest to CI — see
# "Local testing vs GitHub CI" below)
ndtest-docker --test validate-modules

# Linting and type checking
ndlint plugins/
ndmypy plugins/modules/
ndpylint plugins/modules/nd_my_module.py
ndm markdownlint README.md

# Verify / self-heal the dev tools (pinned pydantic in pytest/pylint/mypy,
# markdownlint on PATH)
nddoctor

# Check machine status and LaunchAgent boot logs
ndstatus
ndlogs
```

All commands run inside the machine against your macOS collection path.
You never need to copy files or change directories differently from how
you work today.

## Local testing vs GitHub CI

`ndtest` does **not** read the collection's
`.github/workflows/ansible-test.yml` — that file only configures GitHub
Actions. Locally, `ndtest` simply runs `ansible-test sanity --venv`
inside the machine, and `ansible-test` decides on its own which rules
and Python versions to exercise. The result is close to CI, but not
identical. Three gaps to be aware of:

1. **Interpreter coverage.** The machine ships only Ubuntu 24.04's
   Python 3.12. With `--venv`, per-interpreter sanity tests (`compile`,
   `import`) run only on interpreters actually installed, so `ndtest`
   emits warnings like:

   ```text
   WARNING: Skipping sanity test "compile" on Python 3.13 ...
   WARNING: Skipping sanity test "compile" on Python 3.14 ...
   ```

   CI runs `ansible-test sanity --docker`, whose test container ships
   every supported interpreter, so those tests run on all versions
   there. `ndtest-docker` uses the same container and closes this gap
   completely.

2. **ansible-core version.** The machine has a single ansible-core
   (whatever the image baked in — currently 2.21), while the CI matrix
   runs stable-2.16 through stable-2.19. Different ansible-core
   versions ship different sanity rule sets and consult different
   `tests/sanity/ignore-2.XX.txt` files, so a local pass does not
   guarantee a pass on every CI cell — and vice versa. (This is also
   why local runs mention Python 3.14 at all: ansible-core 2.21
   supports it, while CI's newest branch, 2.19, stops at 3.13.)

   `ndtest-docker` does *not* close this gap — the test container is
   selected by the installed ansible-test. To reproduce a specific CI
   cell, install that stable branch into your user site first (it
   shadows the system copy), run the test, then uninstall to revert:

   ```bash
   ndm pip3 install --user --break-system-packages \
     https://github.com/ansible/ansible/archive/stable-2.19.tar.gz
   ndtest-docker
   ndm pip3 uninstall --break-system-packages -y ansible-core
   ```

3. **Scope.** CI also runs black (pep8 job), galaxy-importer, and the
   unit tests across the whole matrix; `ndtest` covers only `sanity`.
   Run `ndpytest` for the unit tests and black separately for the full
   pre-PR picture.

In practice: `ndtest` is the fast inner loop, and the skipped
3.13/3.14 compile checks are low-risk (they only catch syntax that is
invalid on those interpreters). Run `ndtest-docker` before opening a
PR, and reach for the pinned-ansible-core recipe above only when
chasing a CI-only failure.

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

## NOTES

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
you need the host counterpart of the venv, populated with the collection's
deps so imports resolve in the editor — do not symlink `.venv`, or the machine
would follow it and get the macOS binaries.

`setup.sh` **STEP 8** provisions this for you automatically: it creates
`.venv-Darwin-arm64` (if missing) and runs `uv sync` against `pyproject.toml`
+ `uv.lock` to install the full locked dev set (ansible-core, pydantic,
requests-toolbelt, jsonpath-ng, lxml, …). This is editor IntelliSense only —
it does not change the rule that tests/lint/type-checks run inside `nd-dev`.

To do it (or redo it) by hand, from the collection root on macOS:

```bash
VENV=".venv-$(uname -s)-$(uname -m)"          # .venv-Darwin-arm64
uv venv --python 3.12 "$VENV" --prompt ansible-nd
UV_PROJECT_ENVIRONMENT="$VENV" uv sync
```

Then point your editor at it explicitly (one-time per checkout):

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
automatically (`enable-linger` by `first-boot.sh`; the `containers.conf`
settings by `nd-provision.sh`, since that file lives on the virtiofs home,
which is not yet mounted when first-boot runs):

| Setting | Why |
| --- | --- |
| `pasta` rootless network backend | `slirp4netns` requires a D-Bus user session that isn't available early in boot; `pasta` avoids this |
| `cgroupfs` cgroup manager | The VM doesn't expose a systemd user session for cgroup v2 management |
| `seccomp=unconfined` | The ansible-test controller runs systemd as PID 1, which requires syscalls blocked by the default seccomp profile |
| `loginctl enable-linger` | Creates a persistent systemd user session with D-Bus, required for Podman to place the rootless netns process into `user-UID.slice` |

### `/dev/net/tun` permissions

The Apple VM exposes `/dev/net/tun` as `root:root 0600`. Both `pasta`
and `slirp4netns` need to open it for rootless networking. `first-boot.sh`
sets it to `0666` and writes a udev rule to make this persistent across
container restarts.

### Python CLI tooling (pipx + pinned pydantic)

The per-user dev tools — `ansible-lint`, `pylint`, `mypy`, `pytest`, and the
`black` / `isort` formatters — are installed by `nd-provision.sh` via **pipx**,
each in its own isolated venv under `~/.local/share/pipx/venvs/`. Because those
venvs are isolated, a system- or user-level `pydantic` is **not** visible inside
them. Every tool that *imports the collection's models* needs `pydantic`
injected explicitly (`black` / `isort` don't — they're covered in
[Python formatters](#python-formatters-black--isort) below):

| Tool | Why it needs pydantic |
| --- | --- |
| `pytest` | runs the orchestrator unit tests (instantiates the models) |
| `pylint` | imports the models during static analysis |
| `mypy` | uses the `pydantic.mypy` plugin and imports the models |

All three injects are **floored at `pydantic>=2.12.5`** to match the
collection's own pin in `requirements.txt` (`pydantic==2.12.5` on develop).
The old `<2.12` cap (issue #344: `pydantic>=2.12` hard-errored at class
construction on `NDBaseOrchestrator`) was dropped after
CiscoDevNet/ansible-nd#377 fixed the root cause.

This matters for `pytest` in particular: with **no** pydantic in its venv, the
collection silently falls back to its pydantic compat shim (where
`model_post_init` never fires) and the orchestrator tests pass for the wrong
reason. The pin keeps the machine's local test env matching CI on every rebuild.

**Self-healing.** `nd-provision.sh` injects these at provisioning time, so any
later drift (a failed inject, a partial manual recovery, a rebuild) could
silently degrade the env. `nddoctor.sh` is the idempotent guard against that
(for venvs that exist; a missing venv means provisioning never ran — re-run
`nd-provision.sh` or `setup.sh`):

```bash
nddoctor          # check + heal all three venvs, print a status report
```

The `ndpytest`, `ndmypy`, `ndpylint`, `ndblack`, and `ndisort` wrappers each
call `nddoctor.sh run <tool>` first, so they **self-heal their own venv on every
invocation** (quiet when already healthy) before running the tool. In normal use
you never need to run `nddoctor` by hand — it's there for an explicit check after
a rebuild or when something looks off.

**Offline resilience.** The machine normally has full outbound internet via
the container system's vmnet NAT, but a Tailscale exit node on the host
silently breaks that NAT (see [Troubleshooting](#troubleshooting)) — and
while it's broken, a plain `pipx inject` cannot reach PyPI. `nddoctor`
therefore prefers a **local wheelhouse** at `~/.cache/nd-wheelhouse`
(override with `ND_WHEELHOUSE`) whenever it contains
wheels, falling back to PyPI otherwise. Populate it from macOS — the home
directory is shared via virtiofs, so the same path is visible inside the
machine:

```bash
python3 -m pip download 'pydantic>=2.12.5' --platform manylinux_2_17_aarch64 \
  --python-version 3.12 --only-binary=:all: -d ~/.cache/nd-wheelhouse
```

Add `'black==26.5.1' 'isort==8.0.1'` to that download (their deps come along
automatically) if you also want the formatters to self-heal offline —
`nddoctor` installs them from the same wheelhouse.

### Python formatters (black + isort)

The collection's pre-commit lint pass runs `black` and `isort` on the changed
files, and its CLAUDE.md documents them as `ndm black <file>` / `ndm isort
<file>` — so both must exist **inside** the machine (issue #23). Like the other
Python CLI tools they are pipx-installed by `nd-provision.sh`, but unlike them
they import nothing from the collection, so they need **no** `pydantic` inject.

They are **exact-pinned** — `black==26.5.1`, `isort==8.0.1` — to the versions
the collection's `uv.lock` resolves, so the machine formats code identically to
the editor venv (`.venv-Darwin-arm64`) and to CI's pep8 job. This is a pin, not
a floor: `black`'s output changes across its calendar-versioned releases, so a
drifted version would reformat code differently and produce spurious diffs. The
pin lives in both `nd-provision.sh` (`BLACK_PIN` / `ISORT_PIN`, used at install
time) and `nddoctor.sh` (used to verify/heal) — bump both together, and the
collection's `uv.lock`, when the collection moves.

`nddoctor` checks the installed version against the pin and heals any mismatch
with a forced pipx reinstall (wheelhouse-first when offline, as above). Prefer
the `ndblack` / `ndisort` wrappers over `ndm black` / `ndm isort`: like
`ndpylint` / `ndmypy` / `ndpytest` they route through `nddoctor.sh run <tool>`,
so they **self-heal to the pinned version on every invocation** — a drifted
formatter is corrected the next time you run it, not only when you remember to
run `nddoctor`. (`ndm black` / `ndm isort` still work; they just skip the heal.)
Both formatters read the collection's `pyproject.toml` (line length 159,
`isort` on the `black` profile) when run from the collection root:

```bash
ndblack --check plugins/module_utils/orchestrators/base_interface.py
ndisort --check-only plugins/module_utils/orchestrators/base_interface.py
```

### Markdown linting (markdownlint via npm)

The collection's CLAUDE.md documents `ndm markdownlint <file>.md`, so the
`markdownlint` CLI (npm package `markdownlint-cli`) must exist **inside** the
machine. The `Dockerfile` bakes it into the image alongside Claude Code —
Node.js/npm are already there, and the image build runs on macOS where the
npm registry is reachable (the machine's own outbound network silently
breaks when a Tailscale exit node is active on the host — see
[Troubleshooting](#troubleshooting) — which is why this is *not* done in
`first-boot.sh`).

The package is **pinned at `markdownlint-cli@0.44.0`**: the image's apt
`nodejs` is 18.x, and `markdownlint-cli >= 0.45.0` requires Node >= 20 (npm
only warns on the engine mismatch, then the tool can fail at runtime). The
pin lives in both the `Dockerfile` and `nddoctor.sh` (`MDL_PIN`) — bump both
together if the image ever moves to a newer Node.

A machine built from an older image won't have it. `nddoctor` checks for the
binary and, when the npm registry is reachable, heals with `npm install -g`.
It probes reachability first (quick `curl`) because with the network down a
plain `npm install` burns many minutes of TCP retries before failing — and
npm's cache can't bridge the gap either: package metadata cached by the macOS
npm is not readable by the machine's older npm (`ENOTCACHED`).

The offline fix is a macOS-side install into the virtiofs-shared home —
`~/.local/bin` is first on the machine's PATH, and `markdownlint-cli` is pure
JavaScript, so one install serves both platforms (the `#!/usr/bin/env node`
shim resolves to each side's own Node):

```bash
npm install -g --prefix ~/.local markdownlint-cli@0.44.0
```

Or simply rebuild the image (see
[Rebuilding the machine](#rebuilding-the-machine)).

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

**Machine has no outbound network — `ndtest` hangs at "Installing requirements"**

The machine is *supposed* to have full outbound internet access through the
container system's vmnet NAT (`bridge100` + `InternetSharing` on macOS).
A **Tailscale exit node** on the host breaks that NAT — confirmed by
controlled reproduction (2 full cycles on a stable network, with host
connectivity verified before and after every probe):

- Activating an exit node (`tailscale set --exit-node=<node>`) moves the
  host's default route onto Tailscale's `utun` interface, and the vmnet
  NAT black-holes all guest traffic **immediately** — even against
  freshly rebuilt NAT state. The host itself stays online through the
  tunnel; only the machine (and the buildkit builder VM) goes dark.
- Deactivating the exit node does **not** heal it. Once an exit node has
  been active, the NAT state is poisoned until the container system is
  restarted.
- Ruled out: WiFi flaps (20s and 45s outages), switching networks
  (hotspot → home WiFi), sleep/wake in between, and Tailscale merely
  being connected — none of these broke the NAT. Plain Tailscale
  (including `RouteAll`/CorpDNS, no exit node) coexists fine.
- Related upstream: apple/container#1881, tailscale/tailscale#18653.
  (Unlike the subnet-route variant described there, this one *does* heal
  on a container-system restart.)

The failure signature:

- DNS still resolves inside the machine (the gateway answers it locally),
  but every forwarded TCP/ICMP connection black-holes (`SYN-SENT` forever
  in `ss -tnp`)
- `ndtest` hangs at `Installing requirements for Python 3.12 [venv]`
  (ansible-test bootstrapping pip from PyPI)
- `nddoctor` reports the npm registry unreachable, and `container build`
  times out fetching packages (the builder VM sits behind the same NAT)

The fix: deactivate the exit node, confirm the macOS host itself is online,
then restart the container system to rebuild the NAT state:

```bash
tailscale set --exit-node=          # exit node must be OFF during the rebuild
container machine stop nd-dev
container system stop
container system start
container machine run -n nd-dev --root -- true   # boot the machine again
```

Verify from inside the machine:

```bash
ndm curl -sI --max-time 5 https://pypi.org/
```

Operating rule: don't run a Tailscale exit node while the machine needs
outbound network, and after any exit-node session do the restart above
before trusting `ndtest` / `nddoctor` healing / `container build` again.

The offline fallbacks (`ndlint --offline`, the pip wheelhouse, nddoctor's
npm reachability probe) exist so linting and healing keep working while the
NAT is broken — they are resilience against this failure mode, not a design
statement that the machine is meant to be offline.

**Guest DNS refused (managed host) — `container build` / apt / pip fail with
"Temporary failure resolving", but raw-IP traffic works**

This is the *inverse* signature of the Tailscale failure above: there, DNS
resolves but forwarded connections black-hole; here, forwarding works but
DNS is refused.

On a healthy host, guest DNS is served by macOS **`mDNSResponder`**, which
listens on the vmnet NAT gateway (`192.168.64.1:53`) as a DNS proxy. On some
managed (MDM/EDR) hosts that listener never comes up — observed on a
corporate Mac with Cisco Secure Endpoint + Secure Client filter extensions
active — so guests get connection-refused for every DNS query while NAT
forwarding itself is fine. Disconnecting the VPN doesn't help (it isn't the
VPN: the default route stays on `en0`), and neither does restarting the
container system.

Confirm the signature:

```bash
# Guest side — DNS fails, raw connectivity works:
container run --rm docker.io/library/ubuntu:24.04 bash -c '
  getent hosts ports.ubuntu.com && echo DNS-OK || echo DNS-FAILED
  timeout 5 bash -c "</dev/tcp/1.1.1.1/53" && echo FORWARD-OK || echo FORWARD-FAILED'

# Host side — empty output means nothing is listening on port 53
# (on a healthy host this shows mDNSResponder):
netstat -anv -p udp | grep -E '\.53\s'
```

The fix: bypass the gateway proxy by giving the builder VM and the machine
an external DNS server. Safe to re-run against an existing machine:

```bash
ND_GUEST_DNS=1.1.1.1 bash setup.sh
```

This recreates the builder with `--dns`, writes `/etc/nd-dev/dns-override`
inside the machine, and enables the `nd-dns-override` units: a path watcher
that re-copies the override over `/etc/resolv.conf` whenever it changes,
plus a 5-second boot timer. Two triggers because the machine runtime's
agent rewrites `resolv.conf` to point at the gateway *out-of-band on every
boot, racing systemd* — verified empirically: a plain
`WantedBy=multi-user.target` oneshot ran at boot and still lost to the
agent's rewrite in the same second, and an early-boot inotify watch alone
can also lose the race. The timer sweeps up whichever ordering happens.
Without `ND_GUEST_DNS` set, all the units are inert and the machine uses
the gateway as normal.

`setup.sh` also records the value in `~/.config/nd-dev/guest-dns`, which
`nd-provision.sh` reads when setup.sh runs it after machine create — the
override is applied there *before* the apt/pipx toolchain installs that
need working DNS. (It cannot be applied from `first-boot.sh`: the runtime
runs that script before the virtiofs home is mounted, so the conf file is
not visible yet.) A machine that was provisioned while DNS was broken is
missing the pipx toolchain (symptoms: `ndpytest`/`nddoctor` report "pipx
venv not found"); heal it by re-running setup with the override recorded —
no recreate needed, `nd-provision.sh` is idempotent:

```bash
ND_GUEST_DNS=1.1.1.1 bash setup.sh
```

To stop using the override later: `rm ~/.config/nd-dev/guest-dns`, then
inside the machine `sudo rm /etc/nd-dev/dns-override`, then reboot the
machine — the runtime restores stock gateway DNS on the next boot.

Do **not** be tempted by `chattr +i /etc/resolv.conf` instead: the agent's
`configureDns` bootstrap step hard-fails when its write is denied and the
machine no longer boots at all (recovery requires
`container machine rm` + recreate).

Caveat: pick a resolver the local network actually allows. Corporate
networks often block outbound DNS to public resolvers — if `1.1.1.1` is
blocked on-site, use the host's own DNS servers (first `nameserver` shown
by `scutil --dns`) instead.

### Machine doesn't start at login

```bash
ndlogs   # check /tmp/container-nd-dev-boot.err
# If the 15s delay isn't enough, edit the plist:
# ~/Library/LaunchAgents/com.user.container.nd-dev.plist
# Increase the sleep value and reload:
launchctl bootout gui/$(id -u)/com.user.container.nd-dev
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.container.nd-dev.plist
```

### `ansible-test --docker default` fails with "dbus" or "user session" errors

```bash
# Re-enable user lingering inside the machine
ndm sudo loginctl enable-linger $(whoami)
```

### `ansible-test --docker default` fails with "insufficient UIDs/GIDs"

```bash
# Check subuid/subgid inside the machine
ndm cat /etc/subuid /etc/subgid
# Should show: <your-macos-username>:100000:65536 (not ubuntu:...)
# If wrong, fix and migrate:
ndm sudo sed -i "s/^ubuntu:/$(whoami):/" /etc/subuid /etc/subgid
ndm podman system migrate
```

### `/dev/net/tun: Permission denied`

```bash
ndm sudo chmod 0666 /dev/net/tun
```

### Unit tests pass locally but behave differently from CI (pydantic compat shim)

If `pydantic` is missing from the `pytest` pipx venv, the collection falls back
to its compat shim — `model_post_init` never fires and the orchestrator tests
pass (or fail) for the wrong reason. The one-command fix is `nddoctor`, which
checks every venv and re-injects the pinned pydantic where it is missing or
out of range:

```bash
nddoctor          # check + heal pytest / pylint / mypy
```

The `ndpytest` / `ndmypy` / `ndpylint` wrappers also self-heal automatically, so
you usually hit this only after a manual `pipx` operation. Manual fallback if you
ever need it (this is exactly what `nddoctor` and `nd-provision.sh` do):

```bash
# Check the version inside each venv (should be >= 2.12.5)
for v in pytest pylint mypy; do
  echo -n "$v: "; ndm ~/.local/share/pipx/venvs/$v/bin/python -c 'import pydantic; print(pydantic.VERSION)'
done

# Restore / upgrade if missing or < 2.12.5
ndm pipx inject pytest 'pydantic>=2.12.5'
ndm pipx inject pylint 'pydantic>=2.12.5'
ndm pipx inject mypy   'pydantic>=2.12.5'
```

If the machine is offline (the usual case), the plain injects above fail —
populate the wheelhouse from macOS first and let `nddoctor` do the offline
install:

```bash
python3 -m pip download 'pydantic>=2.12.5' --platform manylinux_2_17_aarch64 \
  --python-version 3.12 --only-binary=:all: -d ~/.cache/nd-wheelhouse
nddoctor
```

### `uv sync` fails with Python version conflicts

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
