#!/usr/bin/env bash
#
# Felyx, the console's copilot, reaches its model through this box's own
# gateway by default, and nothing in compose.yaml lets it go around.
#
# WHAT THIS CHECKS, in the console service of compose.yaml:
#   GENARYX_COPILOT_BASE_URL is http://tokenfuse-gateway:4100,
#   GENARYX_COPILOT_LOCAL_HOSTNAMES allow-lists exactly tokenfuse-gateway,
#   GENARYX_COPILOT_AGENT_ID is built from RECORD_TRUST_DOMAIN;
#   GENARYX_COPILOT_FUSE_KEY_REF points at GENARYX_COPILOT_FUSE_KEY, and that
#   is ${GENARYX_COPILOT_FUSE_KEY:-}: read from .env, empty by default (genaryx
#   invariant 24, Felyx's own gateway client key). A literal would put a key
#   into git; a required one would stop every box that gives Felyx none;
# and anywhere in compose.yaml: no GENARYX_COPILOT_ALLOW_REMOTE, which would
# skip the residency check and send Felyx past the meter.
#
# AND WHAT THE END OF THE RUN TELLS THE OPERATOR ABOUT IT. The closing report used
# to say Felyx "sends no x-fuse-key" on every box with client keys on and a
# provider key for Felyx, including one that had given Felyx a key of its own and
# whose Felyx was answering (measured 2026-10-13 with throwaway consoles v1.1.44
# against a gateway holding client keys: key set, an ask answered 200; key empty,
# the gateway's 401 `unauthorized`). The `felyx_gateway_note` function in install.sh's
# `# identity-files:` block is lifted and run for each situation: with
# GENARYX_COPILOT_FUSE_KEY set it says Felyx presents the key and must be bound,
# and does not say it sends none; with it empty it says Felyx sends none and its
# calls are refused 401; with client keys off, or no provider key for Felyx, it says
# nothing; and it never prints the key.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no console service, or no copilot
# variable in it, no installer block, no felyx_gateway_note, or a closing report
# that never calls it, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.."
problems=0
python3 - <<'PY' || problems=$((problems + 1))
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
if env.get("GENARYX_COPILOT_FUSE_KEY_REF") != "env:GENARYX_COPILOT_FUSE_KEY":
    errors.append(f"console: GENARYX_COPILOT_FUSE_KEY_REF is {env.get('GENARYX_COPILOT_FUSE_KEY_REF')!r}, not 'env:GENARYX_COPILOT_FUSE_KEY': Felyx would not present its own gateway client key")
# The value itself is never printed: if it is wrong, it may be a key.
if env.get("GENARYX_COPILOT_FUSE_KEY") != "${GENARYX_COPILOT_FUSE_KEY:-}":
    errors.append("console: GENARYX_COPILOT_FUSE_KEY is not ${GENARYX_COPILOT_FUSE_KEY:-}: Felyx's client key must be read from .env and empty by default, never written here or required")
for n, line in enumerate(text.splitlines(), 1):
    if not line.lstrip().startswith("#") and "GENARYX_COPILOT_ALLOW_REMOTE" in line:
        errors.append(f"compose.yaml:{n} sets GENARYX_COPILOT_ALLOW_REMOTE: Felyx would skip the residency check and go around the gateway")
if errors:
    for e in errors: print(f"FAIL: {e}")
    sys.exit(1)
print("OK: Felyx reaches its model through tokenfuse-gateway by service name, under agent://<RECORD_TRUST_DOMAIN>/genaryx/felyx, with its own client key read from .env when one is given, and nothing lets it go around.")
PY

# ---- the closing report's note about Felyx --------------------------------------------
BLOCK="$(sed -n '/^# identity-files: begin$/,/^# identity-files: end$/p' install.sh)"
# Built at run time, so the file carries no literal that looks like a credential.
SENTINEL="felyx-sentinel-$$-$(date +%s)"
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# identity-files: begin' .. 'end' block, so the note about Felyx cannot be run and this measured nothing about what the end of the run says"
elif ! printf '%s' "$BLOCK" | grep -q '^felyx_gateway_note()'; then
  fail "the identity-files block defines no felyx_gateway_note, so the closing report's note about Felyx is not something this can run"
elif [ "$(grep -c '\$(felyx_gateway_note)' install.sh)" -ne 1 ]; then
  fail "install.sh does not call felyx_gateway_note exactly once in the closing report: the note about Felyx is dead text or repeated"
else
  note_for() { # IDENTITY_KEYS_COUNT COPILOT_KEY FUSE_KEY: what the note prints
    env -i PATH="$PATH" BLOCK="$BLOCK" KEYS="$1" CK="$2" FK="$3" bash -c '
      set -euo pipefail
      eval "$BLOCK"
      STACK_DIR=/opt/agent-stack
      IDENTITY_KEYS_COUNT="$KEYS"
      GENARYX_COPILOT_KEY="$CK"
      GENARYX_COPILOT_FUSE_KEY="$FK"
      felyx_gateway_note' 2>&1
  }
  # client keys on, a key for Felyx's provider, and a key of its own for the gateway
  out="$(note_for 3 sk-provider "$SENTINEL")"
  [ -n "$out" ] || fail "Felyx has a gateway key and client keys are on, and the note says nothing"
  case "$out" in
    *"sends no x-fuse-key"*|*"are refused 401"*)
      fail "the note says Felyx sends no key, or that its calls are refused 401, although GENARYX_COPILOT_FUSE_KEY is set, which is what the box has" ;;
  esac
  case "$out" in *GENARYX_COPILOT_FUSE_KEY*x-fuse-key*) ;; *) fail "the note for a Felyx with a key does not say it presents GENARYX_COPILOT_FUSE_KEY as x-fuse-key" ;; esac
  case "$out" in *"keys[] binding"*"agent id"*) ;; *) fail "the note for a Felyx with a key does not say its key id has to be bound to Felyx's agent id in the map" ;; esac
  case "$out" in *"$SENTINEL"*) fail "the note printed the value of GENARYX_COPILOT_FUSE_KEY" ;; esac
  # client keys on, a key for Felyx's provider, and no key of its own
  out="$(note_for 3 sk-provider "")"
  case "$out" in *"sends no x-fuse-key"*) ;; *) fail "the note for a Felyx with no gateway key does not say it sends no x-fuse-key" ;; esac
  case "$out" in *"refused 401"*) ;; *) fail "the note for a Felyx with no gateway key no longer says its calls are refused 401" ;; esac
  case "$out" in *GENARYX_COPILOT_FUSE_KEY*) ;; *) fail "the note for a Felyx with no gateway key does not name GENARYX_COPILOT_FUSE_KEY, the way to give it one" ;; esac
  # nothing to refuse: client keys off, or Felyx has no provider key and so makes no call
  for fk in "" "$SENTINEL"; do
    out="$(note_for 0 sk-provider "$fk")"
    [ -z "$out" ] || fail "the note says something about Felyx with client keys off, when there is nothing to refuse: $out"
    out="$(note_for 3 "" "$fk")"
    [ -z "$out" ] || fail "the note says something about Felyx when it has no provider key and so makes no call: $out"
  done
fi

if [ "$problems" -gt 0 ]; then
  exit 1
fi
echo "OK: the closing report tells an operator whose Felyx has a gateway key that it presents it and must be"
echo "    bound, one whose Felyx has none that its calls are refused 401, and nothing when there is nothing"
echo "    to refuse; it never prints the key."
