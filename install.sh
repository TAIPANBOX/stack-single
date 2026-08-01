#!/usr/bin/env bash
# The agent stack on one machine, ready for agents that live somewhere else.
#
#   curl -fsSL https://raw.githubusercontent.com/TAIPANBOX/stack-single/main/install.sh | bash
#
# or, from a clone:
#
#   ./install.sh
#
# What this is NOT: `stack-up`, which is the local sandbox. That one needs
# Rust, Go and Node on your machine to build from source and stops when you
# press Ctrl-C. This one is for a box you will point real agents at: the
# toolchains live inside the images, the services come back after a reboot,
# and the console has a sign-in that exists.
#
# The gateway is published to the host's loopback only, until you say
# otherwise. Publishing an enforcement plane to the internet is a decision, not
# a default, so it is one word you type rather than one you inherit:
#
#   GATEWAY_BIND=0.0.0.0 ./install.sh     # first run: agents elsewhere can call it
#
# Re-running never changes an existing box: the value lives in .env from the
# first run, and .env is left alone.
#
# Requires: a Debian or Ubuntu host, root, and outbound internet. Everything
# else it installs. Roughly 3GB of disk for the images and ten minutes for the
# first build, most of it Rust.
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/TAIPANBOX/stack-k8s/main}"
STACK_DIR="${STACK_DIR:-/opt/agent-stack}"
SRC_DIR="${SRC_DIR:-$STACK_DIR/src}"
CONSOLE_TOKEN="${CONSOLE_TOKEN:-}"   # optional: only for a private fork of the console
CONSOLE_USER="${CONSOLE_USER:-ops}"
# The host interface Docker publishes the gateway on. Loopback by default: a
# box that just ran an install script should not acquire an internet-facing
# enforcement plane because nobody typed anything. Set 0.0.0.0 (or a specific
# address) to let agents on other machines reach it. This is NOT the address
# the gateway process listens on inside its container: that one is 0.0.0.0 in
# compose.yaml and has to be, because loopback inside a container is
# unreachable even from the container beside it.
GATEWAY_BIND="${GATEWAY_BIND:-127.0.0.1}"

