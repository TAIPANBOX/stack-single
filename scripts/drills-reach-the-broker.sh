#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 74: the fire drills reach the MCP broker with a key of the broker's own, and a
# person runs them.
#
# WHY
#
# mockryx's broker drills (a raw secret in tool arguments, personal data in tool arguments, the tool hold) were
# never run against this box's broker: the launcher had no drill service, and mockryx sent the broker no key, so a
# broker that requires one answered every drill with a 401 (estate-gates GAPS G4.10). mockryx 0.5.0 reads a key
# of the broker's own from a file and sends it to the broker alone. This launcher mints that key, puts it on the
# broker's list and in a file, and gives a person one command that runs the drills.
#
# WHAT THIS CHECKS
#
#   A. THE SERVICE. compose.yaml's mockryx-drill sits behind the `manual` profile, runs the pinned mockryx image by
#      digest as 65532:10001, is on `core` alone, mounts drills/broker.key read only at the path
#      MOCKRYX_MCP_BROKER_KEY_FILE names, names the broker by its service name, carries no gateway client key, and
#      runs /scenarios/mcp, the broker drills, and nothing else.
#   A2. THIS BOX'S TOOL-HOLD DRILL. mockryx's own asks its second call for a result, which needs an MCP server that
#      answers `search_notes`, and this box has none, so it would be red on every box. The service mounts
#      drill-scenarios/mcp-ungranted-tool-held.yaml over it: a name of its own, the same first step (an id under
#      ungranted.invalid held, -32004 naming when_no_grant), and a second step as a drill identity carrying the
#      typed plane's secret handle, which gets past the hold and is refused by the vault (-32008), so it reaches no
#      server. The broker's default scopes must keep that handle off search_notes, and a piped install must fetch
#      the file.
#   B. THE IMAGE. Section 3c of install.sh resolves mockryx-drill's image by naming the service (never by passing
#      its profile) and checks its signature before it pulls it.
#   C. THE LIST. agent_static_keys_apply names the drills' key on the broker's static list.
#   D. THE KEY. The `# drills-broker-key:` block of install.sh is lifted out and run against scratch .env files with
#      chown recorded: a fresh box gets one `<secret>:drills-broker` entry appended and every earlier entry kept byte
#      for byte, and the same secret in drills/broker.key, given to uid 65532, mode 0400; a second run changes
#      nothing; a box that lost the file gets it back from .env, and a box that lost the entry gets it back from the
#      file; two entries, a malformed secret, a secret another broker key holds and a secret the gateway holds are
#      each refused; nothing prints the secret.
#
# It refuses to report OK on no service, no block, no call or no list to read.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

[ -f compose.yaml ] && [ -f install.sh ] || fail "compose.yaml or install.sh is missing, so this measured nothing"

service_block() {
  awk -v n="  $1:" '
    $0 == n { on = 1; print; next }
    on && /^  [a-zA-Z0-9_-]+:/ { exit }
    on && /^[a-z]/ { exit }
    on { print }
  ' compose.yaml
}

DRILL="$(service_block mockryx-drill)"
[ -n "$DRILL" ] || fail "compose.yaml has no mockryx-drill, so the drills' wiring measured nothing"

# ---- A. the service -----------------------------------------------------------------
grep -qE '^    profiles: \["manual"\]$' <<<"$DRILL" \
  || fail "mockryx-drill is not behind the manual profile alone, so an install could start it"
grep -qE '^    image: \$\{MOCKRYX_IMAGE:-ghcr\.io/taipanbox/mockryx:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}\}$' <<<"$DRILL" \
  || fail "mockryx-drill does not run a pinned ghcr.io/taipanbox/mockryx image by digest"
v="$(sed -nE 's/^    image: .*mockryx:v([0-9]+)\.([0-9]+)\.[0-9]+@.*/\1 \2/p' <<<"$DRILL")"
read -r major minor <<<"$v"
{ [ "${major:-0}" -gt 0 ] || [ "${minor:-0}" -ge 5 ]; } \
  || fail "mockryx-drill pins mockryx v${major:-?}.${minor:-?}, older than v0.5.0, the first that sends the broker a key of its own"
grep -qE '^    user: "65532:10001"$' <<<"$DRILL" || fail "mockryx-drill does not run as 65532:10001, the uid its key file is given to"
nets="$(awk '/^    networks:/{on=1;next} on&&/^      - /{print $2;next} on{exit}' <<<"$DRILL" | tr '\n' ' ')"
[ "$nets" = "core " ] || fail "mockryx-drill is on '${nets}', not on core alone: it reaches the broker and the gateway by name and nothing else"
grep -qE '^      - \./drills/broker\.key:/run/drills/broker\.key:ro$' <<<"$DRILL" \
  || fail "mockryx-drill does not mount drills/broker.key read only at /run/drills/broker.key"
