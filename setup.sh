#!/usr/bin/env bash
# setup.sh — nd-dev container machine: one-time setup walkthrough
#
# Run from the directory containing this file:
#   cd ~/nd-dev-machine && bash setup.sh
#
# All files are expected flat in the same directory as this script:
#   setup.sh
#   Dockerfile
#   first-boot.sh        (rootfs-only; runs before the home mount exists)
#   nd-provision.sh      (home-dependent provisioning; run via machine run)
#   nd-dev.sh            (shell aliases)
#   nd-dns-override.service
#   nd-dns-override.path
#   nd-dns-override.timer
#   CLAUDE.md
#   com.apple.container.system.plist
#   com.user.container.nd-dev.plist
#
# Optional environment knobs:
#   ND_GUEST_DNS=<ip>   Give the builder VM and the nd-dev machine an external
#                       DNS server instead of the vmnet NAT gateway
#                       (192.168.64.1). Use when the gateway refuses DNS —
#                       e.g. managed hosts where endpoint security blocks
#                       mDNSResponder's DNS-proxy role. See README
#                       "Troubleshooting". Example:
#                         ND_GUEST_DNS=1.1.1.1 bash setup.sh
#                       The value is also recorded in
#                       ~/.config/nd-dev/guest-dns so first-boot.sh can apply
#                       it during machine create (its one-time apt/pipx
#                       provisioning needs working DNS). To stop using the
#                       override, remove that file and the machine's
#                       /etc/nd-dev/dns-override, then reboot the machine.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header() { echo ""; echo "══════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════"; }
step()   { echo ""; echo "── $1"; }
note()   { echo "   ℹ  $1"; }
ok()     { echo "   ✓  $1"; }
warn()   { echo "   ⚠  $1"; }

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 1 — Start the container system service"
# ─────────────────────────────────────────────────────────────────────────────

step "Starting container background services..."
if container system start 2>/dev/null; then
    ok "container system started"
else
    warn "container system start returned non-zero — may already be running"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 2 — Build the nd-dev image"
# ─────────────────────────────────────────────────────────────────────────────

note "This pulls ubuntu:24.04, installs systemd/Podman/Python/ansible-core"
note "and Claude Code. Expect 3-6 minutes on first run; cached layers are fast."
note "Build context: ${SCRIPT_DIR}"

if [ -n "${ND_GUEST_DNS:-}" ]; then
    step "ND_GUEST_DNS=${ND_GUEST_DNS} — recreating builder with external DNS..."
    # The builder VM normally resolves via the vmnet NAT gateway; when the
    # host's DNS proxy is blocked (see README "Troubleshooting"), the build
    # fails with "Temporary failure resolving". --dns points the builder at
    # an external resolver instead. The flag only takes effect at builder
    # creation, so drop any existing builder first.
    container builder delete 2>/dev/null || true
    container builder start --dns "${ND_GUEST_DNS}"
    ok "Builder started with --dns ${ND_GUEST_DNS}"
fi

step "Building local/nd-dev:latest..."
container build --pull -t local/nd-dev:latest "${SCRIPT_DIR}"
ok "Image built: local/nd-dev:latest"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 3 — Create the nd-dev container machine"
# ─────────────────────────────────────────────────────────────────────────────

note "6 CPUs, 8 GB RAM — adjust later with:"
note "  container machine set -n nd-dev cpus=N memory=XG && container machine stop nd-dev"

# Record the guest DNS override where first-boot.sh can see it (the home
# directory is virtiofs-mounted into the machine). Must happen BEFORE
# machine create: first-boot needs working DNS for its apt/pipx installs,
# and the in-machine override below is only applied after create.
if [ -n "${ND_GUEST_DNS:-}" ]; then
    step "Recording guest DNS for first-boot (~/.config/nd-dev/guest-dns)..."
    mkdir -p "${HOME}/.config/nd-dev"
    printf '%s\n' "${ND_GUEST_DNS}" > "${HOME}/.config/nd-dev/guest-dns"
    ok "Recorded — future machine creates provision with DNS ${ND_GUEST_DNS}"
fi

if container machine ls 2>/dev/null | grep -q '^nd-dev'; then
    warn "Machine 'nd-dev' already exists — skipping create."
    warn "To rebuild from scratch:  container machine rm nd-dev  then re-run this script."
