#!/usr/bin/env bash
# Enforces that Docker watches every service that exposes a health path, and only
# those that can be watched with a tool their image already has.
#
# WHY
#
# The installer checks /healthz on four services and then exits; nothing watched
# them afterwards, and compose had one healthcheck (policy-db). A service that goes
# bad after the install is then `restart: unless-stopped` and silently reported
# healthy by `docker compose ps`. Each service the installer probes at a health
# path gets a healthcheck that asks the same question, from inside the container.
#
# The images on this list have no curl or wget, and some have no shell at all. A
# healthcheck needs a tool in the image, and this repository does not add tools to
# images it does not build. So the four that ship bash probe with bash's own
# /dev/tcp, and the distroless ones are left out on purpose: they are named here with
# the reason, so that a healthcheck added to one of them fails this gate until the
# list is changed on purpose.
#
# WHAT IT CHECKS
#
#   1. EXPECT: each of the four services has a healthcheck whose command opens
#      127.0.0.1 on the port the service listens on, asks for /healthz, and reads the
#      status line with grep, and which has an interval.
#   2. EXEMPT: each distroless service has no healthcheck at all.
#   3. The port and the path are the ones the installer's own checks ask for: the
#      installer contains each `:PORT/healthz` (a check that moved to another port
#      would otherwise leave the healthcheck watching a port nothing answers on).
#   4. Refuses to report OK when compose.yaml has no services to read.
#
# (teeth cases: scripts/gates-have-teeth.sh, "health-checks-are-declared: ...")
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
import sys

EXPECT = {
    "tokenfuse-cloud": "8080",
    "tokenfuse-gateway": "4100",
    "tokenfuse-gateway-openai": "4100",
    "console": "7420",
}
EXEMPT = {
    "wardryx": "distroless: no shell, curl or wget (its health paths are /readyz and /healthz)",
    "idryx": "distroless: no shell, curl or wget",
    "typryx-wardryx-proxy": "typryx image, distroless: no shell, curl or wget",
    "vouchryx": "distroless: no shell, curl or wget",
}

problems = []
try:
    lines = open("compose.yaml").read().split("\n")
except OSError:
    print("FAIL: compose.yaml is not there, so no healthcheck can be read. Measured NOTHING.")
    sys.exit(1)

# The services: block, one entry per two-space key under it.
services = {}
current = None
inside = False
for line in lines:
    if re.match(r"^services:\s*$", line):
        inside = True
        continue
    if inside and re.match(r"^\S", line):
        break
    if not inside:
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m:
        current = m.group(1)
        services[current] = []
        continue
    if current is not None:
        services[current].append(line)

if len(services) < 5:
    print(f"FAIL: compose.yaml has {len(services)} service(s) under services:, so this gate measured NOTHING.")
    sys.exit(1)

installer = open("install.sh").read()
for name, port in EXPECT.items():
    body = services.get(name)
    if body is None:
        problems.append(f"{name}: no such service in compose.yaml")
        continue
    text = "\n".join(body)
    if "    healthcheck:" not in text:
        problems.append(f"{name}: no healthcheck, so Docker does not watch it")
        continue
    test = [l for l in body if l.lstrip().startswith("test:")]
    if not test:
        problems.append(f"{name}: healthcheck has no test")
        continue
    t = test[0]
    if f"/dev/tcp/127.0.0.1/{port}" not in t:
        problems.append(f"{name}: healthcheck does not probe 127.0.0.1:{port}, the port it listens on")
    if "/healthz" not in t:
        problems.append(f"{name}: healthcheck does not ask for /healthz")
    if "grep -q" not in t:
        problems.append(f"{name}: healthcheck does not read the status line, so any reply would pass")
    if "interval:" not in text:
        problems.append(f"{name}: healthcheck has no interval")
    if f":{port}/healthz" not in installer:
        problems.append(f"{name}: install.sh no longer asks for :{port}/healthz, so this healthcheck watches a path nothing checks")

for name, reason in EXEMPT.items():
    body = services.get(name)
    if body is None:
        problems.append(f"{name}: no such service in compose.yaml ({reason})")
        continue
    if any(l.startswith("    healthcheck:") for l in body):
        problems.append(f"{name} is {reason}, and has a healthcheck: a tool it does not have, so this must be removed or the list changed on purpose")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print(f"{len(problems)} problem(s) with the healthchecks.")
    sys.exit(1)
print(f"OK: {len(EXPECT)} service(s) watched by a healthcheck on their health path, {len(EXEMPT)} distroless service(s) left out on purpose, of {len(services)} in compose.yaml.")
PY
