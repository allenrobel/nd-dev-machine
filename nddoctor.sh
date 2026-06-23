#!/bin/sh
# nddoctor.sh — verify (and self-heal) the pipx tool venvs used for the
# cisco/nd Ansible collection. Each of pytest / pylint / mypy must have
# pydantic at 2.11.x (capped <2.12, issue #344). Without it, pytest silently
# falls back to the collection's pydantic compat shim (model_post_init never
# fires) and the orchestrator unit tests fail — or worse, pass — for the wrong
# reason. See README.md "Python CLI tooling (pipx + capped pydantic)".
#
# Runs INSIDE the nd-dev machine; pipx venvs live under
# $HOME/.local/share/pipx/venvs. Invoked via the `nddoctor`, `ndpytest`,
# `ndmypy`, and `ndpylint` shell functions in nd-dev.sh.
#
# Usage:
#   nddoctor.sh                       check + heal pytest, pylint, mypy; report
#   nddoctor.sh run <tool> [args...]  heal <tool>'s venv quietly, then exec it
#
set -u

PIN='pydantic>=2.11,<2.12'
VENVS="${HOME}/.local/share/pipx/venvs"
QUIET=0   # set to 1 in `run` mode: only speak when an action is taken

note() { [ "$QUIET" -eq 1 ] || echo "[nddoctor] $*" >&2; }
warn() { echo "[nddoctor] $*" >&2; }

# Print the pydantic version installed in venv $1 (empty if absent).
pydantic_version() {
    "${VENVS}/$1/bin/python" -c 'import pydantic; print(pydantic.VERSION)' 2>/dev/null
}

# Ensure venv $1 has a capped pydantic; re-inject if missing or out of range.
# Returns 0 if healthy/healed, 1 if it could not be fixed.
ensure_pydantic() {
    venv="$1"
    if [ ! -x "${VENVS}/${venv}/bin/python" ]; then
        warn "${venv}: pipx venv not found — run setup.sh / first-boot.sh"
        return 1
    fi
    ver="$(pydantic_version "$venv")"
    case "$ver" in
        2.11.*)
            note "${venv}: pydantic ${ver} OK"
            return 0 ;;
        '')
            warn "${venv}: pydantic MISSING -> injecting ${PIN}" ;;
        *)
            warn "${venv}: pydantic ${ver} out of range -> re-injecting ${PIN}" ;;
    esac
    if pipx inject "$venv" "$PIN" >/dev/null 2>&1; then
        warn "${venv}: pydantic $(pydantic_version "$venv") (healed)"
        return 0
    fi
    warn "${venv}: ERROR pipx inject failed — fix manually: pipx inject ${venv} '${PIN}'"
    return 1
}

# pytest additionally needs the pytest-ansible plugin in its venv.
ensure_pytest_ansible() {
    [ -x "${VENVS}/pytest/bin/python" ] || return 1
    if "${VENVS}/pytest/bin/python" -c 'import pytest_ansible' 2>/dev/null; then
        return 0
    fi
    warn "pytest: pytest-ansible MISSING -> injecting"
    pipx inject pytest pytest-ansible >/dev/null 2>&1 \
        || { warn "pytest: ERROR pytest-ansible inject failed"; return 1; }
}

# Heal a single tool's venv (venv name == tool name for all three).
heal() {
    case "$1" in
        pytest)
            rc=0
            ensure_pydantic pytest || rc=1
            ensure_pytest_ansible || rc=1
            return $rc ;;
        *)
            ensure_pydantic "$1" ;;
    esac
}

# ── run mode: heal one venv quietly, then exec the tool ────────────────────────
if [ "${1:-}" = "run" ]; then
    [ $# -ge 2 ] || { warn "usage: nddoctor.sh run <tool> [args...]"; exit 2; }
    QUIET=1
    tool="$2"
    shift 2
    heal "$tool" || true   # a heal warning must not block the run
    exec "$tool" "$@"
fi

# ── report mode: check/heal all three, summarise ──────────────────────────────
rc=0
for v in pytest pylint mypy; do
    heal "$v" || rc=1
done
if [ "$rc" -eq 0 ]; then
    note "all tool venvs healthy (pydantic 2.11.x)"
else
    warn "one or more venvs need attention (see above)"
fi
exit "$rc"
