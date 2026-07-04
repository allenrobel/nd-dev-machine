# Cisco ND Ansible Collection — Claude Code Instructions

## Environment

This collection is developed on macOS (Apple Silicon) with test execution
delegated to an Ubuntu 24.04 **container machine** named `nd-dev`, running
via Apple's `container` tool. The collection path is identical inside and
outside the machine — no path translation needed.

- **Edit:** VS Code / any macOS editor (native filesystem)
- **Test / lint / type-check:** inside `nd-dev` (real Linux, native Podman)
- **Collection root:** `~/ansible_collections/cisco/nd`

---

## Running Tests

All `ansible-test` invocations must run inside the nd-dev machine.
Use `ndtest` (defined in `~/nd-dev-machine/nd-dev.sh`) or the
explicit form:

```bash
# Run all sanity checks
ndtest

# Run a specific sanity test
ndtest --test validate-modules

# Target a specific file
ndtest --test validate-modules plugins/modules/nd_interface_loopback.py

# Explicit form (without alias)
container machine run -n nd-dev -- bash -lc \
  "cd '$(pwd)' && ansible-test sanity --venv <args>"
```

`ANSIBLE_TEST_PREFER_PODMAN=1` is set system-wide inside the machine.

To get close to CI (full Docker container with all Python interpreters,
slower), use `ndtest-docker` (e.g. `ndtest-docker --test validate-modules`)
— worth doing before a PR. Note it still runs the machine's single
ansible-core version, not the CI matrix; see the README section
"Local testing vs GitHub CI" for the remaining gaps.

---

## Linting and Type Checking

`ndlint` passes `--offline` automatically: the machine normally has outbound
network, but a Tailscale exit node on the host silently breaks its vmnet NAT
(see the README "Troubleshooting" section) — and when it's broken,
ansible-lint's Galaxy pre-flight fails and lets it exit 0 *without running
the rules*. Deps are
already provisioned via uv.lock/pipx, so offline never loses anything here —
no need to add `--offline` by hand.

```bash
# ansible-lint
ndlint plugins/

# pylint
ndpylint plugins/modules/nd_interface_loopback.py

# mypy
ndmypy plugins/modules/

# markdownlint (baked into the machine image via npm)
ndm markdownlint README.md
```

---

## Unit Tests and pydantic

Run the collection's pytest unit tests inside the machine with `ndpytest`
(e.g. `ndpytest tests/unit/...`).

`ndpytest` runs pytest-ansible with `--ansible-unit-inject-only` (and
`ANSIBLE_COLLECTIONS_PATH` set to the collections root) so it does **not** write
a `collections/` symlink farm into the collection root — keep that flag. Both
`collections/` and ansible-lint's `.ansible/` are regenerable and globally
git-ignored (`setup.sh` STEP 9 → `~/.config/git/ignore`), so they never need
moving aside before a rebase. ansible-lint hardcodes `Runtime(isolated=True)`,
so its `.ansible/` cannot be relocated via `ANSIBLE_HOME`.

The `pytest`, `pylint`, and `mypy` tools live in **isolated pipx venvs**, each
with `pydantic` injected and floored at `pydantic>=2.12.5` (matches the
collection's `requirements.txt` pin; the old `<2.12` cap for issue #344 was
dropped after CiscoDevNet/ansible-nd#377). Do NOT rely on a system/user
pydantic — it is not visible inside a pipx venv.

The `ndpytest` / `ndmypy` / `ndpylint` wrappers self-heal their own venv on
every run (via `nddoctor.sh run <tool>`), so a drifted/missing pydantic is
re-injected automatically before the tool runs. To check/heal all three venvs
on demand (e.g. after a rebuild), run `nddoctor`. Healing installs from the
local wheelhouse `~/.cache/nd-wheelhouse` when it has wheels (populate it
from macOS with `pip download`; see the README "Python CLI tooling"
section), falling back to PyPI otherwise — the wheelhouse keeps healing
working when the machine's NAT has been broken by a Tailscale exit node
(see the README "Troubleshooting" section).

If unit tests behave oddly (e.g. `model_post_init` never fires, orchestrator
tests passing — or failing — for the wrong reason), run `nddoctor` to confirm
the venvs are healthy. Manual fallback:

```bash
ndm pipx inject pytest 'pydantic>=2.12.5'
```

This is provisioned by `first-boot.sh` and kept healthy by `nddoctor.sh`; see
the README "Python CLI tooling" section for details.

---

## Running a Single Command Inside the Machine

```bash
ndm <command>          # e.g.  ndm python3 --version
ndm                    # interactive shell
```

---

## Editing Workflow

Edit files normally on macOS. The container machine sees the same files
instantly via virtiofs — no sync step, no copy step.

Do NOT `pip install` or run `ansible-test` directly on macOS for this
collection. Always delegate to the machine to keep the environment consistent
with CI.

The one sanctioned macOS-side venv is the **editor venv**
`.venv-Darwin-arm64`, which VS Code / Pylance points at for IntelliSense.
`setup.sh` **STEP 8** provisions it on the host by running `uv sync` against
`pyproject.toml` + `uv.lock` (full locked dev set, incl. `ansible-core`). This
is editor import-resolution only — it is never used to run tests, so it does
not conflict with the rule above. If imports stop resolving in the editor,
re-run `setup.sh` (STEP 8 is idempotent) or, from the collection root:

```bash
VENV=".venv-$(uname -s)-$(uname -m)"          # .venv-Darwin-arm64
UV_PROJECT_ENVIRONMENT="$VENV" uv sync
```

---

## Machine Management

```bash
container machine ls                    # check status  (alias: ndstatus)
container machine stop nd-dev          # stop
container machine run -n nd-dev        # start / interactive shell
ndlogs                                  # check LaunchAgent boot logs
```

If network-dependent commands inside the machine hang (e.g. `ndtest` stuck
at "Installing requirements"), the vmnet NAT is likely broken — the known
trigger is a Tailscale exit node active on the host (deactivating it is not
enough; the NAT stays poisoned). See the README "Troubleshooting" section
for the diagnosis and the container-system restart (exit node off) that
fixes it.

A second, distinct failure mode exists on managed (MDM/EDR) hosts: DNS is
refused (`Temporary failure resolving`) while raw-IP traffic works, because
endpoint security blocks mDNSResponder's DNS proxy on the NAT gateway. The
fix is `ND_GUEST_DNS=<ip> bash setup.sh`, which points the builder and the
machine at an external resolver — see the README "Troubleshooting" section
("Guest DNS refused").

---

## Notes for Claude Code

- When asked to run tests, use the `ndtest` wrapper or the explicit
  `container machine run` form shown above.
- When asked to lint or type-check, use `ndlint`, `ndmypy`, or `ndpylint`.
  For markdown files, use `ndm markdownlint <file>.md`.
- File paths are the same on macOS and inside the machine — use `$(pwd)`
  to preserve the caller's working directory.
- Do not install Python packages on macOS for this collection; install
  inside the machine using
  `ndm pip3 install --user --break-system-packages <pkg>`
  (Ubuntu 24.04 enforces PEP 668, so bare `--user` is rejected). The sole
  exception is the macOS editor venv `.venv-Darwin-arm64` (IntelliSense
  only) — refresh it with `setup.sh` STEP 8 / `uv sync`, never by hand.
