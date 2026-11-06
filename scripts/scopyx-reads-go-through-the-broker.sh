#!/usr/bin/env bash
#
# Enforces the G2.1 wiring (CLAUDE.md invariant 55): a read of the web by an agent passes the
# MCP broker, which labels the run from the act, and no agent holds the key that opens scopyx.
#
# WHY
#
# Until tokenfuse 1.21.0 the `web` label of a run came from a tool NAME the agent reported, so a
# fetch under a name the policy trusted carried no label (GAPS G2.1). From 1.21.0 the broker
# reports the act: after a classified upstream answers, it tells the gateway which server
# answered, and the label follows that. It only works if the read cannot go round the broker, so
# scopyx is on no network an agent is on, the key that opens it is in the broker's vault and never
# in the agent's hands, and the broker is the only caller that resolves it.
#
# WHAT THIS CHECKS
#
#   A. THE BROKER. It runs under `typed` and under both egress profiles; its upstream list names
#      scopyx at http://scopyx:4300; its classification reads BROKER_UPSTREAM_LABELS and no
#      literal (a literal label on a broker with no taint gateway exits 2, and a box with agent
#      tokens off would lose its typed plane over it); the taint gateway and its key file are
#      still read from .env; its secret scopes read .env and default to the one entry a box had
#      before; typryx is a soft dependency, because under an egress profile alone it is not there.
#   B. SCOPYX AND THE BROWSER. Both take the key in params._meta, and neither is on the agents
#      network. The browser answers to the name `scopyx` on the network it shares with the broker.
#   C. THE INSTALLER'S LABELS. BROKER_UPSTREAM_LABELS is written beside BROKER_TAINT_GATEWAY, as
#      `scopyx=web`, and forgotten with it when agent tokens are off. WITH_EGRESS or WITH_BROWSER
#      with agent tokens off is refused before anything is installed, run for real: the broker's
#      key for the gateway exists only with agent tokens.
#   D. THE KEY OF EACH AGENT. The `# scopyx-broker-keys:` block of install.sh is lifted out and run
#      against scratch .env files. One key per agent lands in three lines that agree: the vault
#      (scopyx_key_<agent>), the rule that lets only that agent resolve it and only for browse and
#      fetch_url, and scopyx's own key list as <key>=<agent>. What a box had stays; a second run
#      changes nothing; a changed trust domain moves the agent and keeps the key; agent tokens off
#      change nothing; nothing prints the key.
#
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

[ -f compose.yaml ] && [ -f install.sh ] || fail "compose.yaml or install.sh is missing, so this measured nothing"

# service_block NAME: the text of one top-level service of compose.yaml
service_block() {
  awk -v n="  $1:" '
    $0 == n { on = 1; print; next }
    on && /^  [a-zA-Z0-9_-]+:/ { exit }
    on && /^[a-z]/ { exit }
    on { print }
  ' compose.yaml
}

BROKER="$(service_block tokenfuse-mcp-broker)"
SCOPYX="$(service_block scopyx)"
BROWSER="$(service_block scopyx-browser)"
[ -n "$BROKER" ] || fail "compose.yaml has no tokenfuse-mcp-broker, so the broker's wiring measured nothing"
[ -n "$SCOPYX" ] || fail "compose.yaml has no scopyx, so its wiring measured nothing"
[ -n "$BROWSER" ] || fail "compose.yaml has no scopyx-browser, so its wiring measured nothing"

# ---- A. the broker ------------------------------------------------------------------
for p in typed egress egress-browser; do
  grep -qE '^    profiles: \[[^]]*"'"$p"'"' <<<"$BROKER" \
    || fail "the MCP broker is not in the $p profile, so a box with that profile has no way for an agent to read the web through it"
done
grep -qE '^      TOKENFUSE_MCP_UPSTREAMS: .*(^|[ ,])scopyx=http://scopyx:4300(,|$)' <<<"$BROKER" \
  || fail "the broker's upstream list does not name scopyx at http://scopyx:4300"
grep -qE '^      TOKENFUSE_MCP_UPSTREAM_LABELS: \$\{BROKER_UPSTREAM_LABELS:-\}$' <<<"$BROKER" \
  || fail "the broker's classification is not read from BROKER_UPSTREAM_LABELS with an empty default: a literal label on a broker with no taint gateway exits 2"
grep -qE '^      TOKENFUSE_MCP_TAINT_GATEWAY: \$\{BROKER_TAINT_GATEWAY:-\}$' <<<"$BROKER" \
  || fail "the broker's taint gateway is not read from BROKER_TAINT_GATEWAY"
