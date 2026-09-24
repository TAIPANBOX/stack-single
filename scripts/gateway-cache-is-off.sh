#!/usr/bin/env bash
#
# Enforces: every service that runs the tokenfuse gateway in serve mode turns
# its semantic response cache off.
#
# WHAT THIS IS ABOUT
#
# With `TOKENFUSE_CACHE` unset, tokenfuse v1.0.4 defaults the cache to
# `shadow` (crates/gateway/src/main.rs:992-997 there). In shadow mode every
# call takes one global mutex, walks up to 10,000 cached entries computing
# cosine similarity, serves nothing, and appends another entry. Measured on
# 2026-09-24 on a 4-core N150 appliance running this launcher's stack: 50
# agents gave 177 calls/s with 403 refusals and CPU 79-92% inside
# SemanticCache::get; with TOKENFUSE_CACHE=off, the same load gave 1102
# calls/s, zero refusals, and no slowdown over time (tokenfuse#319). Decided
# 2026-09-24: this launcher switches the cache off explicitly, ahead of the
# gateway's own default changing.
#
# WHICH SERVICES THIS IS ABOUT
#
# Not every service that runs a tokenfuse binary. `focus-export` runs the same
# image as `tokenfuse-gateway` but its command is `tokenfuse focus-export`, a
# one-shot read of the trace directory; it never opens the cache. `mcp-broker`
# (not present in this compose.yaml today) would be the same shape if it ever
# is: a subcommand, not the bare gateway.
#
# So the subject list is derived from compose.yaml itself, not hand-named:
# every service whose `image:` line names the tokenfuse GATEWAY image
# (`ghcr.io/taipanbox/tokenfuse:`, not `tokenfuse-control-plane:`) and whose
# `command:` is the bare binary with no subcommand,
# `["/usr/local/bin/tokenfuse"]`. A service matching the image but running a
# subcommand is left alone on purpose.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# If no service matches that shape, this says so and fails. A gate whose
# subject list has emptied itself, because the image was renamed or the
# gateway's command line changed shape, must not read as a clean bill of
# health.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "${1:-compose.yaml}" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()

# Two-space-indented service blocks, the same reader record-is-not-on-the-bus.sh
# and bus-has-a-writer.sh use: compose.yaml is hand-written and hand-indented,
# and parsing it with a YAML library would be a dependency the box that runs
# this does not have.
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
    """True when `command:` is the bare gateway binary with no subcommand.
    A one-line JSON-style array is how compose.yaml writes it today; anything
    else (a shell script, extra args, a subcommand) is a different mode."""
    for line in block:
        m = re.match(r'^\s*command:\s*\["/usr/local/bin/tokenfuse"\]\s*$', line)
        if m:
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


subjects = [name for name, block in blocks.items() if is_gateway_image(block) and runs_serve_mode(block)]

if not subjects:
    print("FAIL: no service in compose.yaml both uses the tokenfuse gateway image")
    print("      and runs it with no subcommand, so this gate measured NOTHING.")
    print("      Either the gateway service was renamed or restructured, in which")
    print("      case this check has to move with it, or the shape it looks for")
    print("      (image ghcr.io/taipanbox/tokenfuse:*, command")
    print('      ["/usr/local/bin/tokenfuse"]) no longer matches how compose.yaml')
    print("      writes it. Silence here is not health.")
    sys.exit(1)

problems = 0
for name in sorted(subjects):
    value = env_value(blocks[name], "TOKENFUSE_CACHE")
    if value is None:
        print(f'FAIL: {name} sets no TOKENFUSE_CACHE. Unset, the gateway defaults its')
        print("      semantic cache to shadow mode: one global mutex and up to 10,000")
        print("      cosine-similarity comparisons on every call (tokenfuse#319).")
        problems += 1
        continue
    if value.strip('"').strip("'") != "off":
        print(f'FAIL: {name} sets TOKENFUSE_CACHE: {value}, not "off".')
        problems += 1

if problems:
    print()
    print(f"{problems} problem(s). See CLAUDE.md, the gateway cache invariant.")
    sys.exit(1)

names = ", ".join(sorted(subjects))
print(f'OK: {names} run the tokenfuse gateway in serve mode and set TOKENFUSE_CACHE: "off".')
PY
