#!/usr/bin/env bash
#
# Felyx, the console's copilot, reaches its model through this box's own
# gateway by default, and nothing in compose.yaml lets it go around.
#
# WHAT THIS CHECKS, in the console service of compose.yaml:
#   GENARYX_COPILOT_BASE_URL is http://tokenfuse-gateway:4100,
#   GENARYX_COPILOT_LOCAL_HOSTNAMES allow-lists exactly tokenfuse-gateway,
#   GENARYX_COPILOT_AGENT_ID is built from RECORD_TRUST_DOMAIN;
# and anywhere in compose.yaml: no GENARYX_COPILOT_ALLOW_REMOTE, which would
# skip the residency check and send Felyx past the meter.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no console service, or no copilot
# variable in it, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, sys, pathlib
text = pathlib.Path("compose.yaml").read_text()
m = re.search(r"(?ms)^  console:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)", text)
if not m:
    print("FAIL: compose.yaml has no console service, so this measured nothing"); sys.exit(1)
env = dict(re.findall(r"(?m)^\s+(GENARYX_COPILOT_\w+):\s*(\S+)\s*$", m.group(1)))
if not env:
    print("FAIL: the console carries no GENARYX_COPILOT_* variable, so this measured nothing"); sys.exit(1)
errors = []
for k, v in {"GENARYX_COPILOT_BASE_URL": "http://tokenfuse-gateway:4100",
             "GENARYX_COPILOT_LOCAL_HOSTNAMES": "tokenfuse-gateway"}.items():
    if env.get(k) != v:
        errors.append(f"console: {k} is {env.get(k)!r}, not {v!r}: Felyx would not reach its model through this box's gateway")
if env.get("GENARYX_COPILOT_AGENT_ID") != "agent://${RECORD_TRUST_DOMAIN:-local}/genaryx/felyx":
    errors.append(f"console: GENARYX_COPILOT_AGENT_ID is {env.get('GENARYX_COPILOT_AGENT_ID')!r}: Felyx's agent id must follow RECORD_TRUST_DOMAIN")
for n, line in enumerate(text.splitlines(), 1):
    if not line.lstrip().startswith("#") and "GENARYX_COPILOT_ALLOW_REMOTE" in line:
        errors.append(f"compose.yaml:{n} sets GENARYX_COPILOT_ALLOW_REMOTE: Felyx would skip the residency check and go around the gateway")
if errors:
    for e in errors: print(f"FAIL: {e}")
    sys.exit(1)
print("OK: Felyx reaches its model through tokenfuse-gateway by service name, under agent://<RECORD_TRUST_DOMAIN>/genaryx/felyx, and nothing lets it go around.")
PY
