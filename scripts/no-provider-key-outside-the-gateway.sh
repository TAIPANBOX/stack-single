#!/usr/bin/env bash
#
# Enforces invariant 39 of CLAUDE.md: the provider key is held by the gateway and by
# nothing that acts for an agent. Each door reads it from a file the installer wrote,
# mounted read only into that door alone, and no service in compose.yaml carries it
# as an environment value.
#
# WHAT THIS IS ABOUT
#
# Finding F-002 of the 2026-10-17 review: an agent that holds the provider key can
# call the model with no gateway in the way, and the gateway forwarded whatever key
# a caller sent. The hybrid design (decided 2026-10-17, paraphrased) moves custody of
# the key into the gateway: the agent presents a gateway credential, and the door
# supplies the provider credential itself. Until this change the console held
# GENARYX_COPILOT_KEY as Felyx's environment and the gateway forwarded it.
#
# WHAT THIS CHECKS
#
#   A. SUBJECTS. Every service whose image is the tokenfuse gateway image and whose
#      command is the bare binary, read from the resolved configuration. Each must be
#      one this gate knows the key file of: tokenfuse-gateway (its own directory
#      upstream/anthropic) and tokenfuse-gateway-openai (upstream/openai). A new
#      gateway with no mapping here is a failure, not a smaller subject.
#   B. NO PROVIDER KEY IN ANY ENVIRONMENT. No service's environment names a variable
#      that carries a provider key (ANTHROPIC_API_KEY, OPENAI_API_KEY, COPILOT_KEY and
#      their _API_ forms), and no value is a reference (env:NAME) to one.
#   C. EACH DOOR HAS ITS KEY FILE, AND ONLY ITS OWN. Each subject sets
#      TOKENFUSE_UPSTREAM_KEY_FILE, mounts its own directory at /run/upstream read
#      only, and, rendered with two distinct paths, reads exactly the path its own
#      .env variable gives. No other service mounts any upstream directory or the
#      /run/upstream target.
#   D. THE INSTALLER WRITES THE FILE. install.sh has an `# upstream-key:` block that
#      writes the key with mode 0400 and owner 10001, the uid the gateway runs as.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no compose.yaml, no docker compose, no
# gateway subject, or no installer block is each reported and fails.
set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f compose.yaml ]; then
  fail "compose.yaml is not there, so this gate measured NOTHING about the provider key"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
  exit 1
fi

# resolve OUT ENV-FILE-LINES...: the resolved configuration of compose.yaml with every
# required variable given a fake value, the profiles that hold a door or an add-on on,
# and the extra lines appended. Written to OUT as JSON. Fails the gate if compose refuses.
resolve() {
  local out="$1" extra="$2" cdir="$scratch/cfg"
  mkdir -p "$cdir"
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u \
    | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
  [ -z "$extra" ] || printf '%s\n' "$extra" >>"$cdir/.env"
  if ! docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" \
      --profile openai-door --profile typed --profile finops --profile record \
      --profile egress --profile egress-browser --profile delegation \
      config --format json >"$out" 2>"$cdir/err"; then
    fail "resolved: docker compose config refused the compose file: $(head -1 "$cdir/err")"
    return 1
  fi
}

resolve "$scratch/cfg1.json" "" || exit 1
resolve "$scratch/cfg2.json" "$(printf 'GATEWAY_UPSTREAM_KEY_FILE=/run/upstream/anthropic-key\nOPENAI_DOOR_UPSTREAM_KEY_FILE=/run/upstream/openai-key')" || exit 1

# Every check reads the resolved JSON, so what is judged is what compose renders.
python3 - "$scratch/cfg1.json" "$scratch/cfg2.json" <<'PY' || problems=$((problems + 1))
import json
import re
import sys

base = json.load(open(sys.argv[1]))["services"]
rendered = json.load(open(sys.argv[2]))["services"]

# The doors this gate knows: subject service -> (its directory under upstream/,
# the .env variable that gives its key file's path inside the container).
DOORS = {
    "tokenfuse-gateway": ("anthropic", "GATEWAY_UPSTREAM_KEY_FILE", "/run/upstream/anthropic-key"),
    "tokenfuse-gateway-openai": ("openai", "OPENAI_DOOR_UPSTREAM_KEY_FILE", "/run/upstream/openai-key"),
}
PROVIDER_VAR = re.compile(r"^(ANTHROPIC|OPENAI|PROVIDER|COPILOT)_(API_)?KEY$")
PROVIDER_REF = re.compile(r"^env:(ANTHROPIC|OPENAI|PROVIDER|GENARYX_COPILOT)_(API_)?KEY$")

