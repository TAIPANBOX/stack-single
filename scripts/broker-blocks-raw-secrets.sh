#!/usr/bin/env bash
#
# Enforces invariant 36 of CLAUDE.md: tokenfuse's MCP broker refuses a raw secret
# in tool arguments, refuses a tool listing its scanner flags, and asks the policy
# plane about every tool call, failing closed when it cannot.
#
# WHAT THIS IS ABOUT
#
# The broker (the typed plane's door on port 4200) runs tokenfuse's own defaults
# unless told otherwise, and three of them are weak for a door that holds a vault
# of real credentials (finding F-009 of the 2026-10-17 review): TOKENFUSE_MCP_DLP
# unset is shadow, which logs a raw secret found in tool arguments and forwards it;
# TOKENFUSE_MCP_SCAN unset is warn, which passes a tool listing the scanner flags;
# and the wardryx hook unset is off, so a tool the policy denies is called anyway
# (measured 2026-10-17 on this launcher's environment: the broker forwarded a denied
# tool and a raw AWS key id). @decided 2026-10-17 (paraphrased): close the
# review's findings, defaults first. So the broker sets DLP and the scan to block,
# its wardryx hook to enforce against wardryx by default, failing closed.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. The subjects are derived from compose.yaml's image and command lines:
#      every service whose image is the tokenfuse image and whose command is the
#      `mcp-broker` subcommand. Each sets TOKENFUSE_MCP_DLP: block,
#      TOKENFUSE_MCP_SCAN: block, TOKENFUSE_WARDRYX_FAILMODE: closed,
#      TOKENFUSE_WARDRYX_MODE to enforce (a literal, or a variable whose default is
#      enforce), TOKENFUSE_WARDRYX_URL to a variable or literal that is not empty by
#      default, and TOKENFUSE_WARDRYX_KEY to a required variable (`${VAR:?...}`).
#   B. RESOLVED. `docker compose config`, with the profiles the broker sits behind and
#      nothing set but the required secrets: the broker reads block, block, enforce,
#      closed, and a URL naming wardryx, a service in the same configuration.
#   C. BEHAVIOUR. The image compose resolves for the broker, run with the four
#      switches compose resolves for it, no network, its policy plane and upstream
#      pointed at nothing: a tools/call carrying a raw AWS key id is refused -32002
#      before anything is forwarded, and a harmless one is refused -32004 with
#      failmode=Closed, because the policy plane could not answer.
#
# WHAT IT DOES NOT CHECK
#
# TOKENFUSE_MCP_LOCK (pinning tool definitions) needs a lock file somebody approved
# and is not set here, by decision. The scan's block mode is held by A and B only:
# C has no upstream that serves a poisoned listing.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No broker service, no Docker, or an image that never answered: each is reported
# and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"; [ -z "${ctr:-}" ] || docker rm -f "$ctr" >/dev/null 2>&1' EXIT

# ---- A. compose ----------------------------------------------------------------
python3 - compose.yaml "$scratch/subjects" <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()
blocks = {}
section = None
current = None
for line in text.split("\n"):
    top = re.match(r"^([a-z-]+):\s*$", line)
    if top:
        section = top.group(1)
        current = None
        continue
    m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
    if m and section == "services":
        current = m.group(1)
        blocks[current] = []
        continue
    if section == "services" and current is not None:
        blocks[current].append(line)


def is_broker(block):
    image = any(re.match(r"^\s*image:\s*.*ghcr\.io/taipanbox/tokenfuse:", l) for l in block)
    sub = any(re.match(r'^\s*command:\s*\["mcp-broker"\]\s*$', l) for l in block)
    return image and sub


def env(block):
    out = {}
    inside = False
    for line in block:
        if re.match(r"^    environment:\s*$", line):
            inside = True
            continue
        if inside:
            if re.match(r"^    \S", line):
                break
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = re.match(r"([A-Z_]+):\s*(.*?)\s*$", s)
            if m:
                out[m.group(1)] = m.group(2).strip('"').strip("'")
    return out


def default_of(value):
    """What a value reads as with nothing set: a literal, or a ${VAR:-default}."""
    m = re.fullmatch(r"\$\{[A-Z_]+:-(.*)\}", value)
    if m:
        return m.group(1)
    if value.startswith("${"):
        return None
    return value


subjects = sorted(n for n, b in blocks.items() if is_broker(b))
if not subjects:
    print("FAIL: no service in compose.yaml uses the tokenfuse image with the mcp-broker")
    print("      command, so this gate measured NOTHING about the broker's defaults.")
    print("      Silence here is not health.")
    sys.exit(1)
