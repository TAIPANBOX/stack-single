#!/usr/bin/env bash
# Holds CLAUDE.md invariant 77's two proxies to what they forward.
#
# guest-door is the only thing of this stack on the guests network. It forwards a guest's call to
# vouchryx, the gateway or the MCP broker by port, on the routes an agent uses, and answers every
# other route itself. guest-callback forwards a call back from core to a guest guest-callbacks.txt
# names, for a caller on core only. Neither holds a key. What goes wrong silently here is a route
# that reaches an administrative endpoint of a door, a port that reaches the wrong door, a loop
# guard that runs after the forward, or a call back that answers a guest; so this reads
# guest-door/Caddyfile line by line, and runs install.sh's own `guest-callbacks` block over the
# files an operator could write.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f guest-door/Caddyfile ] || { echo "FAIL: guest-door/Caddyfile is not there, so the guests' routes measured NOTHING."; exit 1; }
BLOCK="$(sed -n '/^# guest-callbacks: begin$/,/^# guest-callbacks: end$/p' install.sh)"
[ -n "$BLOCK" ] || { echo "FAIL: install.sh has no guest-callbacks block, so the call backs measured NOTHING."; exit 1; }

problems=0
report() { printf 'FAIL: %s\n' "$1"; problems=$((problems + 1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/guest-callbacks.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# ---- guest-door/Caddyfile ------------------------------------------------------------
# The routes each door gives a guest, and nothing more: from vouchryx a token, a key set, the server's
# metadata, the revocation list a door reads, and a revocation or its lift under a scoped key; model
# calls in either provider's shape; tool calls. A route a door adds is closed until it is named here.
# Not inside $( ): bash 3.2 reads a here-document there for quotes, and the messages below have some.
python3 - >"$W/caddyfile.out" <<'PY'
import re
EXPECT = {
    "4310": ("vouchryx:4310", {"/v1/token", "/v1/revocations", "/v1/revoke", "/v1/revoke/lift", "/.well-known/jwks.json", "/.well-known/oauth-authorization-server", "/healthz"}),
    "4100": ("tokenfuse-gateway:4100", {"/v1/messages", "/v1/chat/completions", "/healthz"}),
    "4200": ("tokenfuse-mcp-broker:4200", {"/mcp", "/healthz"}),
}
text = open("guest-door/Caddyfile").read()
lines = [l.split("#", 1)[0].rstrip() for l in text.split("\n")]
src = "\n".join(lines)
bad = []
def say(m): bad.append(m)

# the global options: no admin endpoint, no certificate machinery, nothing saved
m = re.match(r"\s*\{\n(.*?)\n\}", src, re.S)
glob = set(l.strip() for l in (m.group(1).split("\n") if m else []) if l.strip())
if glob != {"admin off", "auto_https off", "persist_config off"}:
    say("guest-door's global options are %s, not exactly admin off, auto_https off and persist_config off" % sorted(glob))
for word in ("{env.", "{$", "file_server", "header_up Authorization", "header_up X-Api-Key", "basicauth", "forward_auth", "tls "):
    if word in src:
        say("guest-door/Caddyfile uses %r: the guests' door holds no key, reads no environment and serves no file" % word.strip())

# the sites, by brace depth: each top-level block after the global one
sites = {}
depth = 0
cur = None
body = []
for l in lines:
    s = l.strip()
    if depth == 0 and s.endswith("{") and s != "{":
        cur = s[:-1].strip()
        body = []
    if cur is not None and depth >= 1:
        body.append(s)
    depth += l.count("{") - l.count("}")
    if depth == 0 and cur is not None:
        sites[cur] = [b for b in body if b and b != "}"]
        cur = None
want_sites = {":" + p for p in EXPECT} | {"(loop)"}
if set(sites) != want_sites:
    say("guest-door's sites are %s, not %s" % (sorted(sites), sorted(want_sites)))
if sites.get("(loop)") != ["@loop header X-Guest-Door *"]:
    say("the loop snippet is %s, not one matcher on the header guest-door sets" % sites.get("(loop)"))
for port, (upstream, paths) in EXPECT.items():
    b = sites.get(":" + port)
    if b is None:
        continue
    agent = [x for x in b if x.startswith("@agent ")]
    got = set(agent[0].split()[2:]) if agent and agent[0].split()[1] == "path" else None
    if len(agent) != 1 or got is None:
        say(":%s has no single @agent path matcher" % port)
    elif got != paths:
        say(":%s gives a guest %s, not %s" % (port, sorted(got), sorted(paths)))
    elif any("*" in x for x in got):
        say(":%s matches a path by prefix: a guest's routes are exact" % port)
    if "import loop" not in b:
        say(":%s does not import the loop guard" % port)
    # inside route, in order: the loop answered, the agent's routes forwarded, the rest refused
    try:
        r = b.index("route {")
    except ValueError:
        say(":%s has no route block, so the order of its directives is Caddy's, not the file's" % port)
        continue
    inner = [x for x in b[r + 1:]]
    heads = [x for x in inner if re.match(r"^(respond|reverse_proxy|handle|redir|rewrite|file_server|header|uri)\b", x)]
    if len(heads) != 3:
        say(":%s's route holds %s, not the loop answer, one forward and one refusal" % (port, heads))
        continue
    if not re.match(r'^respond @loop ".*" 508$', heads[0]):
        say(":%s answers %r first, not the loop: a request that came back would be forwarded again" % (port, heads[0]))
    if heads[1] != "reverse_proxy @agent %s {" % upstream:
        say(":%s forwards with %r, not to %s for @agent alone" % (port, heads[1], upstream))
    if not re.match(r'^respond ".*" 404$', heads[2]):
        say(":%s ends with %r, not its own 404" % (port, heads[2]))
    ups = [x for x in inner if x.startswith("header_up ")]
    if ups != ["header_up X-Guest-Door 1"]:
        say(":%s sets %s upstream, not the one header the loop guard reads" % (port, ups))
print("\n".join(bad))
PY
while IFS= read -r l; do [ -z "$l" ] || report "$l"; done <"$W/caddyfile.out"

# ---- install.sh's call backs, over the files an operator could write ----------------------
printf '%s\n' "$BLOCK" >"$W/block.sh"
cb() { # GUESTS FILE-CONTENT|-  -> prints rc, GCB_WHY and the rendered configuration for 10.1.0.0/16
	local d="$W/c$RANDOM"
	mkdir -p "$d"
	if [ "$2" = - ]; then :; elif [ "$2" = DIR ]; then mkdir "$d/guest-callbacks.txt"; else printf '%s' "$2" >"$d/guest-callbacks.txt"; fi
	(
		cd "$d"
		# shellcheck disable=SC1091
		. "$W/block.sh"
		rc=0
		guest_callbacks_read "$1" || rc=$?
		printf 'rc=%s\nwhy=%s\n' "$rc" "$GCB_WHY"
		guest_callbacks_caddyfile $'10.1.0.0/16\n10.2.0.0/16'
	)
}
expect() { # NAME OUTPUT REGEX
	grep -qE -- "$3" <<<"$2" || report "$1: the output does not hold /$3/"
}
refuse() { # NAME GUESTS CONTENT WHY-REGEX
	local o
	o="$(cb "$2" "$3")"
	expect "$1" "$o" '^rc=1$'
	expect "$1" "$o" "^why=$4"
	grep -q 'reverse_proxy' <<<"$o" && report "$1: a refused file still renders a call back"
	return 0
}

o="$(cb "lab-gate-labgate-1" -)"
expect "no guest-callbacks.txt" "$o" '^rc=0$'
expect "no guest-callbacks.txt" "$o" '^:8080 \{$'
expect "no guest-callbacks.txt" "$o" 'respond "guest-callback: guest-callbacks.txt declares no call back" 404'
grep -q 'reverse_proxy' <<<"$o" && report "no guest-callbacks.txt: a call back is rendered with no file"

o="$(cb $'lab-gate-labgate-1\nlab-idp-bridge' $'# the lab\nlab-gate-labgate-1 labgate:8791   # the relay\n\nlab-idp-bridge  bridge:9000\n')"
expect "two call backs" "$o" '^rc=0$'
expect "two call backs" "$o" '^:8791 \{$'
expect "two call backs" "$o" '^:9000 \{$'
expect "two call backs" "$o" $'^\t@core remote_ip 10.1.0.0/16 10.2.0.0/16$'
expect "two call backs" "$o" $'^\t\treverse_proxy @core labgate:8791 \\{$'
expect "two call backs" "$o" $'^\t\treverse_proxy @core bridge:9000 \\{$'
expect "two call backs" "$o" $'^\t\trespond "guest-callback: only a service on core may call a guest back" 403$'
[ "$(grep -c 'reverse_proxy @core' <<<"$o")" = 2 ] || report "two call backs: not exactly two forwards, each for a caller on core"
grep -q $'^\t\treverse_proxy [a-z]' <<<"$o" && report "two call backs: a forward answers every caller"
grep -q $'^\tadmin off$' <<<"$o" || report "two call backs: guest-callback's admin endpoint is not off"

refuse "three fields" "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate:8791 extra\n' "guest-callbacks.txt line 1 is not one"
refuse "no port" "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate\n' "guest-callbacks.txt line 1 is not one"
refuse "a port below 1024" "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate:80\n' "guest-callbacks.txt line 1 is not one"
refuse "port 1023" "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate:1023\n' "guest-callbacks.txt line 1 is not one"
refuse "a port above 65535" "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate:65536\n' "guest-callbacks.txt line 1 is not one"
refuse "a dotted name" "lab-gate-labgate-1" $'lab-gate-labgate-1 api.provider.example:8791\n' "guest-callbacks.txt line 1 is not one"
refuse "an upper-case name" "lab-gate-labgate-1" $'lab-gate-labgate-1 LabGate:8791\n' "guest-callbacks.txt line 1 is not one"
refuse "a name with a space" "lab-gate-labgate-1" $'lab-gate-labgate-1 lab gate:8791\n' "guest-callbacks.txt line 1 is not one"
refuse "a container guests.txt does not name" "lab-idp-bridge" $'lab-gate-labgate-1 labgate:8791\n' "guest-callbacks.txt line 1 names lab-gate-labgate-1, and guests.txt does not"
refuse "a name twice" $'a\nb' $'a labgate:8791\nb labgate:8792\n' "guest-callbacks.txt line 2 repeats the name or the port"
refuse "a port twice" $'a\nb' $'a one:8791\nb two:8791\n' "guest-callbacks.txt line 2 repeats the name or the port"
refuse "a file that cannot be read" "lab-gate-labgate-1" DIR "guest-callbacks.txt is on this box and could not be read"
o="$(cb "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate:1024\n')"
expect "port 1024" "$o" '^rc=0$'
o="$(cb "lab-gate-labgate-1" $'lab-gate-labgate-1 labgate:65535\n')"
expect "port 65535" "$o" '^rc=0$'

# ---- compose.yaml: what each proxy is given --------------------------------------------
for svc in guest-door guest-callback; do
	blk="$(awk -v s="  $svc:" '$0 == s { on = 1; next } on && /^  [a-z]/ { exit } on' compose.yaml)"
	[ -n "$blk" ] || { report "compose.yaml has no service $svc"; continue; }
	grep -q '^    user: "65534:65534"$' <<<"$blk" || report "$svc does not run as nobody"
	grep -q '^    environment:' <<<"$blk" && report "$svc is given an environment: the guests' proxies hold no key"
	grep -q "^    entrypoint: \[\"caddy\", \"run\", \"--config\", \"/etc/$svc/Caddyfile\", \"--adapter\", \"caddyfile\"\]$" <<<"$blk" \
		|| report "$svc does not run caddy on /etc/$svc/Caddyfile, its own configuration"
	grep -q '^    ports:' <<<"$blk" && report "$svc publishes a port: the guests reach it on their own network"
done

if [ "$problems" -ne 0 ]; then
	echo "guest-door-routes: $problems problem(s)"
	exit 1
fi
echo "OK: guest-door forwards ports 4310, 4100 and 4200 to vouchryx, the gateway and the MCP broker on an agent's routes alone, answers a loop first and every other route 404;"
echo "    guest-callback renders one forward per line of guest-callbacks.txt, each for a caller on core, and refuses 12 kinds of line; neither proxy holds a key."
