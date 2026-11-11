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
#   H. (invariant 75) every static key the broker admits (stack-single, drills-broker) is a gateway key of
#      the same id and secret, so the same box with its own keys file carries those lines too:
#        H1. no line for them and no ADD_BROKER_KEY: refused before anything is written, naming each id
#            and ADD_BROKER_KEY=1, and the keys file is byte for byte unchanged;
#        H2. ADD_BROKER_KEY=1: both lines are appended with the secrets the broker holds, the mode is
#            kept, and the keys section 3e checks carry them;
#        H3. a line for one of them with another secret than the broker's: refused, nothing rewritten;
#        H4. a map that does not bind one of them: refused before the keys file is touched;
#        H5. a second run over the file H2 left changes nothing.
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
grep -q '^agent_tokens_resolve() {' <<<"$BLOCK" \
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
    DRILLS_BROKER_ID=drills-broker
    # What identity_resolve read from the keys file, before this block runs: section 3e checks the map
    # against exactly this, so a line the block adds to the file must reach it too.
    IDENTITY_DOOR=main; IDENTITY_KEYS_GIVEN=1
    IDENTITY_KEYS_NEW="$(grep -v -E "^[[:space:]]*(#|$)" "$2" | paste -s -d, -)"
    . "$5/stubs.sh"
    . "$5/block.sh"
    agent_tokens_resolve
    agent_tokens_apply
    broker_callers_apply
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
# The secrets the MCP broker holds for its two static callers (TOKENFUSE_MCP_KEYS), the ones the gateway's keys must repeat.
SECRET_SS="$(fixture_secret)"
SECRET_DB="$(fixture_secret)"
# A box's .env as the broker's keys section leaves it: the broker's two callers, bare as add_env_default writes them
# (the stub reads the quoted form, so this one is quoted).
write_env() { printf "TOKENFUSE_MCP_KEYS='%s:stack-single,%s:drills-broker'\n" "$SECRET_SS" "$SECRET_DB" >"$1/.env"; }
CALLER_BINDS='{"key_id":"stack-single","unit":"install-check","agents":["agent://local.invalid/install-check"]},{"key_id":"drills-broker","unit":"drills","agents":["agent://mockryx.local/*"]}'
MAP_BINDS='{"units":[{"id":"console"},{"id":"agents"},{"id":"drills"},{"id":"install-check"}],"keys":[{"key_id":"agents","unit":"agents","agents":["agent://local/agents/*"]},{"key_id":"broker","unit":"console","agents":["agent://local/agents/*"]},'"$CALLER_BINDS"']}'
# Binds unit agents, but no broker.
MAP_AGENTS_NO_BROKER='{"units":[{"id":"console"},{"id":"agents"},{"id":"drills"},{"id":"install-check"}],"keys":[{"key_id":"agents","unit":"agents","agents":["agent://local/agents/*"]},'"$CALLER_BINDS"']}'
# Binds broker, but nothing in unit agents, the unit the installer enrols the operator agent in at vouchryx.
MAP_NO_AGENTS_UNIT='{"units":[{"id":"console"},{"id":"drills"},{"id":"install-check"}],"keys":[{"key_id":"broker","unit":"console","agents":["agent://local/agents/*"]},'"$CALLER_BINDS"']}'
MAP_NO_BROKER='{"units":[{"id":"console"}],"keys":[{"key_id":"felyx","unit":"console","agents":["agent://local/genaryx/felyx"]}]}'

# A. the keys file has the broker line
d="$(mktemp -d "$scratch/a.XXXXXX")"; mkdir -p "$d/keys"
printf '%s:felyx\n%s:broker\n%s:stack-single\n%s:drills-broker\n' "$SECRET_A" "$SECRET_BROKER" "$SECRET_SS" "$SECRET_DB" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
write_env "$d"
before="$(cat "$d/keys.txt")"
run_case "A" "$d" "$d/keys.txt" "$d/map.json" ""
if [ "$RC" -ne 0 ] || ! grep -qx APPLIED <<<"$OUT"; then
  fail "A. a keys file with a '<secret>:broker' line was refused: $OUT"
else
  got="$(cat "$d/broker/key" 2>/dev/null || true)"
  [ "$got" = "$SECRET_BROKER" ] || fail "A. the broker key file does not hold the secret of the keys file's broker line"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "A. the keys file was changed although it had the broker line"
  grep -qx 'SPEC_IS_THE_FILE=yes' <<<"$OUT" \
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
  grep -q 'ADD_BROKER_KEY=1' <<<"$OUT" || fail "B. the refusal does not name ADD_BROKER_KEY=1: $OUT"
  grep -q '<secret>:broker' <<<"$OUT" || fail "B. the refusal does not name the '<secret>:broker' form: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "B. the keys file changed on a refusal"
fi

# C. no broker line, ADD_BROKER_KEY=1, the map binds broker: append, keep the mode, use the secret
d="$(mktemp -d "$scratch/c.XXXXXX")"
printf '%s:felyx\n' "$SECRET_A" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
write_env "$d"
run_case "C" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -ne 0 ] || ! grep -qx APPLIED <<<"$OUT"; then
  fail "C. ADD_BROKER_KEY=1 with a binding map was refused: $OUT"