open(sys.argv[2], "w").write("\n".join(subjects) + "\n")
bad = 0


def no(msg, *more):
    global bad
    print("FAIL: " + msg)
    for m in more:
        print("      " + m)
    bad += 1


for name in subjects:
    e = env(blocks[name])
    for var, want, why in [
        ("TOKENFUSE_MCP_DLP", "block", "tokenfuse reads it unset as shadow, which forwards a raw secret it found in tool arguments"),
        ("TOKENFUSE_MCP_SCAN", "block", "tokenfuse reads it unset as warn, which passes a tool listing its scanner flags"),
        ("TOKENFUSE_WARDRYX_FAILMODE", "closed", "tokenfuse reads it unset as open, which turns an unreachable policy plane into permission"),
    ]:
        got = e.get(var)
        if got is None:
            no(f"{name} sets no {var}: {why}.")
        elif got != want:
            no(f"{name} sets {var}: {got}, not {want}: {why}.")
    mode = e.get("TOKENFUSE_WARDRYX_MODE")
    if mode is None:
        no(f"{name} sets no TOKENFUSE_WARDRYX_MODE: tokenfuse reads it unset as off, so no tool call is judged.")
    elif default_of(mode) != "enforce":
        no(f"{name} sets TOKENFUSE_WARDRYX_MODE: {mode}, which is not enforce with nothing set:",
           "a tool the policy denies would be called anyway.")
    url = e.get("TOKENFUSE_WARDRYX_URL")
    if url is None or not default_of(url):
        no(f"{name} sets TOKENFUSE_WARDRYX_URL: {url}, which is empty with nothing set, and tokenfuse",
           "turns the hook off when it has no URL, whatever the mode says.")
    key = e.get("TOKENFUSE_WARDRYX_KEY")
    if key is None or not re.fullmatch(r"\$\{[A-Z_]+:\?[^}]*\}", key):
        no(f"{name} sets TOKENFUSE_WARDRYX_KEY: {key}, not a required ${{VAR:?...}}: an empty key makes",
           "every decision fail closed, which is safe and looks like a broken box.")
if bad:
    sys.exit(1)
print("compose: " + ", ".join(subjects) + " set DLP and the tool scan to block, the policy hook to enforce by")
print("         default with a URL, fail closed, and a required key")
PY

# ---- B. resolved ---------------------------------------------------------------
img=""
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
elif [ ! -s "$scratch/subjects" ]; then
  fail "no broker to read the resolved configuration for, so B and C measured nothing"
else
  cdir="$scratch/cfg"
  mkdir -p "$cdir"
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u \
    | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
  profiles=()
  for p in $(python3 - compose.yaml "$scratch/subjects" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for s in open(sys.argv[2]).read().split():
    m = re.search(r"^  " + re.escape(s) + r":\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)", text, re.M | re.S)
    if m:
        for p in re.findall(r'^    profiles:\s*\[([^\]]*)\]', m.group(1), re.M):
            for name in re.findall(r'"([a-z0-9-]+)"', p):
                print(name)
PY
  ); do profiles+=(--profile "$p"); done
  # The typed risk signal's two lines are what a box that asked for it carries; a
  # default box has neither, so neither may come from this run's environment. The
  # image is left as the environment resolves it, as install.sh would run it.
  if ! env -u TYPED_RISK_WARDRYX_MODE -u TYPED_RISK_WARDRYX_URL \
      docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "${profiles[@]}" config --format json \
      >"$cdir/cfg.json" 2>"$cdir/err"; then
    fail "resolved: docker compose config failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
  else
    out="$(python3 - "$cdir/cfg.json" "$scratch/subjects" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
svc = cfg["services"]
bad = 0
for name in open(sys.argv[2]).read().split():
    s = svc.get(name)
    if s is None:
        print(f"FAIL: resolved: {name} is not in the configuration with its own profiles")
        bad += 1
        continue
    e = s.get("environment") or {}
    want = {"TOKENFUSE_MCP_DLP": "block", "TOKENFUSE_MCP_SCAN": "block",
            "TOKENFUSE_WARDRYX_MODE": "enforce", "TOKENFUSE_WARDRYX_FAILMODE": "closed"}
    for k, v in want.items():
        if e.get(k) != v:
            print(f"FAIL: resolved: {name} reads {k}={e.get(k)!r} with nothing set, not {v}")
            bad += 1
    url = e.get("TOKENFUSE_WARDRYX_URL") or ""
    host = url.split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
    if host != "wardryx" or "wardryx" not in svc:
        print(f"FAIL: resolved: {name} asks {url!r} with nothing set, not wardryx, the policy plane of this box")
        bad += 1
    if not e.get("TOKENFUSE_WARDRYX_KEY"):
        print(f"FAIL: resolved: {name} has no TOKENFUSE_WARDRYX_KEY")
        bad += 1
    print(f"IMAGE {s.get('image', '')}")
    print("ENV " + " ".join(f"{k}={e.get(k, '')}" for k in ("TOKENFUSE_MCP_DLP", "TOKENFUSE_MCP_SCAN", "TOKENFUSE_WARDRYX_MODE", "TOKENFUSE_WARDRYX_FAILMODE")))