grep -qE '^      TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE: \$\{BROKER_GATEWAY_KEY_FILE:-\}$' <<<"$BROKER" \
  || fail "the broker's own gateway key file is not read from BROKER_GATEWAY_KEY_FILE"
grep -qE '^      TOKENFUSE_MCP_SECRET_SCOPES: \$\{TOKENFUSE_MCP_SECRET_SCOPES:-typryx_key=tools:ask\|ask_freeform\|list_questions\}$' <<<"$BROKER" \
  || fail "the broker's secret scopes are not read from .env with the typryx entry as the default, so the scopyx keys carry no per-agent rule"
awk '/^    depends_on:/{on=1} on&&/^      typryx:/{t=1} t&&/required: false/{ok=1} END{exit !ok}' <<<"$BROKER" \
  || fail "the broker depends on typryx without 'required: false': under an egress profile alone typryx is not in the project and compose refuses the file"

# ---- B. scopyx and the browser ----------------------------------------------------------
for pair in "scopyx:$SCOPYX" "scopyx-browser:$BROWSER"; do
  name="${pair%%:*}"; body="${pair#*:}"
  grep -qE '^      SCOPYX_ACCEPT_KEY_IN_META: "1"$' <<<"$body" \
    || fail "$name does not take the key in params._meta (SCOPYX_ACCEPT_KEY_IN_META), so the broker cannot hand it the key"
  nets="$(awk '/^    networks:/{on=1;next} on&&/^    [a-z]/{exit} on{print}' <<<"$body")"
  if grep -qE '^      -? ?agents:?$' <<<"$nets"; then
    fail "$name is on the agents network: an agent would fetch without the broker, and the run would carry no label from the act"
  fi
done
awk '/^      browser-broker:/{on=1;next} on&&/aliases:.*"scopyx"/{ok=1} on&&/^      [a-z]/{on=0} END{exit !ok}' <<<"$BROWSER" \
  || fail "scopyx-browser does not answer to the name scopyx on browser-broker, so the broker's upstream URL does not reach it"

# ---- C. the installer's labels and the egress refusal --------------------------------------------
TOK="$(awk '/^agent_tokens_apply\(\) \{/,/^\}$/' install.sh)"
[ -n "$TOK" ] || fail "install.sh has no agent_tokens_apply, so the labels measured nothing"
grep -qE "^  identity_env_set BROKER_UPSTREAM_LABELS scopyx=web$" <<<"$TOK" \
  || fail "agent_tokens_apply does not write BROKER_UPSTREAM_LABELS as scopyx=web"
grep -qE '^  identity_env_set BROKER_TAINT_GATEWAY ' <<<"$TOK" \
  || fail "agent_tokens_apply does not write BROKER_TAINT_GATEWAY beside the labels"
grep -qE '^      for v in .*BROKER_TAINT_GATEWAY .*BROKER_UPSTREAM_LABELS' <<<"$TOK" \
  || fail "agent_tokens_apply does not forget BROKER_UPSTREAM_LABELS with BROKER_TAINT_GATEWAY when agent tokens are off: the broker would exit 2"

RES="$(awk '/^agent_tokens_resolve\(\) \{/,/^\}$/' install.sh)"
[ -n "$RES" ] || fail "install.sh has no agent_tokens_resolve, so the egress refusal measured nothing"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/scopyx-broker.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# run_resolve ENV...: the real agent_tokens_resolve, with WITH_AGENT_TOKENS=0 and what is given
run_resolve() {
  env -i PATH="$PATH" HOME="$scratch" RES="$RES" "$@" bash -c '
    set -euo pipefail
    die() { printf "die: %s\n" "$*"; exit 2; }
    identity_env_get() { :; }
    identity_env_has() { return 1; }
    eval "$RES"
    agent_tokens_resolve
    printf "ok\n"
  ' 2>&1 || true
}
for w in WITH_EGRESS WITH_BROWSER; do
  out="$(run_resolve WITH_AGENT_TOKENS=0 "$w=1")"
  case "$out" in
    die:*"need agent tokens"*) ;;
    *) fail "$w with agent tokens off is not refused: $out" ;;
  esac
done
out="$(run_resolve WITH_AGENT_TOKENS=0)"
[ "$out" = ok ] || fail "agent tokens off alone is refused: $out"