grep -qE '^      MOCKRYX_MCP_BROKER_KEY_FILE: /run/drills/broker\.key$' <<<"$DRILL" \
  || fail "mockryx-drill does not read the broker key from the file it mounts (MOCKRYX_MCP_BROKER_KEY_FILE)"
grep -qE '^      MOCKRYX_MCP_BROKER: http://tokenfuse-mcp-broker:4200/mcp$' <<<"$DRILL" \
  || fail "mockryx-drill does not name this box's broker, http://tokenfuse-mcp-broker:4200/mcp"
if grep -qE 'MOCKRYX_CLIENT_KEY|MOCKRYX_MCP_BROKER_KEY:|GATEWAY_DRILLS_KEY|TOKENFUSE_MCP_KEYS' <<<"$DRILL"; then
  fail "mockryx-drill is handed a key by value or the gateway's client key; it takes the broker's key from its file alone"
fi
grep -qE '^    command: \["run", "--gateway", "http://tokenfuse-gateway:4100", "/scenarios/mcp"\]$' <<<"$DRILL" \
  || fail "mockryx-drill does not run the broker drills (/scenarios/mcp) against this box"

# ---- A2. this box's own tool-hold drill, mounted over the image's -----------------------
grep -qE '^      - \./drill-scenarios/mcp-ungranted-tool-held\.yaml:/scenarios/mcp/mcp-ungranted-tool-held\.yaml:ro$' <<<"$DRILL" \
  || fail "mockryx-drill does not mount this box's tool-hold drill over the image's, so its second step asks for a result no server of this box gives and is red on every box"
SCN=drill-scenarios/mcp-ungranted-tool-held.yaml
[ -f "$SCN" ] || fail "$SCN is not in the tree, so this box's tool-hold drill measured nothing"
python3 - "$SCN" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1]).read()
code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
def no(msg):
    print("FAIL: " + msg); sys.exit(1)
m = re.search(r"^name:\s*(\S+)\s*$", code, re.M)
if not m: no(f"{sys.argv[1]} names no scenario")
if m.group(1) == "mcp-ungranted-tool-held":
    no("this box's tool-hold drill carries mockryx's own scenario name; a report could not tell which of the two ran")
if not re.search(r"^requires:\s*tool-hold\s*$", code, re.M): no("this box's tool-hold drill does not declare requires: tool-hold")
steps = re.split(r"^  - name:", code, flags=re.M)[1:]
if len(steps) != 2: no(f"this box's tool-hold drill has {len(steps)} steps, not the two that tell 'an ungranted id is held' from 'everything is held'")
first, second = steps
def want(step, label, pattern, msg):
    if not re.search(pattern, step, re.M): no(f"{label}: {msg}")
for label, step in (("step 1", first), ("step 2", second)):
    want(step, label, r"^      method: tools/call\s*$", "is not a tools/call")
    want(step, label, r"^        name: search_notes\s*$", "does not call search_notes, a tool no secret rule of this box admits")
    want(step, label, r'^          typryx/key: "\{\{secret:typryx_key\}\}"\s*$', "does not carry the {{secret:typryx_key}} handle the vault refuses for this tool")
want(first, "step 1", r"^      agent_id: agent://ungranted\.invalid/", "does not speak as an id under ungranted.invalid, which no grant can name")
want(first, "step 1", r"^      error_code: -32004\s*$", "does not expect the hold, -32004")
want(first, "step 1", r"^      error_contains: when_no_grant\s*$", "does not read when_no_grant, so a deny or another hold would pass")
want(second, "step 2", r"^      agent_id: agent://mockryx\.local/", "does not speak as a drill identity, which grant-drills reaches")
want(second, "step 2", r"^      error_code: -32008\s*$", "does not expect the vault's refusal, -32008, after the hold let it through")
want(second, "step 2", r"^      error_contains: not scoped to agent\s*$", "does not read the vault's own words, so another -32008 would pass")
PY
scopes="$(sed -nE 's/^      TOKENFUSE_MCP_SECRET_SCOPES: \$\{TOKENFUSE_MCP_SECRET_SCOPES:-(.*)\}$/\1/p' compose.yaml | head -1)"
[ -n "$scopes" ] || fail "compose.yaml gives the broker no default secret scopes, so the tool-hold drill's second step measured nothing"
case "$scopes" in
  *typryx_key=tools:*) ;;
  *) fail "the broker's default scopes give typryx_key no tool rule, so the vault would resolve it for search_notes and the drill's second call would reach an upstream" ;;
