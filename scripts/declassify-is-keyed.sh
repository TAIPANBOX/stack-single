#!/usr/bin/env bash
#
# Enforces: every service that runs the tokenfuse gateway in serve mode sets
# TOKENFUSE_DECLASSIFY_KEY from a secret install.sh mints, never from a
# literal and never to an empty default.
#
# WHAT THIS IS ABOUT
#
# `POST /v1/fuse/declassify` is the gateway's release valve for the agent
# firewall: a human reviews a run and the taint label comes off it. It is not
# behind the admin key (TOKENFUSE_ADMIN_KEYS guards five other routes). Its own
# credential is TOKENFUSE_DECLASSIFY_KEY, presented as `x-fuse-declassify-key`,
# and that credential is OPTIONAL in the gateway: with it unset, anything that
# can reach the gateway port can clear a run, and the clearance is recorded
# only as `authenticated: false` (tokenfuse crates/gateway/src/declassify.rs).
# This launcher publishes that port on the operator's chosen bind. No component
# of this estate calls the endpoint, so a key only the operator holds closes it
# by default and breaks nothing.
#
# WHAT IT HOLDS, TWO HALVES
#
# 1. compose.yaml: each gateway service sets TOKENFUSE_DECLASSIFY_KEY to a
#    `${VAR:?...}` interpolation. A literal is a key committed to a public
#    repository, which is no key. `${VAR:-}` or `${VAR:-literal}` is worse: it
#    starts the gateway with the endpoint open (or a known key) on any box where
#    .env lacks the variable.
# 2. install.sh: that same VAR is minted with `add_env_default VAR "$(gen N)"`,
#    the helper every other generated key here uses. Without the second half
#    the first half is a variable nothing sets, and `docker compose up` stops on
#    every box.
#
# WHICH SERVICES THIS IS ABOUT
#
# The subject list is derived from compose.yaml, the same reader
# gateway-cache-is-off.sh uses: a service whose image is the tokenfuse GATEWAY
# image (`ghcr.io/taipanbox/tokenfuse:`) and whose command is the bare binary
# with no subcommand. `focus-export` and `tokenfuse-mcp-broker` run the same
# image on a subcommand and never serve this route, so they are not judged.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No gateway service found, or no install.sh to read, and this says it measured
# nothing and fails. Silence here is not health.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "${1:-compose.yaml}" "${2:-install.sh}" <<'PY'
import os
import re
import sys

compose_path, install_path = sys.argv[1], sys.argv[2]
text = open(compose_path).read()

blocks = {}
section = None
current = None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section = top.group(1)
        current = None
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m and section == "services":
        current = m.group(1)
        blocks[current] = []
        continue
    if section == "services" and current is not None:
        blocks[current].append(line)

GATEWAY_IMAGE = re.compile(r"ghcr\.io/taipanbox/tokenfuse:")


def is_gateway_image(block):
    for line in block:
        m = re.match(r"^\s*image:\s*(.+?)\s*$", line)
        if m and GATEWAY_IMAGE.search(m.group(1)):
            return True
    return False


def runs_serve_mode(block):
    for line in block:
        if re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', line):
            return True
    return False


def env_value(block, key):
    in_env = False
    for line in block:
        if re.match(r"^    environment:\s*$", line):
            in_env = True
            continue
        if in_env:
            if re.match(r"^    \S", line) or not line.strip():
                in_env = False
                continue
            m = re.match(r"^\s*" + re.escape(key) + r":\s*(.+?)\s*$", line)
            if m:
                return m.group(1).strip()
    return None


subjects = [n for n, b in blocks.items() if is_gateway_image(b) and runs_serve_mode(b)]

if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image")
    print("      and runs it with no subcommand, so this gate measured NOTHING.")
    print("      Either the gateway service was renamed or restructured, in which")
    print("      case this check has to move with it, or the shape it looks for")
    print("      (image ghcr.io/taipanbox/tokenfuse:*, command")
    print('      ["/usr/local/bin/tokenfuse"]) no longer matches how compose.yaml')
    print("      writes it. Silence here is not health.")
    sys.exit(1)

if not os.path.isfile(install_path):
    print(f"FAIL: {install_path} is not there, so this gate measured NOTHING about")
    print("      whether the key the compose file reads is ever minted.")
    sys.exit(1)
install = open(install_path).read()

# A required interpolation: ${NAME:?message}. Nothing else is a secret from
# .env: a literal is committed, ${NAME:-...} and ${NAME-...} supply a default
# that exists on a box whose .env never got the key, and a bare ${NAME} is an
# empty string there.
REQUIRED = re.compile(r"^\$\{([A-Z][A-Z0-9_]*):\?[^}]*\}$")

problems = 0
needed_vars = set()
for name in sorted(subjects):
    value = env_value(blocks[name], "TOKENFUSE_DECLASSIFY_KEY")
    if value is None:
        print(f"FAIL: {name} sets no TOKENFUSE_DECLASSIFY_KEY. Unset, POST")
        print("      /v1/fuse/declassify is open to anything that reaches the gateway")
        print("      port: it clears a run and records only authenticated: false.")
        problems += 1
        continue
    bare = value.strip('"').strip("'")
    m = REQUIRED.match(bare)
    if not m:
        print(f"FAIL: {name} sets TOKENFUSE_DECLASSIFY_KEY: {value}, which is not a")
        print("      required secret interpolation ${VAR:?...}. A literal is committed to")
        print("      a public repository, and a :- or bare default leaves the endpoint")
        print("      open (or on a known key) on a box whose .env lacks the variable.")
        problems += 1
        continue
    needed_vars.add((name, m.group(1)))

for name, var in sorted(needed_vars):
    mint = re.search(
        r"^add_env_default\s+" + re.escape(var) + r"\s+(.+?)\s*$", install, re.M
    )
    if not mint:
        print(f"FAIL: {name} reads {var} from .env, but {install_path} never mints it")
        print(f"      with add_env_default {var}. Compose would stop on every box.")
        problems += 1
        continue
    arg = mint.group(1)
    if not re.match(r'^"\$\(gen [0-9]+\)"$', arg):
        print(f"FAIL: {install_path} mints {var} as {arg}, not with the gen helper.")
        print("      A key that is not random per install is a published key.")
        problems += 1

if problems:
    print()
    print(f"{problems} problem(s). See CLAUDE.md, the declassify key invariant.")
    sys.exit(1)

names = ", ".join(sorted(subjects))
vars_ = ", ".join(sorted({v for _, v in needed_vars}))
print(f"OK: {names} set TOKENFUSE_DECLASSIFY_KEY from {vars_}, which install.sh mints with gen.")
PY
