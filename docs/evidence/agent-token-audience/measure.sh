#!/usr/bin/env bash
#
# Measures the agent-token audience rule (CLAUDE.md invariant 40) on a running stack.
# It needs the stack that RUN.md describes: vouchryx v0.6.0 with the enrolled agent,
# the gateway and the MCP broker with TOKENFUSE_AGENT_TOKENS=accept. Nothing here starts
# or stops a container.
#
#   ENROL_SECRET   the enrolment secret whose SHA-256 digest is in VOUCHRYX_AGENTS
#   VX_URL         vouchryx on the host, e.g. http://127.0.0.1:14310
#   AUDIENCE       the one https audience both doors share, e.g. https://stack-single.local
#   WORK           a directory for the DPoP key and the issued token (created if absent)
#
# Exits 0 when every expectation holds, 1 otherwise.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${ENROL_SECRET:?set ENROL_SECRET to the enrolment secret}"
: "${VX_URL:=http://127.0.0.1:14310}"
: "${AUDIENCE:?set AUDIENCE to the https audience}"
: "${GATEWAY_URL:=http://127.0.0.1:4100}"
: "${BROKER_URL:=http://127.0.0.1:4200}"
: "${WORK:=$(mktemp -d)}"
mkdir -p "$WORK"
agent="agent://local/agents/operator"
htu_token="http://vouchryx:4310/v1/token"
bad=0
expect() { # NAME GOT WANT
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got $2, want $3"; bad=$((bad + 1)); fi
}
json() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$2" <<<"$1"; }
# has STATUS BODY-SUBSTRING OUTPUT: the admission call answered STATUS and its body holds the substring
has() { python3 -c 'import json,sys;d=json.load(sys.stdin);print("yes" if str(d["status"])==sys.argv[1] and sys.argv[2] in d["body"] else "no")' "$1" "$2" <<<"$3"; }
cd "$here" || exit 1

echo "== 1. token exchange, with resource=$AUDIENCE"
out="$(ENROL_SECRET="$ENROL_SECRET" python3 dpop_exchange.py "$VX_URL" "$agent" "$htu_token" "$AUDIENCE" "$WORK/dpop.pem" "$WORK/token" )"
echo "$out"
expect "with resource: status" "$(json "$out" status)" "200"
expect "with resource: token_type" "$(json "$(python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["body"]))' <<<"$out")" token_type)" "DPoP"
expect "with resource: a token was written" "$([ -s "$WORK/token" ] && echo yes || echo no)" "yes"

echo "== 2. token exchange, with no resource"
out="$(ENROL_SECRET="$ENROL_SECRET" python3 dpop_exchange.py "$VX_URL" "$agent" "$htu_token" - "$WORK/dpop.pem")"
echo "$out"
expect "no resource: status" "$(json "$out" status)" "400"
expect "no resource: error" "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["body"].get("error",""))' <<<"$out")" "invalid_target"

GBODY='{"model":"claude-test","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
RPC='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
python3 - "$WORK" <<'PY'
import base64, sys
w = sys.argv[1]
t = open(w + "/token").read().strip()
h, p, s = t.split(".")
sig = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
bad = bytes([sig[0] ^ 1]) + sig[1:]
open(w + "/token.tampered", "w").write(h + "." + p + "." + base64.urlsafe_b64encode(bad).rstrip(b"=").decode())
PY

echo "== 3. the gateway with the issued token (a run id is sent, so a call that passes the door reaches the budget step)"
# BUDGET_USD, when set, is sent as the run's budget: a micro-dollar budget is refused 402 past identity, so the
# admitted call needs no provider. Without it the call reaches the budget step with the cloud not running (503).
XH="x-fuse-run-id: measure-run-1"
if [ -n "${BUDGET_USD:-}" ]; then XH="$XH"$'\n'"x-fuse-budget-usd: $BUDGET_USD"; fi
out="$(XHDR="$XH" python3 admit.py "$GATEWAY_URL/v1/messages" POST "$WORK/token" "$WORK/dpop.pem" "$GBODY")"
echo "$out"
if [ -n "${BUDGET_USD:-}" ]; then
  expect "gateway, good token: admitted past the agent-token check (402: refused by the budget, past identity)" "$(has 402 "" "$out")" "yes"
else
  expect "gateway, good token: admitted past the agent-token check (503 seed_pending: the budget step, cloud not running)" "$(has 503 seed_pending "$out")" "yes"
fi
echo "== 4. the gateway with a tampered token"
out="$(python3 admit.py "$GATEWAY_URL/v1/messages" POST "$WORK/token.tampered" "$WORK/dpop.pem" "$GBODY")"
echo "$out"
expect "gateway, tampered token: refused as an agent token (401)" "$(has 401 agent_token_refused "$out")" "yes"

echo "== 5. the broker with the issued token"
out="$(python3 admit.py "$BROKER_URL/mcp" POST "$WORK/token" "$WORK/dpop.pem" "$RPC")"
echo "$out"
expect "broker, good token: admitted (200, JSON-RPC answer)" "$(has 200 jsonrpc "$out")" "yes"
echo "== 6. the broker with a tampered token"
out="$(python3 admit.py "$BROKER_URL/mcp" POST "$WORK/token.tampered" "$WORK/dpop.pem" "$RPC")"
echo "$out"
expect "broker, tampered token: refused as an agent token (401)" "$(has 401 agent_token_refused "$out")" "yes"

echo "== 7. the broker asks typryx with the agent's own token: a tools/call answered, not refused by the agent-token door"
# The D3(b) path: the door asks wardryx with the token and its proof (wardryx 2.3.0). typryx's stub answers.
ASK='{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ask","arguments":{"template":"eval.outcome_met","state":{"task":"2+2","final_answer":"4"}},"_meta":{"typryx/key":"{{secret:typryx_key}}"}}}'
XH="X-Fuse-Mcp-Upstream: typryx"$'\n'"x-fuse-agent-id: $agent"
out="$(XHDR="$XH" python3 admit.py "$BROKER_URL/mcp" POST "$WORK/token" "$WORK/dpop.pem" "$ASK")"
echo "$out"
answered() { python3 -c 'import json,sys;d=json.load(sys.stdin);b=d["body"];print("yes" if d["status"]==200 and "jsonrpc" in b and not any(x in b for x in ("agent_token_proof_invalid","agent_token_invalid","agent_token_required")) else "no")' <<<"$1"; }
expect "broker, tools/call ask with the agent's token: answered, not refused by the agent-token door" "$(answered "$out")" "yes"

echo
if [ "$bad" -eq 0 ]; then echo "OK: every expectation holds"; exit 0; fi
echo "FAIL: $bad expectation(s) did not hold"; exit 1
