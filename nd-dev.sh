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
_NDM_TMPDIR="${_NDM_HOME}/nd-dev-machine/.tmp"
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
    script="${_NDM_TMPDIR}/cmd-$$.sh"
    # Write the script — all variables expanded on macOS side at write time
    cat > "${script}" << NDMSCRIPT
#!/bin/bash
export HOME="${_NDM_HOME}"
export PATH="${_NDM_PATH}"
export USER="${_NDM_USER}"
export LOGNAME="${_NDM_USER}"
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

# Run ansible-test sanity using --docker default (slower, matches CI exactly).
# Use before opening a PR or when debugging a CI-specific failure.
#
# Usage:
#   ndtest-docker                                           → all sanity checks
#   ndtest-docker --test validate-modules
function ndtest-docker {
    _ndm_run "$(pwd)" ansible-test sanity --docker default "$@"
}

# Run ansible-lint inside the machine
function ndlint {
    _ndm_run "$(pwd)" ansible-lint "$@"
}

# Run mypy inside the machine
function ndmypy {
    _ndm_run "$(pwd)" mypy "$@"
}

# Run pylint inside the machine
function ndpylint {
    _ndm_run "$(pwd)" pylint "$@"
}

# Run pytest inside the machine
function ndpytest {
    _ndm_run "$(pwd)" pytest "$@"
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