else
    # Restart the container system before creating the machine.
    # 'container machine rm' doesn't always clean up internal hostname records,
    # causing "hostname(s) already exist" errors on the next create. A stop/start
    # cycle flushes stale state and takes only a few seconds.
    step "Restarting container system to flush stale hostname state..."
    container system stop 2>/dev/null || true
    container system start
    ok "Container system ready"

    step "Creating nd-dev machine..."
    container machine create local/nd-dev:latest \
        --name nd-dev \
        --cpus 6 \
        --memory 8G \
        --set-default
    ok "Machine created"
fi

# The machine takes a few seconds after create (or after a cold boot) before
# it accepts commands — running one too early fails with "Operation not
# supported by device". Wait until it responds before the steps below.
step "Waiting for nd-dev to accept commands..."
MACHINE_READY=0
for _i in $(seq 1 30); do
    if container machine run -n nd-dev --root -- true > /dev/null 2>&1; then
        MACHINE_READY=1
        break
    fi
    sleep 3
done
if [ "${MACHINE_READY}" -eq 1 ]; then
    ok "Machine is responding"
else
    warn "nd-dev not responding after 90s — subsequent steps may fail."
fi

# In-machine provisioning (guest DNS override, containers.conf, podman
# migrate, pipx toolchain, home rc patches). This CANNOT live in
# first-boot.sh: the runtime runs that script before mounting the macOS
# home, so home-dependent steps there silently land on a shadowed local
# stub. nd-provision.sh is idempotent — it runs on fresh creates AND on
# re-runs against an existing machine, so a machine that was provisioned
# while its network was broken is healed by re-running setup.sh.
step "Provisioning inside nd-dev (DNS override, Podman config, pipx toolchain)..."
container machine run -n nd-dev --root -- \
    "${SCRIPT_DIR}/nd-provision.sh" "$(whoami)" "${HOME}"
ok "In-machine provisioning complete"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 4 — Verify the machine (home mount + identity)"
# ─────────────────────────────────────────────────────────────────────────────

step "Checking user identity and home mount inside nd-dev..."
container machine run -n nd-dev -- whoami
container machine run -n nd-dev -- pwd

# Collection check — warn only, not a failure
if container machine run -n nd-dev -- ls "${HOME}/ansible_collections/cisco/nd" \
        > /dev/null 2>&1; then
    ok "ND collection visible inside machine"
else
    warn "~/ansible_collections/cisco/nd not found on this machine — that's OK if"
    warn "you haven't checked it out on this Mac yet. Clone it first, then re-run"
    warn "STEP 7 for the CLAUDE.md linking reminder."
fi

# ansible-test check — use 'command -v': current ansible-core makes
# 'ansible-test --version' error out demanding a COMMAND argument, so a
# version probe false-negatives even when ansible-test is installed.
step "Verifying ansible-test..."
if container machine run -n nd-dev -- bash -lc "command -v ansible-test" \
        > /dev/null 2>&1; then
    ok "ansible-test available"
    # HOME=/tmp: the runtime hands plain (non --root) sessions HOME=/home/<user>,
    # which doesn't exist — ansible would fail creating ~/.ansible there.
    container machine run -n nd-dev -- bash -lc "HOME=/tmp ansible --version | head -1"
else
    warn "ansible-test not found in PATH — the image build may be stale."
    warn "Check with:"
    warn "  container machine run -n nd-dev -- bash -lc 'command -v ansible-test'"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 5 — Install LaunchAgents (auto-start at login)"
# ─────────────────────────────────────────────────────────────────────────────

# Plists are expected flat alongside this script (no launchagents/ subdirectory)
PLIST_SRC="${SCRIPT_DIR}"
PLIST_DST="${HOME}/Library/LaunchAgents"

# Verify the plist files are present before proceeding
for plist in com.apple.container.system.plist com.user.container.nd-dev.plist; do
    if [ ! -f "${PLIST_SRC}/${plist}" ]; then
        warn "Missing: ${PLIST_SRC}/${plist}"
        warn "Make sure all files from the download are in ${SCRIPT_DIR}"
        warn "then re-run: bash setup.sh"
        exit 1
    fi