else
  last="$(sed -n 2p "$d/keys.txt")"
  case "$last" in *:broker) ;; *) fail "C. the keys file's second line is not the appended ':broker' line after ADD_BROKER_KEY=1" ;; esac
  # And the lines of the broker's two static callers (invariant 75), after it, with the broker's own secrets.
  [ "$(sed -n 3p "$d/keys.txt")" = "$SECRET_SS:stack-single" ] && [ "$(sed -n 4p "$d/keys.txt")" = "$SECRET_DB:drills-broker" ] \
    || fail "C. the keys file does not end with the lines of the broker's static callers, in the broker's secrets"
  [ "$(wc -l <"$d/keys.txt" | tr -d ' ')" = 4 ] || fail "C. the keys file does not hold exactly the felyx line, the appended broker line and the two callers' lines"
  [ "$(mode_of "$d/keys.txt")" = 640 ] || fail "C. the keys file's mode changed from 640 to $(mode_of "$d/keys.txt")"
  appended="${last%:broker}"
  got="$(cat "$d/broker/key" 2>/dev/null || true)"
  [ -n "$got" ] && [ "$got" = "$appended" ] || fail "C. the broker key file does not hold the secret the line appended"
  # Section 3e checks the map against the keys this run read; the line appended here must be among them, or
  # a map that binds broker (which ADD_BROKER_KEY=1 requires) is refused for a key no client carries.
  # Measured on forge 2026-10-25: the run appended the line, then refused its own map.
  grep -qx 'SPEC_IS_THE_FILE=yes' <<<"$OUT" \
    || fail "C. the keys section 3e checks against the map lack the appended broker line ($(printf '%s' "$OUT" | grep '^SPEC_IDS=')), so the map's broker binding is refused"
fi

# D. ADD_BROKER_KEY=1 but the map does not bind broker: refused, and the keys file is untouched
d="$(mktemp -d "$scratch/d.XXXXXX")"
printf '%s:felyx\n' "$SECRET_A" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
# The map binds unit agents (case G's check passes), so only the broker check can refuse it.
printf '%s\n' "$MAP_AGENTS_NO_BROKER" >"$d/map.json"
write_env "$d"
before="$(cat "$d/keys.txt")"
run_case "D" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -eq 0 ]; then
  fail "D. ADD_BROKER_KEY=1 was accepted with an identity map that does not bind broker"
else
  grep -q 'does not bind key_id broker' <<<"$OUT" || fail "D. the refusal does not say the map does not bind broker: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "D. the keys file was appended although the map does not bind broker"
fi

# G. the map binds broker but nothing in unit agents. vouchryx enrols the operator agent in unit agents, so the
# gateway would refuse that agent's token as unit_contradicts_map (measured on forge 2026-10-25: 403 for a valid
# token). Refused before anything is written, naming unit agents, and the keys file is untouched.
d="$(mktemp -d "$scratch/g.XXXXXX")"
printf '%s:felyx\n%s:broker\n%s:stack-single\n%s:drills-broker\n' "$SECRET_A" "$SECRET_BROKER" "$SECRET_SS" "$SECRET_DB" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_NO_AGENTS_UNIT" >"$d/map.json"
write_env "$d"
before="$(cat "$d/keys.txt")"
run_case "G" "$d" "$d/keys.txt" "$d/map.json" ""
if [ "$RC" -eq 0 ]; then
  fail "G. a map with no binding in unit agents was accepted, so the enrolled operator agent's token would be refused"
else
  grep -q 'unit agents' <<<"$OUT" || fail "G. the refusal does not name unit agents: $OUT"
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
    if grep -q 'unbound variable' <<<"$OUT"; then
      fail "$label. the installer read an unset CLIENT_KEYS_FILE: $(printf '%s' "$OUT" | grep 'unbound variable' | head -1)"
    fi
    [ "$RC" -eq 3 ] || fail "$label. it stopped with exit $RC, not the installer's refusal"
    grep -q 'kept in .env' <<<"$OUT" || fail "$label. the refusal does not say the keys are kept in .env"
    grep -q 'CLIENT_KEYS_FILE=' <<<"$OUT" || fail "$label. the refusal does not name CLIENT_KEYS_FILE as the way to add the broker's line"
    grep -q 'WITH_AGENT_TOKENS=0' <<<"$OUT" || fail "$label. the refusal does not name WITH_AGENT_TOKENS=0"
    if grep -q 'gave its own CLIENT_KEYS_FILE' <<<"$OUT"; then
      fail "$label. the refusal says this run gave a CLIENT_KEYS_FILE, which it did not"
    fi
  fi
  [ "$(cat "$d/.env")" = "$before" ] || fail "$label. .env changed on a refusal"
done

