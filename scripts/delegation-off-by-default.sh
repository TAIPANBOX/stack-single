#!/usr/bin/env bash
#
# Enforces the delegation plane's own default: a default install is
# byte-for-byte what it was before this plane existed, in the services it
# runs and the environment the gateway gets.
#
# WHAT THIS IS ABOUT
#
# vouchryx sits behind the `delegation` profile, off unless
# WITH_DELEGATION=1 ./install.sh asks for it, the same shape scopyx and
# typryx already take. But a profile alone does not protect a default box:
# what actually matters is that every TOKENFUSE_DELEGATION_* variable
# compose.yaml hands the ALWAYS-ON gateway defaults to EMPTY, because that is
# the value tokenfuse's own chainproof reads as "off"
# (chainproof::base_config_from_env: issuer and jwks_path both empty is fine,
# either one alone aborts the process at startup). A `${VAR:?...}` or a
# literal value on any one of these six would turn every default install
# into a gateway that refuses to start, or worse, one that half-verifies
# while looking the same as before.
#
# So this checks three things, all in compose.yaml and install.sh's own text:
#
#   1. vouchryx sits behind `profiles: ["delegation"]`.
#   2. Every one of the six TOKENFUSE_DELEGATION_* lines on tokenfuse-gateway
#      is `${NAME:-}`, an empty fallback, never `:?` and never a literal.
#   3. install.sh never passes `--profile delegation` except on a line that
#      also names WITH_DELEGATION, so the profile is never brought up
#      unconditionally.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No vouchryx service, no tokenfuse-gateway service, or none of the six
# variables found at all: each is reported and fails, the same as every
# other gate here.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - compose.yaml install.sh <<'PY'
import re
import sys

compose_path, install_path = sys.argv[1:3]
compose = open(compose_path).read()
install = open(install_path).read()

problems = 0


def note(msg):
    global problems
    print("FAIL: " + msg)
    problems += 1


# ---- 1. vouchryx sits behind the delegation profile -------------------------
m = re.search(r"^  vouchryx:\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)", compose, re.M | re.S)
if not m:
    note("no `vouchryx:` service in compose.yaml, so this gate measured nothing about it")
else:
    block = m.group(1)
    if not re.search(r'profiles:\s*\["delegation"\]', block):
        note('vouchryx does not sit behind `profiles: ["delegation"]`: a plain '
             '`docker compose up` would start it on every box')

# ---- 2. the gateway's own six variables default to empty --------------------
gw = re.search(r"^  tokenfuse-gateway:\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)", compose, re.M | re.S)
if not gw:
    note("no `tokenfuse-gateway:` service in compose.yaml, so this gate measured nothing")
else:
    gw_block = gw.group(1)
    NAMES = [
        "TOKENFUSE_DELEGATION_ISSUER",
        "TOKENFUSE_DELEGATION_JWKS",
        "TOKENFUSE_DELEGATION_AUDIENCE",
        "TOKENFUSE_DELEGATION_URL",
        "TOKENFUSE_DELEGATION_REVOCATIONS",
        "TOKENFUSE_DELEGATION_REVOCATIONS_INTERVAL_MS",
    ]
    found = 0
    for name in NAMES:
        m2 = re.search(r"^\s*" + re.escape(name) + r":\s*(.+?)\s*$", gw_block, re.M)
        if not m2:
            note(f"the gateway sets no {name} at all, so this gate measured nothing about it")
            continue
        found += 1
        value = m2.group(1)
        want = "${" + name + ":-}"
        if value != want:
            note(f"the gateway's {name} is {value!r}, not the empty-default form {want!r}: "
                 f"a default install would carry a non-empty value on the always-on gateway")
    if found == 0:
        note("none of the six TOKENFUSE_DELEGATION_* variables were found on "
             "tokenfuse-gateway at all")

# ---- 3. install.sh never brings the profile up unconditionally --------------
# Guarded either on the SAME line (`[ -z "${WITH_DELEGATION:-}" ] ||
# profiles+=(--profile delegation)`, the shape section 3c's pull list and
# UP_PROFILES both use) or by an ENCLOSING `if [ -n "${WITH_DELEGATION:-}" ];
# then ... fi` block with no other `if`/`fi` of its own between the two (the
# shape the two-phase vouchryx bring-up in section 5 uses, several lines
# inside its own `if`). Either is a real guard; neither line printed on its
# own proves nothing was skipped.
install_lines = install.split("\n")


def guarded(idx):
    if "WITH_DELEGATION" in install_lines[idx]:
        return True
    depth = 0
    for j in range(idx - 1, -1, -1):
        line = install_lines[j].strip()
        if re.match(r"^\}?\s*fi\b", line):
            depth += 1
            continue
        if re.match(r"^if\b.*;\s*then\s*$", line):
            if depth == 0:
                return "WITH_DELEGATION" in line
            depth -= 1
    return False


hits = [i for i, ln in enumerate(install_lines) if "--profile delegation" in ln]
if not hits:
    note("install.sh never passes --profile delegation at all, so this gate measured "
         "nothing about how it is gated")
else:
    for i in hits:
        if not guarded(i):
            note(f"install.sh:{i + 1} passes --profile delegation with no WITH_DELEGATION "
                 f"guard on the line or its enclosing if: {install_lines[i].strip()!r}")

if problems:
    print()
    print(f"{problems} problem(s). A default install must be byte-for-byte what it was")
    print("before this plane existed. See CLAUDE.md invariant 15.")
    sys.exit(1)

print('OK: vouchryx sits behind profiles: ["delegation"], every TOKENFUSE_DELEGATION_*')
print("    variable on the gateway defaults to empty, and install.sh only ever passes")
print("    --profile delegation on a WITH_DELEGATION-guarded line.")
PY
