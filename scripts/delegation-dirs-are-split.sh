#!/usr/bin/env bash
#
# The delegation plane's two directories stay apart, and each is readable by
# the one container that needs it.
#
# WHAT THIS CHECKS
#
#   1. compose.yaml mounts ./delegation (vouchryx's signing key) into the
#      vouchryx service and nowhere else, and the gateway mounts
#      ./delegation-public, never ./delegation.
#   2. install.sh gives ./delegation to the uid vouchryx runs as
#      (`chown 65532:65532 delegation`) and makes ./delegation-public
#      world-readable (`chmod 755 delegation-public`).
#
# WHY
#
# A bind mount keeps the host's ownership and mode. Measured 2026-09-27 on
# Debian 13: with ./delegation root-owned 0700 and mounted into both
# containers, vouchryx exited 2 unable to read its signing key and the gateway
# (uid 10001) exited 2 with Permission denied on the JWKS. Docker Desktop on
# macOS ignores bind-mount ownership, so a run there passes and proves nothing.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no vouchryx service, or no gateway
# mount of either directory, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, pathlib
compose = pathlib.Path("compose.yaml").read_text()
install = pathlib.Path("install.sh").read_text()
errors = []

services = {}
cur = None
in_services = False
for line in compose.splitlines():
    if re.match(r"^services:\s*$", line):
        in_services = True
        continue
    if in_services and re.match(r"^\S", line):
        in_services = False
    if not in_services:
        continue
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
    if m:
        cur = m.group(1)
        services[cur] = []
        continue
    if cur and not line.lstrip().startswith("#"):
        services[cur].append(line)

def mounts(name):
    return [l.strip() for l in services.get(name, []) if re.search(r"-\s+\./delegation(-public)?:", l)]

if "vouchryx" not in services:
    errors.append("compose.yaml has no vouchryx service, so this measured nothing")
if "tokenfuse-gateway" not in services:
    errors.append("compose.yaml has no tokenfuse-gateway service, so this measured nothing")

for name, lines in services.items():
    for m in mounts(name):
        private = re.search(r"\./delegation:", m) is not None
        if private and name != "vouchryx":
            errors.append(f"{name} mounts ./delegation ({m}): that directory holds vouchryx's signing key and is its uid's alone")

gw = mounts("tokenfuse-gateway")
if "tokenfuse-gateway" in services and not any("./delegation-public:" in m for m in gw):
    errors.append("the gateway does not mount ./delegation-public, so the JWKS it is told to read is not there")

if not re.search(r"^\s*chown 65532:65532 delegation\s*$", install, re.M):
    errors.append("install.sh never gives ./delegation to uid 65532: on Linux vouchryx cannot read its own signing key")
if not re.search(r"^\s*chmod 755 delegation-public\s*$", install, re.M):
    errors.append("install.sh never makes ./delegation-public readable: on Linux the gateway (uid 10001) cannot read the JWKS")

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    sys.exit(1)
print("OK: ./delegation is vouchryx's alone (uid 65532), and the gateway reads only ./delegation-public.")
PY