say()  { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { EXPLAINED=1; printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
EXPLAINED=0   # set by die(), so a diagnosed failure is not narrated twice

# Nothing here is allowed to fail silently. Under `set -e` an unhandled
# failure ends the script wherever it happens, and a script that ends
# mid-sentence is the worst thing to hand someone who is installing an
# enforcement plane: it looks like it finished. This says which line died and
# with what, every time, including the signals that `set -e` turns into
# invisible exits (141 is SIGPIPE, and it is a real hazard in a pipeline that
# ends in `head`).
# rc is assigned in this same trap string, which shellcheck does not look inside.
# shellcheck disable=SC2154
trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n\033[1;31m!! install.sh stopped at line %s (exit %s)\033[0m\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the installer, please report it.\n" >&2
      printf "   Nothing is half-configured that a re-run will not redo: this script is safe to run again.\n" >&2
      exit $rc' EXIT

# ---- 0. preflight -----------------------------------------------------------
[ "$(id -u)" = "0" ] || die "run as root: this installs packages and a firewall rule."
[ -r /etc/os-release ] || die "no /etc/os-release: this expects Debian or Ubuntu."
# shellcheck disable=SC1091  # lives on the target machine, not in this repo
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die "this expects Debian or Ubuntu; found ${PRETTY_NAME:-unknown}." ;;
esac
[ "$(uname -m)" = "x86_64" ] || note "architecture $(uname -m): the images build from source, so this should work, but it is untested off x86_64."

say "installing docker and git"
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  # docker.io from the distro, not get.docker.com: one less script piped from
  # the internet on a box that is about to hold an enforcement plane.
  # docker-buildx as well: the distro's docker.io does not include it, and
  # without it every build runs on the deprecated legacy builder.
  apt-get install -y -qq docker.io docker-buildx git curl >/dev/null 2>&1 \
    || apt-get install -y -qq docker.io git curl >/dev/null
else
  apt-get update -qq >/dev/null 2>&1 || true
  # buildx here too, not only on the first-install branch: a box that already
  # had docker is exactly the box that does not have it, and every build then
  # runs on the deprecated legacy builder while telling you so twice per image.
  apt-get install -y -qq git curl docker-buildx >/dev/null 2>&1 \
    || apt-get install -y -qq git curl >/dev/null 2>&1 || true
fi
systemctl enable --now docker >/dev/null 2>&1 || die "docker did not start."
# Compose v2 as a plugin, or the standalone binary, or neither.
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose >/dev/null 2>&1 || true
  if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
  else die "no docker compose available; install the docker-compose-v2 package."; fi
fi
note "docker $(docker --version | awk '{print $3}' | tr -d ,), compose present"

# ---- 1. this repo, whether cloned or piped ----------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
mkdir -p "$STACK_DIR"
if [ -n "$HERE" ] && [ -f "$HERE/compose.yaml" ]; then
  [ "$HERE" = "$STACK_DIR" ] || cp -a "$HERE/." "$STACK_DIR/"
else
  say "fetching the stack definition"
  curl -fsSL "${REPO_SINGLE_RAW:-https://raw.githubusercontent.com/TAIPANBOX/stack-single/main}/compose.yaml" \
    -o "$STACK_DIR/compose.yaml" || die "could not fetch compose.yaml"
fi
cd "$STACK_DIR"

# ---- 2. sources and images --------------------------------------------------
# Built here rather than pulled: there is no public registry for these, and a
# private one is another component to secure and another bill. The build
# happens once; `restart: unless-stopped` means it is not repeated on reboot.
say "fetching sources"
mkdir -p "$SRC_DIR" && cd "$SRC_DIR"
for r in tokenfuse wardryx idryx qryx mockryx verdryx engram; do
  if [ -d "$r/.git" ]; then (cd "$r" && git pull -q --ff-only 2>/dev/null || true)
  else git clone --depth 1 -q "https://github.com/TAIPANBOX/$r.git" "$r" || die "could not clone $r"; fi
done
# The console is Apache-2.0 and public since 2026-07-27, so it clones like
# everything else and needs no token. CONSOLE_TOKEN still works, for the one
# case it is now good for: a private fork of your own.
if [ -d "$SRC_DIR/genaryx-a360" ]; then
  note "console source already present (placed here directly), not cloning"
elif [ -n "$CONSOLE_TOKEN" ]; then
  if [ -d genaryx/.git ]; then (cd genaryx && git pull -q --ff-only 2>/dev/null || true)
  else git clone --depth 1 -q "https://x-access-token:${CONSOLE_TOKEN}@github.com/TAIPANBOX/genaryx.git" genaryx \
      || die "could not clone the console with the token given; is it valid for your fork?"; fi
else
  if [ -d genaryx/.git ]; then (cd genaryx && git pull -q --ff-only 2>/dev/null || true)
  else git clone --depth 1 -q "https://github.com/TAIPANBOX/genaryx.git" genaryx \
      || die "could not clone the console"; fi
fi

say "fetching the image definitions"
mkdir -p "$SRC_DIR/dockerfiles"
for f in go-service.Dockerfile tokenfuse.Dockerfile console.Dockerfile wg.Dockerfile caddy.Dockerfile; do
  curl -fsSL "$REPO_RAW/images/$f" -o "$SRC_DIR/dockerfiles/$f" || die "could not fetch $f"
done

say "building images (first run is slow: Rust)"
cd "$SRC_DIR"
for pair in wardryx:wardryx idryx:idryx qryx:qryx mockryx:mockryx; do
  name="${pair%%:*}"; repo="${pair##*:}"
  note "building $name"
  docker build -q -f dockerfiles/go-service.Dockerfile \
    --build-arg SERVICE="$name" --build-arg SRC="./$repo" -t "stack/$name:dev" . >/dev/null \
    || die "image build failed: $name"
done
note "building caddy (TLS for the console)"
docker build -q -f dockerfiles/caddy.Dockerfile -t stack/caddy:dev . >/dev/null \
  || die "image build failed: caddy"
note "building wg (the operator's tunnel)"
docker build -q -f dockerfiles/wg.Dockerfile -t stack/wg:dev . >/dev/null \
  || die "image build failed: wg"
note "building tokenfuse (gateway + cloud)"
docker build -q -f dockerfiles/tokenfuse.Dockerfile -t stack/tokenfuse:dev ./tokenfuse >/dev/null \
  || die "image build failed: tokenfuse"
if [ -d genaryx ] || [ -d genaryx-a360 ]; then
  note "building the console (four languages, it hosts the tools it runs)"
  [ -d genaryx ] && mv genaryx genaryx-a360 2>/dev/null || true
  docker build -q -f dockerfiles/console.Dockerfile -t stack/genaryx-console:dev . >/dev/null \
    || die "image build failed: console"
fi
cd "$STACK_DIR"

# ---- 3. secrets --------------------------------------------------------------
# Generated here, once, and never printed except the console sign-in at the
# end. 0600 and outside any git tree.
# Needed BEFORE .env is written, because the client WireGuard configs this box
# issues must name the address a phone dials from outside, and nothing on the
# interface can report it. `ipify` first (correct behind NAT, where the local
# address is not the reachable one), the primary local address otherwise.
PUBLIC_IP="$(curl -fsS -m5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

say "credentials"
# `tr </dev/urandom | head -c N` is the idiom everyone writes and it is a trap
# under `set -o pipefail`: when head has its N bytes it closes the pipe, tr
# dies of SIGPIPE, the pipeline reports 141 and `set -e` ends the script right
# here, silently, with no .env written. The subshell turns pipefail off for
# this one pipeline, which is exactly where it is wrong to have it on.
gen() {
  local n="${1:-40}" v
  v="$( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n" )"
  [ "${#v}" = "$n" ] || die "could not generate a $n-character secret (got ${#v}); /dev/urandom is not readable."
  printf '%s' "$v"
}
if [ -s .env ]; then
  note ".env already exists, left as is"
else
  POLICY_DB_PASSWORD="$(gen 32)"
  # Three secrets, six variables. Both planes take a bearer-key SPEC of the
  # form `key:org[:role]` on the server side and the BARE key on the client
  # side, and the difference matters more than it looks: a value with no `:org`
  # half parses to zero valid keys, so the plane authenticates nobody and
  # answers 401 to everything, while starting cleanly and saying so in a single
  # line of log. That is what a random string in `TOKENFUSE_CLOUD_KEYS`
  # produces, and it looks exactly like a working deployment from the outside.
  CLOUD_SECRET="$(gen 40)"
  WARDRYX_ADMIN_SECRET="$(gen 40)"
  WARDRYX_GATEWAY_SECRET="$(gen 40)"
  cat > .env <<EOF
# Generated by install.sh. Nothing here is a default: every value is unique to
# this box. Keep the file at 0600 and out of any repository.
POLICY_DB_PASSWORD=$POLICY_DB_PASSWORD
POLICY_DB_DSN=postgres://wardryx:$POLICY_DB_PASSWORD@policy-db:5432/wardryx?sslmode=disable
APPROVAL_SECRET=$(gen 64)

# The money plane. CLOUD_KEYS is the spec the plane accepts; CLOUD_ADMIN is the
# bare key the gateway and the console present.
CLOUD_KEYS=$CLOUD_SECRET:default:admin
CLOUD_ADMIN=$CLOUD_SECRET

# The policy plane, with two client keys on purpose. The console administers
# policy and needs admin. The gateway only calls /v1/decide, which any
# authenticated principal may do, so it gets a VIEWER key: an enforcement point
# that can rewrite the policy it enforces is not an enforcement point.
WARDRYX_KEYS=$WARDRYX_ADMIN_SECRET:default:admin,$WARDRYX_GATEWAY_SECRET:default:viewer
WARDRYX_ADMIN=$WARDRYX_ADMIN_SECRET
WARDRYX_GATEWAY=$WARDRYX_GATEWAY_SECRET

GATEWAY_BIND=$GATEWAY_BIND

# The operator's WireGuard road in. WG_ENDPOINT_HOST is what an issued device
# config dials; get it wrong and the config looks perfect and never connects.
# Detected once, here, and editable afterwards: a box behind NAT or with a
# hostname you would rather hand out is a normal case, not a broken one.
WG_ENDPOINT_HOST=$PUBLIC_IP
WG_IFACE=wg-op
WG_LISTEN_PORT=51820
WG_BIND=0.0.0.0
EOF
  chmod 600 .env
  note "generated .env (0600)"
fi

# Leaving .env alone is right for values that already exist, and wrong for
# values a NEWER release introduced: an installed box would otherwise fail on
# a variable compose now requires, with an error naming this script as the
# thing that was supposed to set it. So the upgrade path is additive - never
# overwrite, only fill in what is absent - which keeps credentials and the
# operator's own edits untouched while letting the stack grow.
add_env_default() {
  local name="$1" value="$2"
  grep -q "^${name}=" .env 2>/dev/null && return 0
  printf '%s=%s\n' "$name" "$value" >>.env
  note "added $name to .env (new in this release)"
}
add_env_default WG_ENDPOINT_HOST "$PUBLIC_IP"
add_env_default WG_IFACE wg-op
add_env_default WG_LISTEN_PORT 51820
add_env_default WG_BIND 0.0.0.0
# The console's name inside the tunnel. WebAuthn scopes credentials to a domain
# and refuses a bare IP, so the passkey ceremony needs one even here. The
# default is a private-use name that resolves nowhere: it gets a working TLS
# console immediately (Caddy's internal CA, trusted per device), and swapping
# in a real name plus CLOUDFLARE_API_TOKEN upgrades it to a publicly-trusted
# certificate with no other change.
add_env_default CONSOLE_DOMAIN console.genaryx.internal

# Read back what is actually on this box rather than what this run's defaults
# would have written. On a re-run the block above left .env exactly as it was,
# so an existing deployment keeps its own binding and its own credentials, and
# every section below then reports and verifies the real values instead of
# announcing a boundary this run merely intended.
# shellcheck disable=SC1091  # generated at install time, not in this repo
. ./.env

# ---- 4. the files the services read -----------------------------------------
if [ ! -f policy.yaml ]; then
  cat > policy.yaml <<'EOF'
# Seeded scoped to fire-drill identities only, so a fresh box denies something
# real without touching a live fleet. Replace with your own.
- name: starter-require-human-approval
  target: agent://drill.local/*
  require_human_above_usd: 1
- name: starter-deny-shell-exec
  target: agent://drill.local/*
  deny_tool:
    - shell_exec
EOF
  note "wrote policy.yaml"
fi
mkdir -p environments
if [ ! -f environments/single.json ]; then
  cat > environments/single.json <<'EOF'
{
  "name": "single",
  "host": "localhost",
  "services": {
    "cloud":   { "url": "http://tokenfuse-cloud:8080" },
    "gateway": { "url": "http://tokenfuse-gateway:4100", "mode": "enforce" },
    "wardryx": { "url": "http://wardryx:8090" },
    "idryx":   { "url": "http://idryx:8081" }
  },
  "events": {
    "dir": "/var/lib/stack/events",
    "files": {
      "tokenfuse": "/var/lib/stack/events/tokenfuse.ndjson",
      "wardryx": "/var/lib/stack/events/wardryx.ndjson"
    }
  }
}
EOF
  note "wrote environments/single.json"
fi

# ---- 5. up ------------------------------------------------------------------
say "starting the stack"
"${COMPOSE[@]}" up -d --remove-orphans
sleep 8

# ---- 6. the firewall ---------------------------------------------------------
# Docker publishes ports by writing its own iptables rules, which bypass ufw's
# INPUT chain: a `ufw deny` on 4100 would NOT stop traffic to a published
# container port, and an operator who assumes otherwise has an open plane and
# a green firewall status. So the boundary is drawn where it actually holds:
# only the gateway is published at all, everything else has no host port, and
# the console is bound to loopback.
say "network boundary"
case "$GATEWAY_BIND" in
  127.0.0.1|localhost|::1)
    note "loopback only: 4100 (gateway), 7420 (console)"
    note "no machine other than this one can reach any plane. That is the default."
    note "to let agents elsewhere call the gateway, see the end of this run" ;;
  *)
    note "published to the world: 4100 (gateway) only, bound $GATEWAY_BIND"
    note "loopback only: 7420 (console), reachable over your own tunnel" ;;
esac
note "the operator's tunnel: ${WG_LISTEN_PORT:-51820}/udp, open on purpose"
note "  WireGuard answers nothing without a valid key: no banner, no handshake,"
note "  nothing for a scanner to find. It is the road in, not an exposed plane."
note "not published at all: cloud, wardryx, idryx, postgres"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  note "ufw is active: ssh allowed. Note that ufw does NOT govern published container ports."
fi

# ---- 7. the console account --------------------------------------------------
CONSOLE_PASSWORD=""
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx console; then
  say "console account"
  if "${COMPOSE[@]}" exec -T console test -s /var/lib/stack/.taipan/genaryx-web/operator.json >/dev/null 2>&1; then
    note "an operator already exists, left as is"
  else
    CONSOLE_PASSWORD="$(gen 28)"
    if printf '%s\n' "$CONSOLE_PASSWORD" | "${COMPOSE[@]}" exec -T console \
         /usr/local/bin/genaryx-web set-password --username "$CONSOLE_USER" >/dev/null 2>&1; then
      note "created operator '$CONSOLE_USER'"
    else
      CONSOLE_PASSWORD=""
      note "could not set the password automatically; the command is printed below"
    fi
  fi
fi

# ---- 8. does it actually work -------------------------------------------------
say "verify"
fail=0
check() { # name, command
  [ "$#" -eq 2 ] || die "internal: check() got $# arguments, expected 2 (\$1='${1:-}')"
  if eval "$2" >/dev/null 2>&1; then printf '   ok    %s\n' "$1"; else printf '   FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}
# One word, not an array. `"${COMPOSE[@]}"` inside a larger quoted string does
# not stay one argument: it word-splits, check() silently receives three
# arguments instead of two, `$2` becomes the fragment `"docker`, and every
# container-side check reports FAIL on a perfectly healthy stack. `[*]` joins
# the elements into the single string eval actually needs. The argument-count
# assertion above is there so this can never be silent again.
DC="${COMPOSE[*]}"

# Not `docker compose exec ... curl`: none of these images HAS curl, and two of
# them have no shell either, because they are distroless on purpose. A check
# that needs a tool the image deliberately omits fails on a perfectly healthy
# stack and is indistinguishable from a real failure. So the probe is a
# throwaway busybox attached to the same network, which is what a neighbouring
# container sees and therefore what the check should be asking about.
NET="agent-stack_default"
docker network inspect "$NET" >/dev/null 2>&1 || die "network $NET is missing: the stack did not start."
# shellcheck disable=SC2329  # invoked indirectly: passed as a string to `check`
probe() { docker run --rm --network "$NET" busybox:1.36 wget -q -T5 -O /dev/null "$1"; }
# Prints the HTTP status only, so a check can assert 401 and 403 as PASSES.
# shellcheck disable=SC2329  # invoked indirectly: passed as a string to `check`
code() { docker run --rm --network "$NET" busybox:1.36 \
           wget -S -q -T5 -O /dev/null --header="Authorization: Bearer $2" "$1" 2>&1 \
         | awk '/^  HTTP\//{c=$2} END{print c+0}'; }

check "gateway answers on 4100"      "curl -fsS -m5 -o /dev/null http://127.0.0.1:4100/healthz"
check "cloud answers inside"         "probe http://tokenfuse-cloud:8080/healthz"
check "wardryx answers inside"       "probe http://wardryx:8090/healthz"
check "idryx answers inside"         "probe http://idryx:8081/healthz"
check "policy store is up"           "$DC exec -T policy-db pg_isready -U wardryx -d wardryx"

# The three below are about the KEYS, and they exist because a plane with a
# malformed key spec starts cleanly, authenticates nobody, and answers 401 to
# its own console. Reachability alone would have called that deployment green.
check "policy plane accepts its admin key"   "[ \"\$(code http://wardryx:8090/v1/policies '$WARDRYX_ADMIN')\" = 200 ]"
check "policy plane rejects an unknown key"  "[ \"\$(code http://wardryx:8090/v1/policies nonsense-not-a-key)\" = 401 ]"
check "gateway's key cannot write policy"    "[ \"\$(code http://wardryx:8090/v1/policies '$WARDRYX_GATEWAY')\" = 403 ]"
check "cloud is NOT on the host"     "! curl -fsS -m3 -o /dev/null http://127.0.0.1:8080/healthz"
check "wardryx is NOT on the host"   "! curl -fsS -m3 -o /dev/null http://127.0.0.1:8090/healthz"
# Not the variable, the rule Docker actually wrote. A default that says
# loopback while the published port says otherwise is worse than no default at
# all, because the banner then tells you the box is closed while it is open.
check "gateway published on $GATEWAY_BIND only" \
      "$DC port tokenfuse-gateway 4100 | grep -q '^${GATEWAY_BIND}:'"

# The operator's tunnel. Checked from the CONSOLE's side rather than the wg
# container's: what matters is not that a socket exists somewhere, it is that
# the unprivileged console can actually manage peers through it. A tunnel that
# is up while the console cannot reach its socket is the exact failure this
# split was built to avoid, and it looks perfectly healthy from outside.
check "wireguard interface is up" \
      "$DC exec -T wg wg show ${WG_IFACE:-wg-op} public-key"
# Only when a console is actually installed. The stack runs perfectly well
# without one (the planes enforce with or without a UI), and an unconditional
# check here would fail on a deployment that is entirely correct.
#
# The RELAY, not the daemon's own socket: wireguard-go requires its socket to
# stay 0700 and stops answering if that changes, so the console is given a
# group-readable forwarder instead. Checked from the console's side, because a
# tunnel that is up while the console cannot reach it looks healthy from
# everywhere else.
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx console; then
  check "console can manage peers over UAPI" \
        "$DC exec -T console test -r /var/run/wireguard/console.sock"
fi
# `--protocol udp <port>`, not `<port>/udp`: compose parses the argument as a
# bare integer and fails with "strconv.ParseUint: invalid syntax" on the form
# `docker port` accepts, so the check reported a healthy tunnel as broken.
# TLS, checked from inside the tunnel's own network rather than the host: this
# is deliberately not reachable from anywhere else, so a check that could see
# it from the host would mean the boundary had failed.
# A TCP check, not an HTTPS one. The certificate is issued for the console's
# domain, so a request that arrives with any other server name is refused by
# design - which means a naive `wget https://caddy/...` fails on a perfectly
# healthy deployment and would teach the reader to ignore a red line.
check "console TLS is listening" "$DC exec -T wg nc -z caddy 443"
check "console TLS names ${CONSOLE_DOMAIN:-the configured domain}" \
      "$DC exec -T caddy sh -c 'grep -q \"^${CONSOLE_DOMAIN}\" /etc/caddy/Caddyfile'"
check "tunnel accepts on ${WG_LISTEN_PORT:-51820}/udp" \
      "$DC port --protocol udp wg ${WG_LISTEN_PORT:-51820} | grep -q ':${WG_LISTEN_PORT:-51820}$'"
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx console; then
  check "console answers on loopback" "curl -fsS -m5 -o /dev/null http://127.0.0.1:7420/healthz"
  # Reachability is not usefulness. The console comes up perfectly whether or
  # not it can resolve the planes behind it, and the difference is only visible
  # as an Overview that says "No environment found" after you sign in - which
  # is exactly the moment it is most expensive to discover.
  check "console resolves the money plane" \
        "$DC exec -T console printenv TOKENFUSE_CLOUD_ADMIN_KEY"
  check "console resolves the policy plane" \
        "$DC exec -T console printenv WARDRYX_ADMIN_KEY"
fi

# The console is HTTPS on a name now, which needs two things the operator has
# to do on their own device when that name is the private default. Printing the
# URL alone would send them to a page their browser refuses to load, with an
# error about the certificate rather than about the missing steps.
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  CONSOLE_ACCESS_NOTE="
  The certificate is publicly trusted, so nothing has to be installed on your
  devices. Point $CONSOLE_DOMAIN at 10.9.0.1 in DNS and open it inside the
  tunnel."
else
  CONSOLE_ACCESS_NOTE="
  That name is private and its certificate is self-issued, so each device you
  use needs two one-time steps:

      echo \"10.9.0.1 $CONSOLE_DOMAIN\" | sudo tee -a /etc/hosts
      # then trust this box's own CA:
      #   docker compose exec caddy cat /data/caddy/pki/authorities/local/root.crt

  Both disappear once you set a real domain and CLOUDFLARE_API_TOKEN in .env:
  the certificate becomes publicly trusted and nothing needs installing.
  A passkey cannot be enrolled until one of these is done - WebAuthn refuses a
  bare IP and refuses an untrusted certificate, so http://10.9.0.1 is not a
  place the ceremony can run."
fi

# What to tell the operator depends on the boundary this box actually has, and
# the closed case needs the longer answer: a re-run will NOT widen it, because
# .env is deliberately left alone once it exists. Saying "re-run with
# GATEWAY_BIND=0.0.0.0" would be advice that quietly does nothing.
case "$GATEWAY_BIND" in
  127.0.0.1|localhost|::1)
    REACH="  The gateway answers on this box only. Nothing here is reachable from another
  machine, which is the default on purpose. On the box itself:

      ANTHROPIC_BASE_URL=http://127.0.0.1:4100

  When you want agents elsewhere to call it, publish it deliberately. Editing
  .env is the way; re-running this script will not do it for you:

      cd $STACK_DIR
      sed -i 's/^GATEWAY_BIND=.*/GATEWAY_BIND=0.0.0.0/' .env
      ${COMPOSE[*]} up -d
      # then, from anywhere: ANTHROPIC_BASE_URL=http://$PUBLIC_IP:4100

  Port 4100 is then open to the internet. Put a cloud security group in front
  of it: ufw will not do it, because Docker's own iptables rules bypass ufw's
  INPUT chain and a published container port stays reachable through a 'deny'." ;;
  *)
    REACH="  Point an agent at the gateway. Its calls are then metered, budgeted and
  policy-checked wherever that agent runs:

      ANTHROPIC_BASE_URL=http://$PUBLIC_IP:4100" ;;