done

step "Copying plists to ~/Library/LaunchAgents..."
mkdir -p "${PLIST_DST}"
cp "${PLIST_SRC}/com.apple.container.system.plist" "${PLIST_DST}/"
cp "${PLIST_SRC}/com.user.container.nd-dev.plist"  "${PLIST_DST}/"
ok "Plists copied"

step "Loading LaunchAgents..."
# Unload first in case of stale registrations (errors here are harmless)
launchctl bootout "gui/$(id -u)/com.apple.container.system" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.user.container.nd-dev"  2>/dev/null || true

launchctl bootstrap "gui/$(id -u)" "${PLIST_DST}/com.apple.container.system.plist"
launchctl bootstrap "gui/$(id -u)" "${PLIST_DST}/com.user.container.nd-dev.plist"
ok "LaunchAgents registered"

note "The nd-dev machine will auto-start at login (15s after the container"
note "system service). Check /tmp/container-nd-dev-boot.err after next login"
note "if the machine doesn't come up."

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 6 — Wire up shell aliases"
# ─────────────────────────────────────────────────────────────────────────────

# Generate ndm-env.sh — the env shim used by nd-dev.sh to set HOME and PATH
# correctly inside the machine. Generated rather than static so it contains
# the actual macOS username and home path of whoever runs setup.sh.
NDM_ENV="${SCRIPT_DIR}/ndm-env.sh"
step "Generating ndm-env.sh..."
cat > "${NDM_ENV}" << ENVEOF
#!/bin/bash
# Auto-generated by setup.sh — do not edit manually, re-run setup.sh instead.
# Sets HOME and PATH to the macOS user's virtiofs-mounted home before exec'ing
# the requested command. Required because the container machine runtime
# overrides HOME regardless of /etc/passwd when using --root.
export HOME="${HOME}"
export PATH="${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export USER="$(whoami)"
export LOGNAME="$(whoami)"
exec "\$@"
ENVEOF
chmod +x "${NDM_ENV}"
ok "Generated: ${NDM_ENV}"

# nd-dev.sh is expected flat alongside this script
ALIAS_FILE="${SCRIPT_DIR}/nd-dev.sh"
ALIAS_LINE="source '${ALIAS_FILE}'"
ZSHRC="${HOME}/.zshrc"
BASHRC="${HOME}/.bashrc"

if [ ! -f "${ALIAS_FILE}" ]; then
    warn "Missing: ${ALIAS_FILE} — aliases not wired. Copy nd-dev.sh into"
    warn "${SCRIPT_DIR} and re-run setup.sh."
else
    wire_rc() {
        local RC="$1"
        [ -f "$RC" ] || return 0
        if grep -qF "nd-dev.sh" "$RC"; then
            note "Already sourced in ${RC} — skipping"
        else
            echo "" >> "$RC"
            echo "# nd-dev container machine aliases" >> "$RC"
            echo "${ALIAS_LINE}" >> "$RC"
            ok "Added source line to ${RC}"
        fi
    }

    wire_rc "${ZSHRC}"
    wire_rc "${BASHRC}"
    note "Reload your shell to activate:  source ~/.zshrc"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 7 — Link the nd-dev CLAUDE.md into your LLM context"
# ─────────────────────────────────────────────────────────────────────────────

# This repo's CLAUDE.md is the single source of truth for the nd-dev tooling.
# We deliberately do NOT copy it into the cisco/nd collection: that left an
# uncommitted CLAUDE.md inside the ansible-nd git repo. Instead, link to it with
# an `@<path>` import from a CLAUDE.md placed *outside* that repo — the cisco
# namespace directory, one level above the `nd` collection, is ideal because the
# link never shows up as a dirty file in ansible-nd. This step only prints the
# reminder; it does not write into either repo.

ND_NAMESPACE="${HOME}/ansible_collections/cisco"
CLAUDE_MD_SRC="${SCRIPT_DIR}/CLAUDE.md"
LINK_TARGET="${ND_NAMESPACE}/CLAUDE.md"
IMPORT_LINE="@${CLAUDE_MD_SRC}"
STALE_COPY="${ND_NAMESPACE}/nd/CLAUDE.md"

