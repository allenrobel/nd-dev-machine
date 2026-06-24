#!/usr/bin/env bash
# setup.sh — nd-dev container machine: one-time setup walkthrough
#
# Run from the directory containing this file:
#   cd ~/nd-dev-machine && bash setup.sh
#
# All files are expected flat in the same directory as this script:
#   setup.sh
#   Dockerfile
#   first-boot.sh
#   nd-dev.sh            (shell aliases)
#   CLAUDE.md
#   com.apple.container.system.plist
#   com.user.container.nd-dev.plist

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

step "Building local/nd-dev:latest..."
container build --pull -t local/nd-dev:latest "${SCRIPT_DIR}"
ok "Image built: local/nd-dev:latest"

# ─────────────────────────────────────────────────────────────────────────────
header "STEP 3 — Create the nd-dev container machine"
# ─────────────────────────────────────────────────────────────────────────────

note "6 CPUs, 8 GB RAM — adjust later with:"
note "  container machine set -n nd-dev cpus=N memory=XG && container machine stop nd-dev"

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
    warn "STEP 7 to install CLAUDE.md."
fi

# ansible-test check — 'ansible-test --version' exits 0; bare 'ansible-test' exits 2
step "Verifying ansible-test..."
if container machine run -n nd-dev -- bash -lc "ansible-test --version" \
        > /dev/null 2>&1; then
    ok "ansible-test available"
    container machine run -n nd-dev -- bash -lc "ansible-test --version"
else
    warn "ansible-test not found in PATH yet."
    warn "The first-boot pip install may still be running. Wait ~60s then check with:"
    warn "  container machine run -n nd-dev -- bash -lc 'ansible-test --version'"
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
header "STEP 7 — Install CLAUDE.md into the ND collection"
# ─────────────────────────────────────────────────────────────────────────────

ND_COLLECTION="${HOME}/ansible_collections/cisco/nd"
CLAUDE_MD_SRC="${SCRIPT_DIR}/CLAUDE.md"
CLAUDE_MD_DST="${ND_COLLECTION}/CLAUDE.md"

if [ ! -f "${CLAUDE_MD_SRC}" ]; then
    warn "Missing: ${CLAUDE_MD_SRC} — copy CLAUDE.md into ${SCRIPT_DIR} and re-run."
elif [ ! -d "${ND_COLLECTION}" ]; then
    warn "Collection not found at ${ND_COLLECTION}"
    warn "Once checked out, install CLAUDE.md with:"
    warn "  cp '${CLAUDE_MD_SRC}' '${CLAUDE_MD_DST}'"
elif [ -f "${CLAUDE_MD_DST}" ]; then
    warn "CLAUDE.md already exists at ${CLAUDE_MD_DST} — skipping to avoid overwrite."
    warn "Review and merge manually from: ${CLAUDE_MD_SRC}"
else
    cp "${CLAUDE_MD_SRC}" "${CLAUDE_MD_DST}"
    ok "CLAUDE.md installed at ${CLAUDE_MD_DST}"
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