esac

cat <<EOF

$(printf '\033[1m')$([ "$fail" -eq 0 ] && echo "Up, and every check passed." || echo "Up, with $fail failed check(s) above.")$(printf '\033[0m')

$REACH

${CONSOLE_PASSWORD:+  Console sign-in, shown once and stored nowhere:

      user      $CONSOLE_USER
      password  $CONSOLE_PASSWORD

}  The console is on loopback by design, so it is reached over a tunnel. This
  box runs the WireGuard side and issues your device its own peer config:
  sign in, open Remote, and take the QR. The config is shown once.

      console  https://$CONSOLE_DOMAIN   (once your tunnel is up)
      tunnel   $WG_ENDPOINT_HOST:${WG_LISTEN_PORT:-51820}/udp
$CONSOLE_ACCESS_NOTE

  Issuing and revoking a device both need a passkey, like a kill does: a road
  into the control plane is not something a stolen session should be able to
  mint quietly. Enrol one on first sign-in.

  SSH stays as the way in before the first device exists:

      ssh -L 17420:127.0.0.1:7420 root@$PUBLIC_IP
      open http://localhost:17420

  Manage it:

      cd $STACK_DIR && ${COMPOSE[*]} ps
      cd $STACK_DIR && ${COMPOSE[*]} logs -f tokenfuse-gateway
      cd $STACK_DIR && ${COMPOSE[*]} down     # stop, keeping every volume

EOF
# The banner above already said what failed, so the trap must not narrate a
# non-zero exit here as if the script had crashed: it ran to the end.
EXPLAINED=1
exit "$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
