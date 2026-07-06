# ─────────────────────────────────────────────────────────────────────────────
# nd-dev container machine aliases
# Source this from ~/.zshrc after setup:
#
#   echo 'source ~/nd-dev-machine/nd-dev.sh' >> ~/.zshrc
#
# Design notes:
#   - 'container machine run -- bash -c <cmd>' silently drops stdout for quoted
#     strings. We write commands to temp scripts on the virtiofs mount instead.
#   - All scripts run as root (--root) with HOME/PATH set to the macOS user's
#     virtiofs-mounted home. This sidesteps the container runtime's HOME
#     override behaviour.
#   - cwd is captured on the macOS side and written into the script explicitly.
# ─────────────────────────────────────────────────────────────────────────────

_NDM_USER="$(whoami)"
_NDM_HOME="/Users/${_NDM_USER}"
_NDM_REPO="${_NDM_HOME}/nd-dev-machine"
_NDM_TMPDIR="${_NDM_REPO}/.tmp"
_NDM_PATH="${_NDM_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Internal helper — writes a script to the virtiofs mount and executes it.
# Usage: _ndm_run <cwd> <cmd> [args...]
#   cwd  — working directory inside the machine (pass $(pwd) from macOS)
#   cmd  — command and arguments to run
function _ndm_run {
    local cwd="$1"
    shift
    local script
    mkdir -p "${_NDM_TMPDIR}"
    # Unique path per invocation via mktemp. A fixed name (e.g. cmd-$$.sh) collides
    # when two _ndm_run calls run back-to-back in the same shell: call N's trailing
    # `rm` churns the path while call N+1 writes/execs the SAME path, and virtiofs
    # metadata coherence lags — surfacing as
    # "cmd-...: cannot execute: required file not found". A fresh unique path is
    # never re-touched, so there is nothing to race (mktemp is atomic, so this also
    # holds across subshells/concurrent shells — a counter would not). No .sh
    # suffix: the runtime execs by path via the shebang, so the extension is moot.
    script="$(mktemp "${_NDM_TMPDIR}/cmd-XXXXXXXX")" || {
        echo "ERROR: could not create temp script in ${_NDM_TMPDIR}" >&2
        return 1
    }
    # Write the script — all variables expanded on macOS side at write time
    cat > "${script}" << NDMSCRIPT
#!/bin/bash
export HOME="${_NDM_HOME}"
export PATH="${_NDM_PATH}"
export USER="${_NDM_USER}"
export LOGNAME="${_NDM_USER}"
# Per-platform uv venv: macOS and the Linux machine share this tree via
# virtiofs, so a single .venv path can't serve both (binaries/.so files are
# platform-specific). The \$(uname ...) is escaped so it is evaluated at
# runtime *inside* the machine (Linux) — yielding e.g. .venv-Linux-aarch64.
export UV_PROJECT_ENVIRONMENT=".venv-\$(uname -s)-\$(uname -m)"
cd "${cwd}" || { echo "ERROR: could not cd to ${cwd}"; exit 1; }
$@
NDMSCRIPT
    chmod +x "${script}"
    container machine run -n nd-dev --root -- "${script}"
    local rc=$?
    rm -f "${script}"
    return $rc
}

