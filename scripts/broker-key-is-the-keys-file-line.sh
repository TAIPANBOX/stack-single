#!/usr/bin/env bash
#
# Enforces invariant 48 of CLAUDE.md (1.4.0, D6): a box given its own CLIENT_KEYS_FILE, with
# agent tokens on (the default), carries the MCP broker's key in that file as a line
# `<secret>:broker`, the format install.sh reads (one secret:key_id per line, split on the LAST
# colon). With the line, the installer accepts the box and the broker's key file is that secret.
# Without it, the installer refuses, and the refusal names ADD_BROKER_KEY=1, which mints the
# secret, appends the line and keeps the file's mode. The README must say the same format.
#
# Before 1.4.0 the README said `broker:<secret>`, the installer read `<secret>:broker`, and
# the refusal named the README's form, so an operator who followed it was refused again.
#
# WHAT THIS CHECKS, by running the installer's own `# agent-tokens:` block (lifted out of
# install.sh) against scratch files, with the helpers it calls stubbed:
#   A. the keys file has the broker line: the box is accepted, the broker key file holds that
#      secret, and the keys file is byte for byte unchanged.
#   B. no broker line and no ADD_BROKER_KEY: refused before anything is written, naming
#      ADD_BROKER_KEY=1 and the `<secret>:broker` form.
#   C. no broker line and ADD_BROKER_KEY=1, with the identity map binding `broker`: the line is
#      appended, the file keeps its mode, and the broker key file holds the appended secret.
#   D. ADD_BROKER_KEY=1 but the identity map does not bind `broker`: refused before the keys file
#      is touched.
#   E. the README states `<secret>:broker` and not `broker:<secret>`, and the refusal text of the
#      installer does not print `'broker:<secret>'`.
#   F. a re-run of a box whose keys an earlier run took from its keys file and keeps in .env, with
#      no CLIENT_KEYS_FILE this run (the variable unset, as on forge 2026-10-25), with and without
#      ADD_BROKER_KEY=1: refused by the installer's own refusal, not a shell error on the unset
#      variable, saying the keys are kept in .env and naming CLIENT_KEYS_FILE and
#      WITH_AGENT_TOKENS=0 as the ways out, and .env is unchanged.
#
# IT REFUSES TO REPORT OK ON NOTHING: no install.sh, no `# agent-tokens:` block, or no
# agent_tokens_resolve in it is reported and fails.

set -euo pipefail
cd "$(dirname "$0")/.."

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f install.sh ]; then
  fail "install.sh is not there, so the broker line was not measured"
  exit 1
fi
BLOCK="$(sed -n '/^# agent-tokens: begin$/,/^# agent-tokens: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# agent-tokens:' block, so the broker line was not measured"
  exit 1
fi
printf '%s\n' "$BLOCK" | grep -q '^agent_tokens_resolve() {' \
  || { fail "the agent-tokens block has no agent_tokens_resolve, so the broker line was not measured"; exit 1; }
printf '%s\n' "$BLOCK" >"$scratch/block.sh"