if [ ! -f "${CLAUDE_MD_SRC}" ]; then
    warn "Missing: ${CLAUDE_MD_SRC} — this repo's CLAUDE.md is the link source."
elif [ -f "${LINK_TARGET}" ] && grep -qF "${IMPORT_LINE}" "${LINK_TARGET}"; then
    ok "Already linked from ${LINK_TARGET}"
else
    note "To let your LLM see the nd-dev wrappers (ndtest, ndlint, ndm, …), add"
    note "this import line to ${LINK_TARGET}:"
    note "  ${IMPORT_LINE}"
    note "That file sits in the collection namespace dir, above the cisco/nd git"
    note "repo, so the link never becomes an uncommitted file in ansible-nd."
fi

# Flag (but don't touch) a CLAUDE.md left behind by older, copy-based setup runs.
if [ -f "${STALE_COPY}" ]; then
    warn "A copied CLAUDE.md exists at ${STALE_COPY} (from an older setup.sh)."
    warn "It is no longer managed here — remove it to keep the ansible-nd repo clean:"
    warn "  rm '${STALE_COPY}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 8 — Provision the macOS editor venv (.venv-Darwin-arm64)"
# ─────────────────────────────────────────────────────────────────────────────

# Editor IntelliSense only. VS Code / Pylance points at this host venv, so it
# must contain the collection's third-party deps (ansible-core, pydantic,
# requests-toolbelt, jsonpath-ng, lxml) for imports to resolve. This does NOT
# violate the CLAUDE.md "no pip install / ansible-test on macOS" rule: that rule
# governs *test execution*, which still runs exclusively inside nd-dev. Nothing
# installed here is ever used to run tests.

HOST_VENV_NAME=".venv-$(uname -s)-$(uname -m)"          # e.g. .venv-Darwin-arm64
HOST_VENV_DIR="${ND_COLLECTION}/${HOST_VENV_NAME}"

if ! command -v uv > /dev/null 2>&1; then
    warn "uv not found on macOS PATH — skipping editor venv provisioning."
    warn "Install uv (https://docs.astral.sh/uv/), then re-run setup.sh, or"
    warn "provision manually per the README 'Python CLI tooling' section."
elif [ ! -d "${ND_COLLECTION}" ]; then
    warn "Collection not found at ${ND_COLLECTION} — skipping editor venv."
    warn "Clone it, then re-run setup.sh to provision ${HOST_VENV_NAME}."
else
    if [ ! -x "${HOST_VENV_DIR}/bin/python" ]; then
        step "Creating ${HOST_VENV_NAME}..."
        ( cd "${ND_COLLECTION}" && uv venv --python 3.12 "${HOST_VENV_NAME}" --prompt ansible-nd )
        ok "Created ${HOST_VENV_DIR}"
    else
        note "${HOST_VENV_NAME} already exists — syncing collection deps into it."
    fi

    step "Installing collection deps with 'uv sync' (full locked dev set)..."
    if ( cd "${ND_COLLECTION}" && UV_PROJECT_ENVIRONMENT="${HOST_VENV_NAME}" uv sync ); then
        ok "Editor venv provisioned: ${HOST_VENV_DIR}"
        if "${HOST_VENV_DIR}/bin/python" -c \
                "import ansible, pydantic, requests_toolbelt, jsonpath_ng, lxml" 2>/dev/null; then
            ok "Imports resolve: ansible(-core), pydantic, requests_toolbelt, jsonpath_ng, lxml"
        else
            warn "uv sync completed but an import probe failed — review the 'uv sync' output above."
        fi
        note "Point your editor at it (one-time, see README):"
        note "  \"python.defaultInterpreterPath\": \"\${workspaceFolder}/${HOST_VENV_NAME}/bin/python\""
    else
        warn "uv sync failed — editor IntelliSense may not resolve third-party imports."
        warn "Retry manually:"
        warn "  cd '${ND_COLLECTION}' && UV_PROJECT_ENVIRONMENT='${HOST_VENV_NAME}' uv sync"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 9 — Ignore machine-generated dev artifacts (global git ignore)"
# ─────────────────────────────────────────────────────────────────────────────