esac
grep -qE '(^|[|:])search_notes([|;,]|$)' <<<"$scopes" \
  && fail "the broker's default scopes admit search_notes, so the drill's second call would reach an upstream"
grep -qF 'drill-scenarios/mcp-ungranted-tool-held.yaml" \' install.sh \
  || fail "a piped install does not fetch drill-scenarios/mcp-ungranted-tool-held.yaml, so compose would mount a directory where the drill should be"

# ---- B. the image is checked before it is pulled ---------------------------------------
grep -qE 'config --images mockryx-drill' install.sh \
  || fail "install.sh does not resolve mockryx-drill's image, so its signature is never checked and 'docker compose run' pulls it unchecked"
awk '/config --images mockryx-drill/{r=NR} r&&/image_verify "\$drill_img"/&&!v{v=NR} r&&/docker pull -q "\$drill_img"/&&!p{p=NR} END{exit !(r&&v&&p&&r<v&&v<p)}' install.sh \
  || fail "install.sh does not check mockryx-drill's signature before it pulls the image"

# ---- C. the drills' key is on the broker's static list ----------------------------------
grep -qE '^  for id in stack-single "\$DRILLS_BROKER_ID" ' install.sh \
  || fail "agent_static_keys_apply does not name the drills' key on the broker's list, so under require the broker refuses it 401"
awk '/^drills_broker_key_apply$/{d=NR} /^agent_static_keys_apply$/{s=NR} END{exit !(d&&s&&d<s)}' install.sh \
  || fail "drills_broker_key_apply is not called before agent_static_keys_apply, so the first run lists a key the broker does not hold yet"

# ---- D. the key, run for real --------------------------------------------------------------
block="$(awk '/^# drills-broker-key: begin$/{on=1} on{print} /^# drills-broker-key: end$/{exit}' install.sh)"
[ -n "$block" ] && grep -q '^drills_broker_key_apply()' <<<"$block" \
  || fail "install.sh has no '# drills-broker-key:' block with drills_broker_key_apply, so the key measured nothing"
genb="$(awk '/^gen\(\) \{$/{on=1} on{print} /^# gen: end$/{exit}' install.sh)"
[ -n "$genb" ] || fail "install.sh has no gen block to mint with"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
printf '%s\n' "$block" >"$scratch/block.sh"
printf '%s\n' "$genb" >"$scratch/gen.sh"
cat >"$scratch/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
die() { printf '!! %s\n' "$*" >&2; exit 1; }
note() { printf '   %s\n' "$*"; }
chown() { printf 'chown %s\n' "$*" >>"$SCRATCH/chown.log"; }
identity_env_get() { [ -f "$STACK_DIR/.env" ] || return 0; sed -n "s/^$1=//p" "$STACK_DIR/.env" | head -1 | sed "s/^'//; s/'\$//"; }
identity_env_set() {
  local tmp; tmp="$(mktemp)"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf "%s='%s'\n" "$1" "$2" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env"; rm -f "$tmp"
}
. "$SCRATCH/gen.sh"
. "$SCRATCH/block.sh"
drills_broker_key_apply
SH
export SCRATCH="$scratch"
OLD='Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1:stack-single'
GW='Ggggggggggggggggggggggggggggggggggggggg1:felyx'
box() { rm -rf "$scratch/s"; mkdir -p "$scratch/s"; printf "TOKENFUSE_MCP_KEYS='%s'\nGATEWAY_CLIENT_KEYS='%s'\n" "$1" "$2" >"$scratch/s/.env"; : >"$scratch/chown.log"; }
run() { STACK_DIR="$scratch/s" bash "$scratch/run.sh" 2>&1; }
entry() { sed -n -e "s/^TOKENFUSE_MCP_KEYS='\\(.*\\)'\$/\\1/p" -e "t" -e "s/^TOKENFUSE_MCP_KEYS=\\([^']*\\)\$/\\1/p" "$scratch/s/.env"; }