# Drop into an interactive shell inside nd-dev, or run a single command.
#
#   ndm                 → interactive Linux shell; type 'exit' to return to macOS
#   ndm uname -a        → run a single command and return immediately
#
# Note: interactive mode uses bare 'container machine run -n nd-dev' with no
# command, which the runtime handles natively as a TTY login session. Single
# commands use _ndm_run (temp script) to avoid the stdout-swallowing issue
# that affects 'bash -c' invocations via container machine run.
function ndm {
    if [ $# -eq 0 ]; then
        container machine run -n nd-dev
    else
        _ndm_run "$(pwd)" "$@"
    fi
}

# Run ansible-test sanity using --venv (fast, recommended for local iteration).
# Must be run from within the collection directory.
#
# Usage:
#   ndtest                                                  → all sanity checks
#   ndtest --test validate-modules                          → single test
#   ndtest --test validate-modules plugins/modules/nd_my_module.py
function ndtest {
    _ndm_run "$(pwd)" ansible-test sanity --venv "$@"
}

# Run ansible-test sanity using --docker default (slower; same all-Pythons
# container as CI, but still the machine's single ansible-core version — see
# README "Local testing vs GitHub CI"). Use before opening a PR or when
# debugging a CI-specific failure.
#
# Usage:
#   ndtest-docker                                           → all sanity checks
#   ndtest-docker --test validate-modules
function ndtest-docker {
    _ndm_run "$(pwd)" ansible-test sanity --docker default "$@"
}

# Run ansible-lint inside the machine.
# --offline skips ansible-lint's Galaxy pre-flight: the nd-dev sandbox has no
# network, and deps are already provisioned via uv.lock/pipx — without it the
# pre-flight fails and ansible-lint can exit 0 without running the rules.
function ndlint {
    _ndm_run "$(pwd)" ansible-lint --offline "$@"
}

# Verify/self-heal the pipx tool venvs (pinned pydantic in pytest/pylint/mypy).
# Run on demand, e.g. after a machine rebuild or if unit tests act up. The
# ndmypy/ndpylint/ndpytest wrappers below also self-heal their own venv on each
# invocation, so you rarely need to call this directly. See nddoctor.sh.
function nddoctor {
    _ndm_run "$_NDM_HOME" "$_NDM_REPO/nddoctor.sh" "$@"
}

# Run mypy inside the machine (self-heals mypy's pydantic first via nddoctor).
function ndmypy {
    _ndm_run "$(pwd)" "$_NDM_REPO/nddoctor.sh" run mypy "$@"
}

# Run pylint inside the machine (self-heals pylint's pydantic first).
function ndpylint {
    _ndm_run "$(pwd)" "$_NDM_REPO/nddoctor.sh" run pylint "$@"
}

# Run black inside the machine (self-heals black to its exact pinned version
# first, so machine-side formatting can't drift from the editor venv / CI).
# Run from the collection root so black picks up pyproject.toml (line length 159).
function ndblack {
    _ndm_run "$(pwd)" "$_NDM_REPO/nddoctor.sh" run black "$@"
}

# Run isort inside the machine (self-heals isort to its exact pinned version
# first). Run from the collection root so isort picks up pyproject.toml.
function ndisort {
    _ndm_run "$(pwd)" "$_NDM_REPO/nddoctor.sh" run isort "$@"
}

# Run pytest inside the machine (self-heals pytest's pydantic first — without
# it, the collection silently falls back to the pydantic compat shim).
#
# Runs pytest-ansible in "inject-only" mode (--ansible-unit-inject-only). By
# default pytest-ansible sees galaxy.yml at the collection root and, because the
# repo lives at `…/ansible_collections/cisco/nd` (parent is `ansible_collections`,
# not `collections`), manufactures a `collections/ansible_collections/cisco/nd`
# symlink farm in the repo to make `import ansible_collections.cisco.nd` resolve.
# That farm is untracked, not git-ignored, and symlinks every top-level entry
# (incl. .git/.venv-*), so it shows up as a "symlink loop" that has to be moved
# aside before every rebase. Inject-only skips the farm and instead trusts an
# existing ANSIBLE_COLLECTIONS_PATH — and since the repo already sits under a
# valid collections root, we just point it at the grandparent of
# `ansible_collections/` (e.g. /Users/<you>). ANSIBLE_HOME is redirected to a
# machine-local scratch dir so the galaxy/cache `.ansible` tree stays out of the
# repo too. Verified: full unit suite (1570 tests) passes identically with zero
# artifacts written to the collection.
function ndpytest {
    local cwd acp
    cwd="$(pwd)"
    acp="${cwd%/ansible_collections/*}"        # grandparent of ansible_collections/
    [ "$acp" = "$cwd" ] && acp="$_NDM_HOME"    # fallback if not inside such a tree
    _ndm_run "$cwd" env \
        "ANSIBLE_COLLECTIONS_PATH=$acp" \
        "ANSIBLE_HOME=/tmp/nd-ansible-home" \
        "$_NDM_REPO/nddoctor.sh" run pytest --ansible-unit-inject-only "$@"
}

# Show nd-dev machine status
function ndstatus {
    container machine ls
}

# Quick log check for LaunchAgent boot issues
function ndlogs {
    echo "=== container system ==="
    cat /tmp/container-system.log 2>/dev/null || echo "(empty)"
    cat /tmp/container-system.err 2>/dev/null | grep -v '^$' || true
    echo ""
    echo "=== nd-dev boot ==="
    cat /tmp/container-nd-dev-boot.log 2>/dev/null || echo "(empty)"
    cat /tmp/container-nd-dev-boot.err 2>/dev/null | grep -v '^$' || true
}
