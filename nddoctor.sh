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
# Also verifies the npm-installed markdownlint CLI (issue #14): the collection
# docs call `ndm markdownlint`, which fails on machines built from an image
# that predates the Dockerfile baking markdownlint-cli in.
#
# Also verifies the black / isort formatters (issue #23): the collection docs
# call `ndm black` / `ndm isort`. These are pipx-installed but, unlike the
# pydantic tools, import nothing from the collection — so instead of a pydantic
# inject they are checked against an EXACT version pin (formatter output drifts
# across releases; the machine must match the editor venv / CI).
#
# Usage:
#   nddoctor.sh                       check + heal pytest, pylint, mypy,
#                                     black, isort, markdownlint; report
#   nddoctor.sh run <tool> [args...]  heal <tool>'s venv quietly, then exec it
#
set -u

PIN='pydantic>=2.12.5'
FLOOR='2.12.5'
VENVS="${HOME}/.local/share/pipx/venvs"
# Optional local wheelhouse for when the machine is offline. The machine
# normally has outbound network via the vmnet NAT, but that NAT can silently
# go stale (see README "Troubleshooting"), leaving `pipx inject` unable to
# reach PyPI. Populate it from macOS — the home directory is shared via
# virtiofs, so the same path is visible inside the machine:
#   python3 -m pip download 'pydantic>=2.12.5' --platform manylinux_2_17_aarch64 \
#     --python-version 3.12 --only-binary=:all: -d ~/.cache/nd-wheelhouse
WHEELHOUSE="${ND_WHEELHOUSE:-${HOME}/.cache/nd-wheelhouse}"
# markdownlint-cli pin — keep in sync with the Dockerfile. 0.44.0 is the last
# release that runs on the image's Node 18 (>=0.45.0 needs Node >=20).
MDL_PIN='markdownlint-cli@0.44.0'
# black / isort formatter pins (issue #23) — EXACT, not floored: formatter
# output drifts across releases, so a version mismatch means the machine would
# reformat code differently from the editor venv / CI. Keep in sync with
# nd-provision.sh (BLACK_PIN/ISORT_PIN) and the collection's uv.lock.
BLACK_PIN='black==26.5.1'
ISORT_PIN='isort==8.0.1'
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
        warn "${venv}: pipx venv not found — run: sudo ~/nd-dev-machine/nd-provision.sh \"\$(whoami)\" \"\$HOME\"  (or re-run setup.sh on macOS)"
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
    warn "  if the machine should be online, the vmnet NAT may be stale — see README Troubleshooting"
    return 1
}

# Ensure the markdownlint CLI (npm package markdownlint-cli) is on PATH.
# The Dockerfile bakes it into the image; a machine built from an older image
# won't have it. An npm install is only attempted when the registry is
# reachable (quick curl probe first): with the network down (stale vmnet
# NAT — see README "Troubleshooting") a plain `npm install` burns many
# minutes of TCP retries before failing, and npm's cache can't bridge the
# gap either — packuments cached by macOS npm are not readable by the
# machine's older npm (ENOTCACHED). The offline fix is to install from macOS
# into the virtiofs-shared home (~/.local/bin is first on the machine's
# PATH, and markdownlint-cli is pure JS so one install serves both
# platforms):
#   npm install -g --prefix ~/.local markdownlint-cli@0.44.0
ensure_markdownlint() {
    if command -v markdownlint >/dev/null 2>&1; then
        note "markdownlint: $(markdownlint --version 2>/dev/null) OK"
        return 0
    fi
    if curl -sI --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
        warn "markdownlint: MISSING -> installing ${MDL_PIN} via npm"
        if npm install -g "$MDL_PIN" >/dev/null 2>&1; then
            warn "markdownlint: $(markdownlint --version 2>/dev/null) (healed)"
            return 0
        fi
        warn "markdownlint: ERROR npm install failed"
    else
        warn "markdownlint: MISSING (registry unreachable — skipping npm install)"
        warn "  if the machine should be online, the vmnet NAT may be stale — see README Troubleshooting"
    fi
    warn "markdownlint: install from macOS into the shared home (~/.local/bin is on the machine PATH):"
    warn "  npm install -g --prefix ~/.local '${MDL_PIN}'"
    warn "  or rebuild the image (the Dockerfile now bakes it in)"
    return 1
}

# Print the version of pipx package $1 as recorded in its own venv (empty if
# the venv is absent). Package name == venv name for black / isort.
tool_version() {
    [ -x "${VENVS}/$1/bin/python" ] || return 0
    "${VENVS}/$1/bin/python" \
        -c "import importlib.metadata as m; print(m.version('$1'))" 2>/dev/null
}

# Ensure the pipx-installed formatter $1 (black / isort) is present at the
# EXACT version in pin $2 (e.g. "black==26.5.1"). These import nothing from the
# collection, so there is no pydantic to inject — but their output drifts across
# releases, so a version mismatch is a real defect (the machine reformats code
# differently from the editor venv / CI) and is healed by a forced reinstall.
# Offline: prefer the wheelhouse (same rationale as inject_pydantic — a PyPI
# attempt burns minutes of retries on the stale-NAT machine), fall back to PyPI.
ensure_pinned_tool() {
    tool="$1"
    pin="$2"
    want="${pin#*==}"
    have="$(tool_version "$tool")"
    if [ "$have" = "$want" ]; then
        note "${tool}: ${have} OK"
        return 0
    fi
    if [ -z "$have" ]; then
        warn "${tool}: MISSING -> installing ${pin}"
    else
        warn "${tool}: ${have} != ${want} -> reinstalling ${pin}"
    fi
    if [ -n "$(ls "${WHEELHOUSE}"/*.whl 2>/dev/null)" ]; then
        if pipx install --force "$pin" \
            --pip-args="--no-index --find-links=${WHEELHOUSE}" >/dev/null 2>&1; then
            warn "${tool}: $(tool_version "$tool") (healed)"
            return 0
        fi
        warn "${tool}: wheelhouse install failed (${WHEELHOUSE}) -> trying PyPI"
    fi
    if pipx install --force "$pin" >/dev/null 2>&1; then
        warn "${tool}: $(tool_version "$tool") (healed)"
        return 0
    fi
    warn "${tool}: ERROR install failed — offline? Populate the wheelhouse from macOS:"
    warn "  python3 -m pip download '${pin}' --platform manylinux_2_17_aarch64 --python-version 3.12 --only-binary=:all: -d '${WHEELHOUSE}'"
    warn "  then re-run nddoctor (or: pipx install --force '${pin}')"
    warn "  if the machine should be online, the vmnet NAT may be stale — see README Troubleshooting"
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

# Heal a single tool's venv (venv name == tool name for the pipx three);
# markdownlint is npm-global rather than a pipx venv, so it gets its own case.
heal() {
    case "$1" in
        pytest)
            rc=0
            ensure_pydantic pytest || rc=1
            ensure_pytest_ansible || rc=1
            return $rc ;;
        markdownlint)
            ensure_markdownlint ;;
        black)
            ensure_pinned_tool black "$BLACK_PIN" ;;
        isort)
            ensure_pinned_tool isort "$ISORT_PIN" ;;
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

# ── report mode: check/heal everything, summarise ─────────────────────────────
rc=0
for v in pytest pylint mypy black isort markdownlint; do
    heal "$v" || rc=1
done
if [ "$rc" -eq 0 ]; then
    note "all tools healthy (pydantic >= ${FLOOR}; black/isort pinned; markdownlint on PATH)"
else
    warn "one or more tools need attention (see above)"
fi
exit "$rc"