# D1. a fresh box
box "$OLD" "$GW"
out="$(run)" || fail "D1: the block refused a fresh box: $(head -1 <<<"$out")"
keys="$(entry)"
case "$keys" in "$OLD,"*":drills-broker") ;; *) fail "D1: TOKENFUSE_MCP_KEYS did not keep the earlier entry and gain one drills-broker entry after it" ;; esac
sec="${keys#"$OLD,"}"; sec="${sec%:drills-broker}"
[[ "$sec" =~ ^[A-Za-z0-9]{40}$ ]] || fail "D1: the minted drills-broker secret is not 40 letters and digits"
[ -f "$scratch/s/drills/broker.key" ] || fail "D1: drills/broker.key was not written"
[ "$(cat "$scratch/s/drills/broker.key")" = "$sec" ] || fail "D1: drills/broker.key does not hold the secret the broker's entry holds"
[ "$(od -An -c "$scratch/s/drills/broker.key" | tr -d ' \n' | tail -c 2)" != '\n' ] || fail "D1: drills/broker.key ends in a newline, which mockryx would send as part of the key"
grep -qx "chown 65532:10001 $scratch/s/drills/broker.key" "$scratch/chown.log" || fail "D1: drills/broker.key is not given to uid 65532, the mockryx-drill service's"
[ "$(stat -c '%a' "$scratch/s/drills/broker.key" 2>/dev/null || stat -f '%Lp' "$scratch/s/drills/broker.key")" = 400 ] \
  || fail "D1: drills/broker.key is not mode 0400"
grep -qF "$sec" <<<"$out" && fail "D1: the block printed the drills' secret"

# D2. a second run changes nothing
cp "$scratch/s/.env" "$scratch/env1"; cp "$scratch/s/drills/broker.key" "$scratch/key1"
run >/dev/null || fail "D2: a second run was refused"
cmp -s "$scratch/env1" "$scratch/s/.env" || fail "D2: a second run rewrote .env"
cmp -s "$scratch/key1" "$scratch/s/drills/broker.key" || fail "D2: a second run rewrote drills/broker.key"

# D3. a box that lost the file gets it back from .env
rm -f "$scratch/s/drills/broker.key"
run >/dev/null || fail "D3: a box that lost drills/broker.key was refused"
cmp -s "$scratch/key1" "$scratch/s/drills/broker.key" || fail "D3: the file came back with a secret that is not the broker's entry"

# D4. a box that lost the entry gets it back from the file
printf "TOKENFUSE_MCP_KEYS='%s'\nGATEWAY_CLIENT_KEYS='%s'\n" "$OLD" "$GW" >"$scratch/s/.env"
run >/dev/null || fail "D4: a box that lost its drills-broker entry was refused"
[ "$(entry)" = "$OLD,$(cat "$scratch/key1"):drills-broker" ] || fail "D4: the entry came back with a secret that is not the file's"

# D6. a .env whose line is bare, as add_env_default writes it, keeps its line bare: the installer's own check and
# CI read the broker's first key with sed, and a quote in front of it is a wrong key.
rm -rf "$scratch/s"; mkdir -p "$scratch/s"; : >"$scratch/chown.log"
printf "TOKENFUSE_MCP_KEYS=%s\nGATEWAY_CLIENT_KEYS='%s'\n" "$OLD" "$GW" >"$scratch/s/.env"
run >/dev/null || fail "D6: a box whose TOKENFUSE_MCP_KEYS line is bare was refused"
grep -qE "^TOKENFUSE_MCP_KEYS=${OLD},[A-Za-z0-9]{40}:drills-broker\$" "$scratch/s/.env" \
  || fail "D6: a bare TOKENFUSE_MCP_KEYS line was rewritten in another form, or lost its first entry; the first key a reader takes with sed would carry a quote"

# D5. the refusals
refused() { # LABEL KEYS GW NEEDLE
  box "$2" "$3"
  if out="$(run)"; then fail "D5: $1 was not refused"; fi
  grep -qF "$4" <<<"$out" || fail "D5: $1 was refused without saying why ($(head -1 <<<"$out"))"
  grep -qF 'Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1' <<<"$out" && fail "D5: $1 printed the secret"
  return 0
}
refused "two drills-broker entries" "$OLD,Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1:drills-broker,Cccccccccccccccccccccccccccccccccccccccc1:drills-broker" "$GW" "more than one entry"
refused "a secret that is not letters and digits" "$OLD,Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1~x:drills-broker" "$GW" "not 24 to 128 letters and digits"
refused "a secret another broker key holds" "Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1:stack-single,Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1:drills-broker" "$GW" "secret of another entry"
refused "a secret the gateway holds" "$OLD,Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1:drills-broker" "Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1:drills" "also a gateway client key"

echo "OK: the fire drills reach the MCP broker with a key of its own: the service (manual, pinned, 65532, core, key file, /scenarios/mcp, this box's tool-hold drill over the image's), the image checked before its pull, the static list, and the key minted, kept and refused in 9 scratch runs"