problems = []


def env_of(svc):
    return svc.get("environment") or {}


def is_gateway(svc):
    return str(svc.get("image", "")).startswith("ghcr.io/taipanbox/tokenfuse:") and svc.get("command") == ["/usr/local/bin/tokenfuse"]


subjects = sorted(n for n, s in base.items() if is_gateway(s))
if not subjects:
    problems.append("A. no service runs the tokenfuse gateway image with its bare command, so this gate measured NOTHING about the provider key")
for n in subjects:
    if n not in DOORS:
        problems.append("A. %s is a gateway with no key file this gate knows, so its provider key is not judged; add it to DOORS with its own directory" % n)

# B. no provider key as an environment value, and no reference to one.
for n, s in sorted(base.items()):
    for k, v in env_of(s).items():
        if PROVIDER_VAR.match(k):
            problems.append("B. %s carries %s as an environment value: a provider key an agent-facing service can read" % (n, k))
        if isinstance(v, str) and PROVIDER_REF.match(v):
            problems.append("B. %s takes its key from %s, a provider key, through a reference" % (n, v))

# C. each door reads its own key file, mounted read only from its own directory,
# and no other service mounts an upstream directory or the /run/upstream target.
def upstream_mounts(svc):
    return [v for v in svc.get("volumes") or [] if isinstance(v, dict) and str(v.get("target", "")).startswith("/run/upstream")]


for n in subjects:
    if n not in DOORS:
        continue
    directory, var, _ = DOORS[n]
    if "TOKENFUSE_UPSTREAM_KEY_FILE" not in env_of(base[n]):
        problems.append("C. %s sets no TOKENFUSE_UPSTREAM_KEY_FILE, so it cannot hold the provider key" % n)
    mounts = upstream_mounts(base[n])
    own = [v for v in mounts if str(v.get("source", "")).endswith("/upstream/" + directory) and v.get("read_only") is True]
    if not own:
        problems.append("C. %s does not mount ./upstream/%s at /run/upstream read only" % (n, directory))
    got = env_of(rendered[n]).get("TOKENFUSE_UPSTREAM_KEY_FILE")
    want = DOORS[n][2]
    if got != want:
        if var.endswith("KEY_FILE"):
            problems.append("C. %s reads TOKENFUSE_UPSTREAM_KEY_FILE %r, not the path %s gives (%r)" % (n, got, var, want))

for n, s in sorted(base.items()):
    if n in DOORS and n in subjects:
        continue
    for v in upstream_mounts(s):
        problems.append("C. %s mounts /run/upstream, the provider key's directory, and is not a door" % n)
    for v in s.get("volumes") or []:
        if isinstance(v, dict) and re.search(r"/upstream/(anthropic|openai)$", str(v.get("source", ""))):
            problems.append("C. %s mounts the provider key directory %s, and is not that door" % (n, v.get("source")))

# Ensure the rendered read for the other door is also checked against its own path,
# not only the first: a door reading the other door's variable is the fault above.
for n in subjects:
    if n in DOORS:
        got = env_of(rendered[n]).get("TOKENFUSE_UPSTREAM_KEY_FILE")
        other = [DOORS[m][2] for m in DOORS if m != n]
        if got in other:
            problems.append("C. %s reads the other door's key file %r" % (n, got))

for p in problems:
    print("FAIL: " + p)
if problems:
    sys.exit(1)
print("OK: %d gateway subject(s) (%s); no provider key in any service's environment; each door reads its own key file from its own read-only directory" % (len(subjects), ", ".join(subjects)))
PY

# D. the installer writes the key file, owned by the gateway's uid and mode 0400.
BLOCK="$(sed -n '/^# upstream-key: begin$/,/^# upstream-key: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# upstream-key: begin' .. 'end' block, so nothing writes the provider key a gateway holds"
else
  # The commands, not the comments: the block's own prose says 0400 too.
  printf '%s\n' "$BLOCK" | grep -q 'chmod 0400' || fail "the upstream-key block does not set mode 0400 on the key file"
  printf '%s\n' "$BLOCK" | grep -q 'chown 10001:10001' || fail "the upstream-key block does not give the key file to uid 10001, the uid the gateway runs as"
fi

if [ "$problems" -ne 0 ]; then
  printf 'no-provider-key-outside-the-gateway: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: no-provider-key-outside-the-gateway (invariant 39)"
