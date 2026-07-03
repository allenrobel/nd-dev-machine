#!/bin/sh
# nddoctor.sh — verify (and self-heal) the pipx tool venvs used for the
# cisco/nd Ansible collection. Each of pytest / pylint / mypy must have
# pydantic >= 2.12.5 (matches the collection's requirements.txt pin; the old
# <2.12 cap for issue #344 was dropped after CiscoDevNet/ansible-nd#377).
# Without it, pytest silently falls back to the collection's pydantic compat
# shim (model_post_init never fires) and the orchestrator unit tests fail — or
# worse, pass — for the wrong reason. See README.md "Python CLI tooling
# (pipx + pinned pydantic)".
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

PIN='pydantic>=2.12.5'
FLOOR='2.12.5'
VENVS="${HOME}/.local/share/pipx/venvs"
# Optional local wheelhouse for offline machines (the nd-dev machine usually
# has no outbound network, so a plain `pipx inject` cannot reach PyPI).
# Populate it from macOS — the home directory is shared via virtiofs, so the
# same path is visible inside the machine:
#   python3 -m pip download 'pydantic>=2.12.5' --platform manylinux_2_17_aarch64 \
#     --python-version 3.12 --only-binary=:all: -d ~/.cache/nd-wheelhouse
WHEELHOUSE="${ND_WHEELHOUSE:-${HOME}/.cache/nd-wheelhouse}"
QUIET=0   # set to 1 in `run` mode: only speak when an action is taken

note() { [ "$QUIET" -eq 1 ] || echo "[nddoctor] $*" >&2; }
warn() { echo "[nddoctor] $*" >&2; }

# Print the pydantic version installed in venv $1 (empty if absent).
pydantic_version() {
    "${VENVS}/$1/bin/python" -c 'import pydantic; print(pydantic.VERSION)' 2>/dev/null
}

# Return 0 if venv $1's pydantic satisfies the >= FLOOR requirement.
pydantic_in_range() {
    "${VENVS}/$1/bin/python" -c '
import re, sys
import pydantic
ver = tuple(int(x) for x in re.findall(r"\d+", pydantic.VERSION)[:3])
floor = tuple(int(x) for x in sys.argv[1].split("."))
sys.exit(0 if ver >= floor else 1)
' "$FLOOR" 2>/dev/null
}

# Inject $PIN into venv $1. When the wheelhouse has wheels, try it first: on
# the offline machine a PyPI attempt burns minutes of pip retries before
# failing, while the wheelhouse succeeds (or fails) instantly. Fall back to a
# normal PyPI inject either way, so an online machine still heals when the
# wheelhouse is stale.
inject_pydantic() {
    venv="$1"
    if [ -n "$(ls "${WHEELHOUSE}"/*.whl 2>/dev/null)" ]; then
        pipx inject "$venv" "$PIN" \
            --pip-args="--no-index --find-links=${WHEELHOUSE}" \
            >/dev/null 2>&1 && return 0
        warn "${venv}: wheelhouse inject failed (${WHEELHOUSE}) -> trying PyPI"
    fi
    pipx inject "$venv" "$PIN" >/dev/null 2>&1
}

# Ensure venv $1 has pydantic at or above the floor; (re-)inject if missing
# or too old. Returns 0 if healthy/healed, 1 if it could not be fixed.
ensure_pydantic() {
    venv="$1"
    if [ ! -x "${VENVS}/${venv}/bin/python" ]; then
        warn "${venv}: pipx venv not found — run setup.sh / first-boot.sh"
        return 1
    fi
    ver="$(pydantic_version "$venv")"
    if [ -n "$ver" ] && pydantic_in_range "$venv"; then
        note "${venv}: pydantic ${ver} OK"
        return 0
    fi
    if [ -z "$ver" ]; then
        warn "${venv}: pydantic MISSING -> injecting ${PIN}"
    else
        warn "${venv}: pydantic ${ver} out of range -> re-injecting ${PIN}"
    fi
    if inject_pydantic "$venv"; then
        warn "${venv}: pydantic $(pydantic_version "$venv") (healed)"
        return 0
    fi
    warn "${venv}: ERROR inject failed — offline? Populate the wheelhouse from macOS:"
    warn "  python3 -m pip download '${PIN}' --platform manylinux_2_17_aarch64 --python-version 3.12 --only-binary=:all: -d '${WHEELHOUSE}'"
    warn "  then re-run nddoctor (or: pipx inject ${venv} '${PIN}')"
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
    note "all tool venvs healthy (pydantic >= ${FLOOR})"
else
    warn "one or more venvs need attention (see above)"
fi
exit "$rc"
