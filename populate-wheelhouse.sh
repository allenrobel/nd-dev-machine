#!/bin/sh
# populate-wheelhouse.sh — download the Linux wheels that nddoctor.sh installs
# when the nd-dev machine is offline, into the local wheelhouse at
# ~/.cache/nd-wheelhouse.
#
# Run this from macOS. The home directory is shared into the machine via
# virtiofs, so the same path is visible inside — nddoctor (which runs INSIDE
# the machine) then heals the pipx tool venvs and the black/isort formatters
# from these wheels without reaching PyPI. That matters because the vmnet NAT
# can silently go stale (a Tailscale exit node on the host is the known
# trigger; see README "Troubleshooting"), leaving a plain `pipx inject` unable
# to reach the network.
#
# The package pins are read straight from nddoctor.sh (PIN / BLACK_PIN /
# ISORT_PIN) so there is ONE source of truth: bump them there (and in
# nd-provision.sh / the collection's uv.lock) and this script follows. This is
# why the wheelhouse covers every tool nddoctor heals — pydantic for the
# pytest / pylint / mypy venvs, plus the two formatters — not just pydantic.
#
# Usage:
#   ./populate-wheelhouse.sh                    # -> ~/.cache/nd-wheelhouse
#   ND_WHEELHOUSE=/some/path ./populate-wheelhouse.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
NDDOCTOR="${HERE}/nddoctor.sh"
[ -r "$NDDOCTOR" ] || { echo "ERROR: cannot read ${NDDOCTOR}" >&2; exit 1; }

# Pull the canonical pins from nddoctor.sh without executing its heal logic:
# eval only the three simple assignments, nothing else in the file.
eval "$(grep -E "^(PIN|BLACK_PIN|ISORT_PIN)=" "$NDDOCTOR")"
: "${PIN:?could not read PIN from nddoctor.sh}"
: "${BLACK_PIN:?could not read BLACK_PIN from nddoctor.sh}"
: "${ISORT_PIN:?could not read ISORT_PIN from nddoctor.sh}"

WHEELHOUSE="${ND_WHEELHOUSE:-${HOME}/.cache/nd-wheelhouse}"

# Target the nd-dev machine's interpreter, NOT the macOS host's: Ubuntu 24.04
# on Apple Silicon is aarch64 / CPython 3.12. --only-binary=:all: keeps this to
# prebuilt wheels so nothing gets built for macOS by mistake.
PLATFORM='manylinux_2_17_aarch64'
PYVER='3.12'

mkdir -p "$WHEELHOUSE"
echo "Populating ${WHEELHOUSE} for ${PLATFORM} / py${PYVER}:"
echo "  ${PIN}  ${BLACK_PIN}  ${ISORT_PIN}"
echo

python3 -m pip download "$PIN" "$BLACK_PIN" "$ISORT_PIN" \
    --platform "$PLATFORM" --python-version "$PYVER" \
    --only-binary=:all: -d "$WHEELHOUSE"

echo
echo "Wheelhouse now holds $(ls "$WHEELHOUSE"/*.whl 2>/dev/null | wc -l | tr -d ' ') wheels."
echo "Run 'nddoctor' inside the machine to heal the tool venvs from them."
