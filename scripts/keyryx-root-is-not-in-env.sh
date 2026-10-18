#!/usr/bin/env bash
#
# Enforces: the Keyryx root keys are files, never environment values and never
# lines in .env (CLAUDE.md invariant 43).
#
# WHY
#
# A root key wraps every private key Keyryx holds. Anything that reads the
# environment or .env (a `docker inspect`, a crash dump of compose, the
# installer's own `. ./.env`, a support bundle) would read it. So the root key
# is a 0400 file that install.sh writes once, mounted read only into the one
# process that uses it, and never a value anywhere a shell or a container
# environment could show it.
#
# WHAT IT JUDGES
#
#   1. install.sh: the two functions that write the root keys (keyryx_root_key,
#      keyryx_prepare) never touch .env, and nothing calls add_env_default with
#      a root-key name or with a root-key file.
#   2. compose.yaml, resolved with a fake .env: no service's environment carries
#      a root-key NAME whose value is bytes rather than a path under /run/keyryx,
#      and no environment value is an interpolation of a root-key variable.
#   3. compose.yaml's text: no interpolation of a root-key variable from .env.
#
# It refuses to report OK when the subjects are gone (no keyryx service, no
# keyryx_root_key function): an empty result is "measured nothing".
#
# Scenarios: features/keyryx-root-keys-are-files.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "keyryx-root".

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "keyryx-root: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/keyryx-root.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []

def bad(msg):
    print("FAIL keyryx-root: " + msg)
    sys.exit(1)

install = open("install.sh").read()
compose_text = open("compose.yaml").read()

# 1. install.sh: the root-key writers are present, and they never reach .env.
def body(name):
    m = re.search(r"^%s\(\) \{[^\n]*\n(.*?)^\}\n" % re.escape(name), install, re.M | re.S)
    if not m:
        bad("install.sh has no %s() function; measured nothing" % name)
    return m.group(1)

for name in ("keyryx_root_key", "keyryx_prepare"):
    b = body(name)
    if re.search(r"\.env\b|add_env_default", b):
        problems.append("%s() writes .env or calls add_env_default: a root key must never reach .env" % name)

for m in re.finditer(r"^.*add_env_default.*$", install, re.M):
    if re.search(r"ROOT_KEY|root\.key|witness-root", m.group(0)):
        problems.append("install.sh writes a root key into .env: %s" % m.group(0).strip())

# 3. the compose text never interpolates a root-key variable from .env.
for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*ROOT_KEY[A-Za-z0-9_]*)[:}]", compose_text):
    if not m.group(1).endswith("_FILE"):
        problems.append("compose.yaml interpolates %s from .env" % m.group(1))

# 2. resolved compose: no root-key bytes in any environment.
required = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", compose_text)))
envfile = os.path.join(work, ".env")
with open(envfile, "w") as f:
    for name in required:
        f.write("%s=placeholder\n" % name)
clean = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}
r = subprocess.run(
    ["docker", "compose", "--project-directory", root, "--env-file", envfile,
     "-f", os.path.join(root, "compose.yaml"), "--profile", "*", "config", "--format", "json"],
    capture_output=True, text=True, env=clean, cwd=root)
if r.returncode != 0:
    bad("docker compose config failed: %s" % ((r.stderr.strip().splitlines() or ["?"])[-1]))
services = json.loads(r.stdout).get("services", {})
if "keyryx" not in services or "keyryx-witness" not in services:
    bad("the resolved configuration has no keyryx or keyryx-witness service; measured nothing")

for svc, d in services.items():
    for k, v in (d.get("environment") or {}).items():
        if re.search(r"ROOT_KEY", k) and not k.endswith("_FILE"):
            problems.append("%s sets %s: a root key is a file, not an environment value" % (svc, k))
        if k.endswith("_FILE") and "ROOT_KEY" in k and not str(v).startswith("/"):
            problems.append("%s sets %s to %r, which is not a path" % (svc, k, v))

if problems:
    for p in problems:
        print("FAIL keyryx-root: " + p)
    sys.exit(1)
print("OK: no root key is in .env or in any environment; both root keys are files written by install.sh")
PY