# ---- D. the key of each agent, lifted out of install.sh and run on scratch .env files ---------------
BLOCK="$(sed -n '/^# scopyx-broker-keys: begin$/,/^# scopyx-broker-keys: end$/p' install.sh)"
# The installer's own generator, lifted: this gate keeps no copy of it (scripts/gen-is-bounded.sh holds it).
GEN="$(sed -n '/^# gen: begin$/,/^# gen: end$/p' install.sh)"
[ -n "$GEN" ] || fail "install.sh has no '# gen: begin' .. 'end' block, so the key of each agent could not be minted by the installer's generator"
[ -n "$BLOCK" ] || fail "install.sh has no '# scopyx-broker-keys: begin' .. 'end' block, so the key of each agent measured nothing"
grep -q '^scopyx_broker_keys_apply() {' <<<"$BLOCK" \
  || fail "the scopyx-broker-keys block defines no scopyx_broker_keys_apply, so the key of each agent measured nothing"

TYP="typryxsecret0123456789ABCDEFGHIJKLMNOP"
OLD="oldscopyxkey0123456789ABCDEFGHIJKLMNOP"
AG1="agent://alpha.example/agents/operator"
AG2="agent://beta.example/agents/operator"

# The two .env helpers of install.sh, as they are there: identity_env_get strips one pair of single quotes,
# identity_env_set writes NAME='VALUE'. Kept in a file so their quotes are the real ones.
cat >"$scratch/helpers.sh" <<'HELPERS'
identity_env_get() { local v; v="$(sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env")"; v="${v#\'}"; v="${v%\'}"; printf '%s' "$v"; }
identity_env_set() { local t; t="$(mktemp)"; { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$t"; printf "%s='%s'\n" "$1" "$2" >>"$t"; cat "$t" >"$STACK_DIR/.env"; rm -f "$t"; }
HELPERS

# run_keys DIR TOKENS_ON AGENT: runs the block in DIR with the .env it holds; prints what it said
run_keys() {
  local d="$1" on="$2" agent="$3"
  ( cd "$d" && env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" ON="$on" AGENT="$agent" HELPERS="$scratch/helpers.sh" GEN="$GEN" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$GEN"
      . "$HELPERS"
      AGENT_TOKENS_ON="$ON"; AGENT_TOKEN_AGENT="$AGENT"
      eval "$BLOCK"
      scopyx_broker_keys_apply
    ' 2>&1 )
}
# val DIR NAME: what .env holds for NAME, quotes removed
val() { ( cd "$1" && sed -n "/^$2=/{s///p;q;}" .env | sed -e "s/^'//" -e "s/'\$//" ); }
# items STRING: one comma-separated item per line
items() { tr ',' '\n' <<<"$1"; }

# a box as install.sh leaves it before this block: the typryx secret and scope, scopyx's one default key
mkbox() {
  mkdir -p "$1"
  printf 'SENTINEL=1\nSCOPYX_KEYS=%s=agent://local.invalid/default-agent\nTOKENFUSE_MCP_SECRETS=typryx_key=%s\nTOKENFUSE_MCP_SECRET_SCOPES='"'"'typryx_key=tools:ask|ask_freeform|list_questions'"'"'\nTAIL=last\n' \
    "$OLD" "$TYP" >"$1/.env"
}

# D1: a fresh box gets one key in three agreeing places, and what it had stays
d="$scratch/fresh"; mkbox "$d"
out="$(run_keys "$d" 1 "$AG1")" || fail "the block refused a fresh box: $out"
vault="$(val "$d" TOKENFUSE_MCP_SECRETS)"
key="$(items "$vault" | sed -n 's/^scopyx_key_operator=//p')"
[ -n "$key" ] || fail "the vault holds no scopyx_key_operator after the block ran: $vault"
grep -qx "typryx_key=$TYP" <<<"$(items "$vault")" || fail "the block dropped the typryx secret from the vault: $vault"
scopes="$(val "$d" TOKENFUSE_MCP_SECRET_SCOPES)"
grep -qx 'typryx_key=tools:ask|ask_freeform|list_questions' <<<"$(items "$scopes")" || fail "the block dropped the typryx scope: $scopes"
grep -qx "scopyx_key_operator=agents:$AG1;tools:browse|fetch_url" <<<"$(items "$scopes")" \
  || fail "the scope of the scopyx key is not 'agents:<that agent>;tools:browse|fetch_url' (an agent resolving it for another agent, or for another tool, would fetch as that agent): $scopes"
keys="$(val "$d" SCOPYX_KEYS)"
grep -qx "$key=$AG1" <<<"$(items "$keys")" || fail "scopyx's key list does not pair the vault's key with the agent, as <key>=<agent>: it cannot name who fetched"
grep -qx "$OLD=agent://local.invalid/default-agent" <<<"$(items "$keys")" || fail "the block dropped the key a box already had from scopyx's list"
grep -qx 'SENTINEL=1' "$d/.env" && grep -qx 'TAIL=last' "$d/.env" || fail "the block rewrote a line it has no business with"
case "$out" in *"$key"*) fail "the block printed the scopyx key" ;; esac

# D2: a second run changes nothing, not even the bytes
cp "$d/.env" "$scratch/fresh.before"
out="$(run_keys "$d" 1 "$AG1")" || fail "the block refused a second run: $out"
cmp -s "$d/.env" "$scratch/fresh.before" || fail "a second run changed .env: the key was minted again or an entry was written twice"
[ "$(items "$(val "$d" TOKENFUSE_MCP_SECRETS)" | grep -c '^scopyx_key_operator=')" = 1 ] || fail "the vault holds more than one scopyx_key_operator"

# D3: a changed trust domain moves the agent and keeps the key, with no stale entry left
out="$(run_keys "$d" 1 "$AG2")" || fail "the block refused a changed trust domain: $out"
[ "$(items "$(val "$d" TOKENFUSE_MCP_SECRETS)" | sed -n 's/^scopyx_key_operator=//p')" = "$key" ] || fail "a changed trust domain changed the key"
scopes="$(val "$d" TOKENFUSE_MCP_SECRET_SCOPES)"
[ "$(items "$scopes" | grep -c '^scopyx_key_operator=')" = 1 ] || fail "a changed trust domain left two scope entries for the key: $scopes"
grep -qx "scopyx_key_operator=agents:$AG2;tools:browse|fetch_url" <<<"$(items "$scopes")" || fail "the scope did not follow the new agent: $scopes"
keys="$(val "$d" SCOPYX_KEYS)"
[ "$(items "$keys" | grep -c "^$key=")" = 1 ] || fail "a changed trust domain left two entries for the key in scopyx's list: $keys"
grep -qx "$key=$AG2" <<<"$(items "$keys")" || fail "scopyx's list did not follow the new agent: $keys"

# D4: agent tokens off changes nothing
d="$scratch/off"; mkbox "$d"; cp "$d/.env" "$scratch/off.before"
run_keys "$d" 0 "" >/dev/null || fail "the block refused a box with agent tokens off"
cmp -s "$d/.env" "$scratch/off.before" || fail "agent tokens off, and the block still wrote scopyx keys: there is no broker key for the gateway, so no read could be labelled"

# D5: a key already in the vault is the key: it is used, not replaced
d="$scratch/kept"; mkbox "$d"
KEPT="keptscopyx0123456789ABCDEFGHIJKLMNOPQ"
sed -i.bak "s|^TOKENFUSE_MCP_SECRETS=.*|TOKENFUSE_MCP_SECRETS=typryx_key=$TYP,scopyx_key_operator=$KEPT|" "$d/.env"; rm -f "$d/.env.bak"
run_keys "$d" 1 "$AG1" >/dev/null || fail "the block refused a vault that already holds the key"
[ "$(items "$(val "$d" TOKENFUSE_MCP_SECRETS)" | sed -n 's/^scopyx_key_operator=//p')" = "$KEPT" ] || fail "the block replaced a key the box already had"
grep -qx "$KEPT=$AG1" <<<"$(items "$(val "$d" SCOPYX_KEYS)")" || fail "scopyx's list does not carry the key the vault already held"

# D6: a vault key that is not a plain secret is refused, and nothing is written
d="$scratch/bad"; mkbox "$d"
sed -i.bak "s|^TOKENFUSE_MCP_SECRETS=.*|TOKENFUSE_MCP_SECRETS=typryx_key=$TYP,scopyx_key_operator=short|" "$d/.env"; rm -f "$d/.env.bak"
cp "$d/.env" "$scratch/bad.before"
if out="$(run_keys "$d" 1 "$AG1")"; then fail "a vault key of 5 characters was accepted"; fi
cmp -s "$d/.env" "$scratch/bad.before" || fail "a refused key still changed .env"

echo "OK: scopyx-reads-go-through-the-broker (invariant 55): the broker fronts scopyx under typed and both egress profiles with labels that follow its taint gateway; scopyx and the browser take the key in _meta and are on no agent network; egress with agent tokens off is refused; one key per agent is in the vault, scoped to that agent and to browse and fetch_url, and in scopyx's list, kept by a re-run and never printed"
