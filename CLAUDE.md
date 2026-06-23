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
Use `ndtest` (defined in `~/nd-dev-machine/aliases/nd-dev.sh`) or the
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

---

## Linting and Type Checking

```bash
# ansible-lint
ndlint plugins/

# pylint
ndpylint plugins/modules/nd_interface_loopback.py

# mypy
ndmypy plugins/modules/
```

---

## Unit Tests and pydantic

Run the collection's pytest unit tests inside the machine with `ndpytest`
(e.g. `ndpytest tests/unit/...`).

The `pytest`, `pylint`, and `mypy` tools live in **isolated pipx venvs**, each
with `pydantic` injected and capped to `pydantic>=2.11,<2.12` (matches the
collection pin / issue #344). Do NOT rely on a system/user pydantic — it is not
visible inside a pipx venv.

The `ndpytest` / `ndmypy` / `ndpylint` wrappers self-heal their own venv on
every run (via `nddoctor.sh run <tool>`), so a drifted/missing pydantic is
re-injected automatically before the tool runs. To check/heal all three venvs
on demand (e.g. after a rebuild), run `nddoctor`.

If unit tests behave oddly (e.g. `model_post_init` never fires, orchestrator
tests passing — or failing — for the wrong reason), run `nddoctor` to confirm
the venvs are healthy. Manual fallback:

```bash
ndm pipx inject pytest 'pydantic>=2.11,<2.12'
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

---

## Machine Management

```bash
container machine ls                    # check status
container machine stop nd-dev          # stop
container machine run -n nd-dev        # start / interactive shell
ndlogs                                  # check LaunchAgent boot logs
```

---

## Notes for Claude Code

- When asked to run tests, use the `ndtest` wrapper or the explicit
  `container machine run` form shown above.
- When asked to lint or type-check, use `ndlint`, `ndmypy`, or `ndpylint`.
- File paths are the same on macOS and inside the machine — use `$(pwd)`
  to preserve the caller's working directory.
- Do not install Python packages on macOS for this collection; install
  inside the machine using `ndm pip3 install --user <pkg>`.