# Working the collection on this machine leaves a few regenerable, per-developer
# trees that are deliberately NOT in the team's tracked .gitignore:
#   collections/      — pytest-ansible's collection symlink farm (ndpytest creates
#                       it unless run with --ansible-unit-inject-only, which the
#                       wrapper now does).
#   .ansible/         — ansible-lint's galaxy/cache tree. ansible-lint hardcodes
#                       Runtime(isolated=True), so it ALWAYS writes
#                       <project>/.ansible regardless of ANSIBLE_HOME.
#   .venv / .venv-*/  — per-platform uv venvs (suffixed by `uname` so the macOS
#                       host and the Linux machine never collide on the shared
#                       virtiofs tree).
# Left un-ignored, collections/ and .ansible/ block `git rebase` (the "move aside
# the untracked symlink loop" dance). We ignore all of them via the developer's
# *global* git ignore so each repo's own tracked .gitignore can stay aligned with
# the team's. Directory patterns only affect *untracked* dirs of those names — a
# repo that tracks one is unaffected.

if ! command -v git > /dev/null 2>&1; then
    warn "git not found on macOS PATH — skipping global git ignore setup."
    warn "Add '.ansible/', 'collections/', '.venv', '.venv-*/' to your global git ignore manually."
else
    # Respect an existing core.excludesfile; otherwise use git's XDG default.
    GLOBAL_IGNORE="$(git config --global --get core.excludesfile 2>/dev/null || true)"
    if [ -n "${GLOBAL_IGNORE}" ]; then
        GLOBAL_IGNORE="${GLOBAL_IGNORE/#\~/$HOME}"           # expand leading ~
    else
        GLOBAL_IGNORE="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
    fi

    step "Ensuring entries in ${GLOBAL_IGNORE}..."
    mkdir -p "$(dirname "${GLOBAL_IGNORE}")"
    touch "${GLOBAL_IGNORE}"

    # One-time explanatory header (sentinel-guarded so re-runs don't duplicate it).
    if ! grep -qF "nd-dev: machine-generated ansible artifacts" "${GLOBAL_IGNORE}"; then
        {
            echo ""
            echo "# nd-dev: machine-generated ansible artifacts (regenerable; never source)."
            echo "# ansible-lint writes .ansible/ and pytest-ansible writes collections/ into"
            echo "# the collection root. Ignored globally so each repo's tracked .gitignore can"
            echo "# match the team's. Only affects *untracked* dirs of these names."
        } >> "${GLOBAL_IGNORE}"
    fi

    add_ignore() {
        local pat="$1"
        if grep -qxF "${pat}" "${GLOBAL_IGNORE}"; then
            note "Already present: ${pat}"
        else
            printf '%s\n' "${pat}" >> "${GLOBAL_IGNORE}"
            ok "Added: ${pat}"
        fi
    }
    add_ignore ".ansible/"
    add_ignore "collections/"

    # Per-platform uv venvs — separate sentinel so existing installs pick these
    # up on re-run without duplicating the comment above.
    if ! grep -qF "nd-dev: per-platform uv venvs" "${GLOBAL_IGNORE}"; then
        {
            echo ""
            echo "# nd-dev: per-platform uv venvs (.venv-<os>-<arch>; shared host/machine tree"
            echo "# via virtiofs, per-developer). Ignored globally so the collection's tracked"
            echo "# .gitignore can match the team's."
        } >> "${GLOBAL_IGNORE}"
    fi
    add_ignore ".venv"
    add_ignore ".venv-*/"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "ALL DONE"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "  Quick-reference:"
echo ""
echo "    ndm                  → interactive shell in nd-dev"
echo "    ndtest               → ansible-test sanity --docker default (all checks)"
echo "    ndtest --test validate-modules plugins/modules/my_module.py"
echo "    ndlint plugins/      → ansible-lint"
echo "    ndmypy plugins/      → mypy"
echo "    ndpylint <file>      → pylint"
echo "    ndlogs               → check LaunchAgent boot logs"
echo ""
echo "  To run Claude Code against the collection (from macOS):"
echo "    cd ~/ansible_collections/cisco/nd && claude"
echo ""
echo "  For a fully-native agentic session (tests + edits both in Linux):"
echo "    ndm     # then run 'claude' from inside the machine"
echo ""
