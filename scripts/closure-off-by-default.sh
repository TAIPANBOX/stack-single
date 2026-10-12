#!/usr/bin/env bash
#
# Enforces invariant 26: closing a retained reservation is off by default, and
# when WITH_CLOSURE=1 turns it on, the gateway and the console get the same
# secret bytes and nothing prints them.
#
# WHAT THIS IS ABOUT
#
# The gateway (TOKENFUSE_CLOSURE_SECRET) and the console
# (GENARYX_CLOSURE_SECRET_FILE) both read an empty value as "off". A default
# box stays exactly as it was only if compose hands both an empty default,
# never a `:?` and never a literal. When the operator asks for it, install.sh
# writes the one secret twice: into .env for the gateway, and into
# ./closure/secret for the console. The two must match byte for byte. The
# console trims whitespace from the file and the gateway does not, so the file
# is written with printf '%s' and never with a trailing newline.
#
# So this checks, in compose.yaml and install.sh's own text:
#
#   1. the gateway's TOKENFUSE_CLOSURE_SECRET is `${CLOSURE_SECRET:-}`;
#   2. the console's GENARYX_CLOSURE_SECRET_FILE is `${CLOSURE_SECRET_FILE:-}`,
#      and the console mounts ./closure read only at /run/closure;
#   3. every `add_env_default CLOSURE_SECRET...` sits on a WITH_CLOSURE line or
#      inside an `if` that names WITH_CLOSURE;
#   4. every line that expands the secret is its length check or its
#      printf '%s' into closure/secret.tmp: nothing prints it, and nothing
#      writes it with a newline.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway, no console, either variable missing, no mint in install.sh, or
# no write of the file: each is reported and fails, as every gate here does.
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


def service(name):
    m = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)",
                  compose, re.M | re.S)
    return m.group(1) if m else None


def env_value(block, name):
    m = re.search(r"^\s*" + re.escape(name) + r":\s*(.+?)\s*$", block, re.M)
    return m.group(1) if m else None


# ---- 1. the gateway's secret defaults to empty -------------------------------
gw = service("tokenfuse-gateway")
if gw is None:
    note("no `tokenfuse-gateway:` service in compose.yaml, so this gate measured nothing about it")
else:
    value = env_value(gw, "TOKENFUSE_CLOSURE_SECRET")
    want = "${CLOSURE_SECRET:-}"
    if value is None:
        note("the gateway sets no TOKENFUSE_CLOSURE_SECRET at all, so this gate measured nothing about it")
    elif value != want:
        note(f"the gateway's TOKENFUSE_CLOSURE_SECRET is {value!r}, not the empty-default form "
             f"{want!r}: a default install would carry a closure secret, or refuse to start")

# ---- 2. the console's file defaults to empty, and the file reaches it --------
con = service("console")
if con is None:
    note("no `console:` service in compose.yaml, so this gate measured nothing about it")
else:
    value = env_value(con, "GENARYX_CLOSURE_SECRET_FILE")
    want = "${CLOSURE_SECRET_FILE:-}"
    if value is None:
        note("the console sets no GENARYX_CLOSURE_SECRET_FILE at all, so this gate measured "
             "nothing about it")
    elif value != want:
        note(f"the console's GENARYX_CLOSURE_SECRET_FILE is {value!r}, not the empty-default "
             f"form {want!r}")
    if not re.search(r"^\s*-\s*\./closure:/run/closure:ro\s*$", con, re.M):
        note("the console does not mount ./closure read only at /run/closure, so the file "
             "install.sh writes never reaches it")

# ---- 3. the secret is minted only when asked for -----------------------------
lines = install.split("\n")


def guarded(idx):
    if "WITH_CLOSURE" in lines[idx]:
        return True
    depth = 0
    for j in range(idx - 1, -1, -1):
        line = lines[j].strip()
        if re.match(r"^\}?\s*fi\b", line):
            depth += 1
            continue
        if re.match(r"^if\b.*;\s*then\s*$", line):
            if depth == 0:
                return "WITH_CLOSURE" in line
            depth -= 1
    return False


mints = [i for i, ln in enumerate(lines)
         if re.match(r"^\s*add_env_default\s+CLOSURE_SECRET(_FILE)?\b", ln)]
if not mints:
    note("install.sh never writes CLOSURE_SECRET into .env, so this gate measured nothing "
         "about how it is guarded")
for i in mints:
    if not guarded(i):
        note(f"install.sh:{i + 1} writes a closure setting with no WITH_CLOSURE guard on the "
             f"line or its enclosing if: {lines[i].strip()!r}")

# ---- 4. the secret is only checked and written, never printed ----------------
writes = 0
for i, ln in enumerate(lines):
    if not re.search(r"\$\{?#?closure_secret\b", ln):
        continue
    s = ln.strip()
    rest = s.replace("${#closure_secret}", "")
    if "${#closure_secret}" in s and not re.search(r"\$\{?closure_secret\b", rest):
        continue
    if re.search(r"printf '%s' \"\$closure_secret\" >closure/secret\.tmp", s):
        writes += 1
        continue
    if "printf" in s:
        note(f"install.sh:{i + 1} writes the closure secret with a format other than "
             f"printf '%s', so the console's bytes would differ from the gateway's: {s!r}")
    else:
        note(f"install.sh:{i + 1} expands the closure secret outside its length check and its "
             f"write to the file, which can print it: {s!r}")
if writes == 0:
    note("install.sh never writes the closure secret to closure/secret.tmp with printf '%s', "
         "so this gate measured nothing about the file")

if problems:
    print()
    print(f"{problems} problem(s). Closing retained reservations is off unless asked for, and")
    print("then the gateway and the console hold the same bytes. See CLAUDE.md invariant 26.")
    sys.exit(1)

print("OK: the gateway's TOKENFUSE_CLOSURE_SECRET and the console's GENARYX_CLOSURE_SECRET_FILE")
print("    default to empty, the console mounts ./closure at /run/closure, install.sh mints the")
print("    secret only under WITH_CLOSURE, and writes it with printf '%s' and nowhere else.")
PY