# H. CLAUDE.md invariant 75: every static key the broker admits is a gateway key of the same id and secret.
# H1. the file has the broker line and nothing for the two callers, and no ADD_BROKER_KEY: refused, naming both ids
# and the way out, with the file and .env as they were.
d="$(mktemp -d "$scratch/h1.XXXXXX")"
printf '%s:felyx\n%s:broker\n' "$SECRET_A" "$SECRET_BROKER" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
write_env "$d"
before="$(cat "$d/keys.txt")"; before_env="$(cat "$d/.env")"
run_case "H1" "$d" "$d/keys.txt" "$d/map.json" ""
if [ "$RC" -eq 0 ]; then
  fail "H1. a keys file with no line for the broker's static callers was accepted with no ADD_BROKER_KEY"
else
  grep -q 'stack-single' <<<"$OUT" && grep -q 'drills-broker' <<<"$OUT" || fail "H1. the refusal does not name both ids: $OUT"
  grep -q 'ADD_BROKER_KEY=1' <<<"$OUT" || fail "H1. the refusal does not name ADD_BROKER_KEY=1: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "H1. the keys file changed on a refusal"
  [ "$(cat "$d/.env")" = "$before_env" ] || fail "H1. .env changed on a refusal"
fi
# H2. ADD_BROKER_KEY=1: both lines appended with the broker's secrets, the mode kept; H5: a second run changes nothing.
d="$(mktemp -d "$scratch/h2.XXXXXX")"
printf '%s:felyx\n%s:broker\n' "$SECRET_A" "$SECRET_BROKER" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
write_env "$d"
run_case "H2" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -ne 0 ] || ! grep -qx APPLIED <<<"$OUT"; then
  fail "H2. ADD_BROKER_KEY=1 did not add the callers' lines: $OUT"
else
  [ "$(tail -2 "$d/keys.txt" | head -1)" = "$SECRET_SS:stack-single" ] && [ "$(tail -1 "$d/keys.txt")" = "$SECRET_DB:drills-broker" ] \
    || fail "H2. the appended lines are not the broker's own secrets for stack-single and drills-broker"
  [ "$(mode_of "$d/keys.txt")" = 640 ] || fail "H2. the keys file's mode changed from 640 to $(mode_of "$d/keys.txt")"
  grep -qx 'SPEC_IS_THE_FILE=yes' <<<"$OUT" || fail "H2. the keys section 3e checks lack the appended lines"
  if grep -qF -- "$SECRET_SS" <<<"$OUT" || grep -qF -- "$SECRET_DB" <<<"$OUT"; then fail "H2. a secret was printed"; fi
  cp "$d/keys.txt" "$d/keys.after1"
  run_case "H5" "$d" "$d/keys.txt" "$d/map.json" "1"
  if [ "$RC" -ne 0 ]; then fail "H5. a second run over the file ADD_BROKER_KEY=1 left was refused: $OUT"
  else cmp -s "$d/keys.txt" "$d/keys.after1" || fail "H5. a second run changed the keys file (it added the lines twice or rewrote them)"; fi
fi
# H3. a line for stack-single with another secret than the broker's: refused, nothing rewritten.
d="$(mktemp -d "$scratch/h3.XXXXXX")"
printf '%s:felyx\n%s:broker\n%s:stack-single\n%s:drills-broker\n' "$SECRET_A" "$SECRET_BROKER" "$(fixture_secret)" "$SECRET_DB" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' "$MAP_BINDS" >"$d/map.json"
write_env "$d"
before="$(cat "$d/keys.txt")"
run_case "H3" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -eq 0 ]; then
  fail "H3. a keys file whose stack-single line holds another secret than the broker's was accepted"
else
  grep -q 'different secret' <<<"$OUT" && grep -q 'stack-single' <<<"$OUT" || fail "H3. the refusal does not name the id and the different secret: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "H3. the keys file was rewritten"
fi
# H4. a map that binds broker and agents but not stack-single: refused before the keys file is touched.
d="$(mktemp -d "$scratch/h4.XXXXXX")"
printf '%s:felyx\n' "$SECRET_A" >"$d/keys.txt"; chmod 0640 "$d/keys.txt"
printf '%s\n' '{"units":[{"id":"console"},{"id":"agents"},{"id":"drills"}],"keys":[{"key_id":"agents","unit":"agents","agents":["agent://local/agents/*"]},{"key_id":"broker","unit":"console","agents":["agent://local/agents/*"]},{"key_id":"drills-broker","unit":"drills","agents":["agent://mockryx.local/*"]}]}' >"$d/map.json"
write_env "$d"
before="$(cat "$d/keys.txt")"
run_case "H4" "$d" "$d/keys.txt" "$d/map.json" "1"
if [ "$RC" -eq 0 ]; then
  fail "H4. ADD_BROKER_KEY=1 was accepted with a map that does not bind stack-single"
else
  grep -q 'does not bind key_id stack-single' <<<"$OUT" || fail "H4. the refusal does not say the map does not bind stack-single: $OUT"
  [ "$(cat "$d/keys.txt")" = "$before" ] || fail "H4. the keys file was appended although the map does not bind stack-single"
fi

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