# The helpers the block calls that live elsewhere in install.sh, stubbed to what they do for a
# scratch .env and a scratch stack directory. The stubs keep the real semantics that matter here:
# a line replaced, never duplicated; a secret minted only when absent; a key file written 0400.
cat >"$scratch/stubs.sh" <<'STUBS'
die()  { echo "DIE: $*"; exit 3; }
note() { :; }
gen() { head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$1"; }
identity_entry_why() { :; }
identity_env_get() {
  local v=""
  [ -f "$STACK_DIR/.env" ] && v="$(sed -n "s/^$1='\(.*\)'\$/\1/p" "$STACK_DIR/.env" | tail -1)"
  printf '%s' "$v"
}
identity_env_set() {
  local f="$STACK_DIR/.env"
  touch "$f"
  grep -v "^$1=" "$f" >"$f.tmp" || true
  printf "%s='%s'\n" "$1" "$2" >>"$f.tmp"
  mv -f "$f.tmp" "$f"
}
mint_env_forget() { local f="$STACK_DIR/.env"; [ -f "$f" ] && { grep -v "^$1=" "$f" >"$f.tmp" || true; mv -f "$f.tmp" "$f"; }; return 0; }
mint_env_secret() { [ -n "$(identity_env_get "$1")" ] || identity_env_set "$1" "$(gen 40)"; }
upstream_put() { mkdir -p "$2"; printf '%s' "$1" >"$2/key"; }
STUBS

# run_case NAME STACK_DIR_PATH KEYS_FILE MAP_FILE ADD: resolve then apply the block, in a
# subshell that prints what it decided. Prints the output; sets RC.
run_case() {
  local name="$1" d="$2" keys="$3" map="$4" add="$5" out
  out="$(bash -c '
    set -euo pipefail
    STACK_DIR="$1"; MINT_ON=0; CLIENT_KEYS_FILE="$2"; IDENTITY_MAP_FILE="$3"; ADD_BROKER_KEY="$4"
    GATEWAY_PROBE=127.0.0.1; WITH_AGENT_TOKENS=""; WITH_DELEGATION=""; STATIC_KEY_IDS=""
    # What identity_resolve read from the keys file, before this block runs: section 3e checks the map
    # against exactly this, so a line the block adds to the file must reach it too.
    IDENTITY_DOOR=main; IDENTITY_KEYS_GIVEN=1
    IDENTITY_KEYS_NEW="$(grep -v -E "^[[:space:]]*(#|$)" "$2" | paste -s -d, -)"
    . "$5/stubs.sh"
    . "$5/block.sh"
    agent_tokens_resolve
    agent_tokens_apply
    echo "APPLIED"
    printf "SPEC_IDS=%s\n" "$(printf "%s" "$IDENTITY_KEYS_NEW" | tr "," "\n" | sed -e "s/.*://" | paste -s -d, -)"
    want="$(grep -v -E "^[[:space:]]*(#|$)" "$2" | paste -s -d, -)"
    [ "$IDENTITY_KEYS_NEW" = "$want" ] && echo "SPEC_IS_THE_FILE=yes" || echo "SPEC_IS_THE_FILE=no"
  ' _ "$d" "$keys" "$map" "$add" "$scratch" 2>&1)" && RC=0 || RC=$?
  OUT="$out"
  : "$name"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Fixture secrets are minted for this run, never written into the repository (the secret scanner reads
# every tracked file). A bounded read, so the generator ends on its own.
fixture_secret() {
  local s
  s="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  printf '%s' "${s:0:40}"
}
SECRET_A="$(fixture_secret)"
SECRET_BROKER="$(fixture_secret)"
MAP_BINDS='{"units":[{"id":"console"},{"id":"agents"}],"keys":[{"key_id":"agents","unit":"agents","agents":["agent://local/agents/*"]},{"key_id":"broker","unit":"console","agents":["agent://local/agents/*"]}]}'
# Binds unit agents, but no broker.
MAP_AGENTS_NO_BROKER='{"units":[{"id":"console"},{"id":"agents"}],"keys":[{"key_id":"agents","unit":"agents","agents":["agent://local/agents/*"]}]}'
# Binds broker, but nothing in unit agents, the unit the installer enrols the operator agent in at vouchryx.
MAP_NO_AGENTS_UNIT='{"units":[{"id":"console"}],"keys":[{"key_id":"broker","unit":"console","agents":["agent://local/agents/*"]}]}'
MAP_NO_BROKER='{"units":[{"id":"console"}],"keys":[{"key_id":"felyx","unit":"console","agents":["agent://local/genaryx/felyx"]}]}'

# A. the keys file has the broker line
d="$(mktemp -d "$scratch/a.XXXXXX")"; mkdir -p "$d/keys"
printf '%s:felyx\n%s:broker\n' "$SECRET_A" "$SECRET_BROKER" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
before="$(cat "$d/keys.txt")"
run_case "A" "$d" "$d/keys.txt" "$d/map.json" ""
if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -qx APPLIED; then
  fail "A. a keys file with a '<secret>:broker' line was refused: $OUT"
else
  got="$(cat "$d/broker/key" 2>/dev/null || true)"
  [ "$got" = "$SECRET_BROKER" ] || fail "A. the broker key file does not hold the secret of the keys file's broker line"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "A. the keys file was changed although it had the broker line"
  printf '%s' "$OUT" | grep -qx 'SPEC_IS_THE_FILE=yes' \
    || fail "A. the keys section 3e checks are not the keys file's own lines ($(printf '%s' "$OUT" | grep '^SPEC_IDS='))"
fi

# B. no broker line and no ADD_BROKER_KEY: refused before anything is written
d="$(mktemp -d "$scratch/b.XXXXXX")"
printf '%s:felyx\n' "$SECRET_A" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_NO_BROKER" >"$d/map.json"
before="$(cat "$d/keys.txt")"
run_case "B" "$d" "$d/keys.txt" "$d/map.json" ""
if [ "$RC" -eq 0 ]; then
  fail "B. a keys file with no broker line was accepted with no ADD_BROKER_KEY"
else
  printf '%s' "$OUT" | grep -q 'ADD_BROKER_KEY=1' || fail "B. the refusal does not name ADD_BROKER_KEY=1: $OUT"
  printf '%s' "$OUT" | grep -q '<secret>:broker' || fail "B. the refusal does not name the '<secret>:broker' form: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "B. the keys file changed on a refusal"
fi

# C. no broker line, ADD_BROKER_KEY=1, the map binds broker: append, keep the mode, use the secret
d="$(mktemp -d "$scratch/c.XXXXXX")"
printf '%s:felyx\n' "$SECRET_A" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
run_case "C" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -qx APPLIED; then
  fail "C. ADD_BROKER_KEY=1 with a binding map was refused: $OUT"
else
  last="$(tail -1 "$d/keys.txt")"
  case "$last" in *:broker) ;; *) fail "C. the keys file does not end in a ':broker' line after ADD_BROKER_KEY=1" ;; esac
  [ "$(wc -l <"$d/keys.txt" | tr -d ' ')" = 2 ] || fail "C. the keys file does not hold exactly the felyx line and the appended broker line"
  [ "$(mode_of "$d/keys.txt")" = 640 ] || fail "C. the keys file's mode changed from 640 to $(mode_of "$d/keys.txt")"
  appended="${last%:broker}"
  got="$(cat "$d/broker/key" 2>/dev/null || true)"
  [ -n "$got" ] && [ "$got" = "$appended" ] || fail "C. the broker key file does not hold the secret the line appended"
  # Section 3e checks the map against the keys this run read; the line appended here must be among them, or
  # a map that binds broker (which ADD_BROKER_KEY=1 requires) is refused for a key no client carries.
  # Measured on forge 2026-10-25: the run appended the line, then refused its own map.
  printf '%s' "$OUT" | grep -qx 'SPEC_IS_THE_FILE=yes' \
    || fail "C. the keys section 3e checks against the map lack the appended broker line ($(printf '%s' "$OUT" | grep '^SPEC_IDS=')), so the map's broker binding is refused"
fi

# D. ADD_BROKER_KEY=1 but the map does not bind broker: refused, and the keys file is untouched
d="$(mktemp -d "$scratch/d.XXXXXX")"
printf '%s:felyx\n' "$SECRET_A" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
# The map binds unit agents (case G's check passes), so only the broker check can refuse it.
printf '%s\n' "$MAP_AGENTS_NO_BROKER" >"$d/map.json"
before="$(cat "$d/keys.txt")"
run_case "D" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -eq 0 ]; then
  fail "D. ADD_BROKER_KEY=1 was accepted with an identity map that does not bind broker"
else
  printf '%s' "$OUT" | grep -q 'does not bind key_id broker' || fail "D. the refusal does not say the map does not bind broker: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "D. the keys file was appended although the map does not bind broker"
fi

# G. the map binds broker but nothing in unit agents. vouchryx enrols the operator agent in unit agents, so the
# gateway would refuse that agent's token as unit_contradicts_map (measured on forge 2026-10-25: 403 for a valid
# token). Refused before anything is written, naming unit agents, and the keys file is untouched.
d="$(mktemp -d "$scratch/g.XXXXXX")"
printf '%s:felyx\n%s:broker\n' "$SECRET_A" "$SECRET_BROKER" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_NO_AGENTS_UNIT" >"$d/map.json"
before="$(cat "$d/keys.txt")"
run_case "G" "$d" "$d/keys.txt" "$d/map.json" ""
if [ "$RC" -eq 0 ]; then
  fail "G. a map with no binding in unit agents was accepted, so the enrolled operator agent's token would be refused"
else
  printf '%s' "$OUT" | grep -q 'unit agents' || fail "G. the refusal does not name unit agents: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "G. the keys file changed on a refusal"
  [ ! -e "$d/.env" ] || ! grep -q '^TOKENFUSE_AGENT_TOKENS=' "$d/.env" || fail "G. .env was written before the refusal"
fi

# F. keys kept in .env by an earlier run, no CLIENT_KEYS_FILE this run. The variable is UNSET, as on a
# real re-run, so `set -u` meets it if the block reads it. The stubbed die exits 3; a shell error exits 1.
run_kept_case() {
  local d="$1" add="$2" out
  out="$(bash -c '
    set -euo pipefail
    STACK_DIR="$1"; MINT_ON=0; ADD_BROKER_KEY="$2"; unset CLIENT_KEYS_FILE IDENTITY_MAP_FILE
    GATEWAY_PROBE=127.0.0.1; WITH_AGENT_TOKENS=""; WITH_DELEGATION=""; STATIC_KEY_IDS=""
    . "$3/stubs.sh"
    . "$3/block.sh"
    agent_tokens_resolve
    agent_tokens_apply
    echo "APPLIED"
  ' _ "$d" "$add" "$scratch" 2>&1)" && RC=0 || RC=$?
  OUT="$out"
}
for add in "" 1; do
  label="F${add:+ (ADD_BROKER_KEY=1)}"
  d="$(mktemp -d "$scratch/f.XXXXXX")"
  printf "GATEWAY_CLIENT_KEYS='%s:felyx'\n" "$SECRET_A" >"$d/.env"
  before="$(cat "$d/.env")"
  run_kept_case "$d" "$add"
  if [ "$RC" -eq 0 ]; then
    fail "$label. a box whose keys are kept in .env, with no CLIENT_KEYS_FILE this run, was accepted with no broker key"
  else
    if printf '%s' "$OUT" | grep -q 'unbound variable'; then
      fail "$label. the installer read an unset CLIENT_KEYS_FILE: $(printf '%s' "$OUT" | grep 'unbound variable' | head -1)"
    fi
    [ "$RC" -eq 3 ] || fail "$label. it stopped with exit $RC, not the installer's refusal"
    printf '%s' "$OUT" | grep -q 'kept in .env' || fail "$label. the refusal does not say the keys are kept in .env"
    printf '%s' "$OUT" | grep -q 'CLIENT_KEYS_FILE=' || fail "$label. the refusal does not name CLIENT_KEYS_FILE as the way to add the broker's line"
    printf '%s' "$OUT" | grep -q 'WITH_AGENT_TOKENS=0' || fail "$label. the refusal does not name WITH_AGENT_TOKENS=0"
    if printf '%s' "$OUT" | grep -q 'gave its own CLIENT_KEYS_FILE'; then
      fail "$label. the refusal says this run gave a CLIENT_KEYS_FILE, which it did not"
    fi
  fi
  [ "$(cat "$d/.env")" = "$before" ] || fail "$label. .env changed on a refusal"
done

# E. the docs and the refusal text name the same form the installer reads
if grep -q 'broker:<secret>' README.md; then
  fail "E. README.md still says broker:<secret>, which the installer never reads (it reads <secret>:broker)"
fi
grep -q '<secret>:broker' README.md || fail "E. README.md does not name the <secret>:broker form"
if grep -q "'broker:<secret>'" install.sh; then
  fail "E. install.sh's refusal still prints 'broker:<secret>'"
fi

if [ "$problems" -ne 0 ]; then
  printf 'broker-key-is-the-keys-file-line: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: broker-key-is-the-keys-file-line (invariant 48): a box with its own keys file takes the broker line, or adds it on ADD_BROKER_KEY=1"