sys.exit(1 if bad else 0)
PY
)" || problems=$((problems + 1))
    printf '%s\n' "$out" | grep '^FAIL' || true
    img="$(sed -n 's/^IMAGE //p' <<<"$out" | head -n 1)"
    benv="$(sed -n 's/^ENV //p' <<<"$out" | head -n 1)"
  fi
fi

# ---- C. behaviour --------------------------------------------------------------
# The image compose resolves (TOKENFUSE_IMAGE moves it, which is the point of
# reading it from the configuration), the four switches compose resolves, and a
# policy plane and upstream that are not there.
if [ -n "$img" ]; then
  if ! docker version >/dev/null 2>&1; then
    fail "no Docker here, so the broker image could not be run. This gate does not pass on a box that cannot run it."
  elif ! docker image inspect "$img" >/dev/null 2>&1 && ! docker pull -q "$img" >/dev/null 2>&1; then
    fail "could not pull $img, so the broker's behaviour could not be measured"
  else
    eargs=()
    for kv in $benv; do eargs+=(-e "$kv"); done
    ctr="stack-single-gate-broker-$$"
    docker rm -f "$ctr" >/dev/null 2>&1 || true
    if ! docker run -d --name "$ctr" --network none \
        -e TOKENFUSE_MCP_ADDR=127.0.0.1:4200 \
        -e TOKENFUSE_MCP_UPSTREAMS=typryx=http://127.0.0.1:9/mcp \
        -e TOKENFUSE_WARDRYX_URL=http://127.0.0.1:9 \
        -e TOKENFUSE_WARDRYX_KEY=gate-not-a-key \
        -e TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS=500 \
        "${eargs[@]}" "$img" mcp-broker >/dev/null 2>"$scratch/run.err"; then
      fail "behaviour: $img never answered as the broker: it would not start ($(head -1 "$scratch/run.err" | cut -c1-160))"
    else
      up=0
      for _ in $(seq 1 60); do
        if docker logs "$ctr" 2>&1 | grep -q 'credential-broker listening'; then up=1; break; fi
        [ "$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null)" = true ] || break
        sleep 0.25
      done
      if [ "$up" != 1 ]; then
        fail "behaviour: $img never answered as the broker (no 'credential-broker listening' line), so nothing showed that the broker this box runs blocks anything. Its last words: $(docker logs "$ctr" 2>&1 | tail -1 | cut -c1-160)"
      else
        call() { # BODY: the broker's answer to one tools/call, over bash's /dev/tcp
          docker exec -e BODY="$1" "$ctr" bash -c '
            exec 3<>/dev/tcp/127.0.0.1/4200 || exit 9
            printf "POST /mcp HTTP/1.0\r\nHost: broker\r\nContent-Type: application/json\r\nX-Fuse-Mcp-Upstream: typryx\r\nx-fuse-agent-id: agent://gate.invalid/probe\r\nContent-Length: %d\r\n\r\n%s" "${#BODY}" "$BODY" >&3
            cat <&3' 2>&1
        }
        # AWS's own documented example key id: a secret's shape, and nobody's secret.
        raw="$(call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"note":"AKIAIOSFODNN7EXAMPLE"}}}')"
        grep -q '"code":-32002' <<<"$raw" \
          || fail "behaviour: a tools/call carrying a raw AWS key id was not refused -32002 by $img; it answered: $(tail -1 <<<"$raw" | cut -c1-200)"
        calm="$(call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask","arguments":{"note":"hello"}}}')"
        grep -q '"code":-32004' <<<"$calm" && grep -q 'failmode=Closed' <<<"$calm" \
          || fail "behaviour: with the policy plane unreachable, a harmless tools/call was not refused closed by $img; it answered: $(tail -1 <<<"$calm" | cut -c1-200)"
      fi
    fi
  fi
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 36."
  exit 1
fi
echo "OK: the MCP broker blocks raw secrets in tool arguments and flagged tool listings, asks wardryx about every"
echo "    tool call and fails closed, in compose.yaml, in the resolved configuration and in the image it runs."
