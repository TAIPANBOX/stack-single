#!/usr/bin/env bash
# The agent stack on one machine, ready for agents that live somewhere else.
#
#   curl -fsSL https://raw.githubusercontent.com/TAIPANBOX/stack-single/main/install.sh | bash
#
# or, from a clone:
#
#   ./install.sh
#
# What this is NOT: `stack-up`, which is the local sandbox. That one binds
# 127.0.0.1 on purpose and needs Rust, Go and Node on your machine to build
# from source. This one is for a box you will point real agents at: the
# toolchains live inside the images, the gateway is published, the services
# come back after a reboot, and the console has a sign-in that exists.
#
# Requires: a Debian or Ubuntu host, root, and outbound internet. Everything
# else it installs. Roughly 3GB of disk for the images and ten minutes for the
# first build, most of it Rust.
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/TAIPANBOX/stack-k8s/main}"
STACK_DIR="${STACK_DIR:-/opt/agent-stack}"
SRC_DIR="${SRC_DIR:-$STACK_DIR/src}"
CONSOLE_TOKEN="${CONSOLE_TOKEN:-}"   # a GitHub token with access to the closed console repo
CONSOLE_USER="${CONSOLE_USER:-ops}"
GATEWAY_BIND="${GATEWAY_BIND:-0.0.0.0}"

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
trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n\033[1;31m!! install.sh stopped at line %s (exit %s)\033[0m\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the installer, please report it.\n" >&2
      printf "   Nothing is half-configured that a re-run will not redo: this script is safe to run again.\n" >&2
      exit $rc' EXIT

# ---- 0. preflight -----------------------------------------------------------
[ "$(id -u)" = "0" ] || die "run as root: this installs packages and a firewall rule."
[ -r /etc/os-release ] || die "no /etc/os-release: this expects Debian or Ubuntu."
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
if [ -n "$CONSOLE_TOKEN" ]; then
  if [ -d genaryx/.git ]; then (cd genaryx && git pull -q --ff-only 2>/dev/null || true)
  else git clone --depth 1 -q "https://x-access-token:${CONSOLE_TOKEN}@github.com/TAIPANBOX/genaryx.git" genaryx \
      || die "could not clone the console; is the token valid for TAIPANBOX/genaryx?"; fi
elif [ -d "$SRC_DIR/genaryx-a360" ]; then
  note "console source already present (placed here directly), no token needed"
else
  note "no CONSOLE_TOKEN and no genaryx-a360 source: installing the governed"
  note "stack WITHOUT the console. The planes enforce with or without a UI."
  note "To add it later, copy the console source to $SRC_DIR/genaryx-a360 and re-run."
fi

say "fetching the image definitions"
mkdir -p "$SRC_DIR/dockerfiles"
for f in go-service.Dockerfile tokenfuse.Dockerfile console.Dockerfile; do
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
  cat > .env <<EOF
# Generated by install.sh. Nothing here is a default: every value is unique to
# this box. Keep the file at 0600 and out of any repository.
POLICY_DB_PASSWORD=$POLICY_DB_PASSWORD
POLICY_DB_DSN=postgres://wardryx:$POLICY_DB_PASSWORD@policy-db:5432/wardryx?sslmode=disable
APPROVAL_SECRET=$(gen 64)
CLOUD_KEYS=$(gen 40)
CLOUD_ADMIN=
WARDRYX_KEYS=$(gen 40)
WARDRYX_GATEWAY=
WARDRYX_ADMIN=
GATEWAY_BIND=$GATEWAY_BIND
EOF
  # The gateway and the console authenticate to the planes with keys the
  # planes accept, so those are the SAME values, not new ones.
  sed -i "s|^CLOUD_ADMIN=.*|CLOUD_ADMIN=$(grep '^CLOUD_KEYS=' .env | cut -d= -f2)|" .env
  sed -i "s|^WARDRYX_GATEWAY=.*|WARDRYX_GATEWAY=$(grep '^WARDRYX_KEYS=' .env | cut -d= -f2)|" .env
  sed -i "s|^WARDRYX_ADMIN=.*|WARDRYX_ADMIN=$(grep '^WARDRYX_KEYS=' .env | cut -d= -f2)|" .env
  chmod 600 .env
  note "generated .env (0600)"
fi

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
note "published to the world: 4100 (gateway) only"
note "loopback only: 7420 (console), reachable over your own tunnel"
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
check "gateway answers on 4100"      "curl -fsS -m5 -o /dev/null http://127.0.0.1:4100/healthz"
check "cloud answers inside"         "$DC exec -T tokenfuse-cloud curl -fsS -m5 -o /dev/null http://127.0.0.1:8080/healthz || $DC exec -T tokenfuse-gateway curl -fsS -m5 -o /dev/null http://tokenfuse-cloud:8080/healthz"
check "wardryx answers inside"       "$DC exec -T tokenfuse-gateway curl -fsS -m5 -o /dev/null http://wardryx:8090/healthz"
check "idryx answers inside"         "$DC exec -T tokenfuse-gateway curl -fsS -m5 -o /dev/null http://idryx:8081/healthz"
check "policy store is up"           "$DC exec -T policy-db pg_isready -U wardryx -d wardryx"
check "cloud is NOT on the host"     "! curl -fsS -m3 -o /dev/null http://127.0.0.1:8080/healthz"
check "wardryx is NOT on the host"   "! curl -fsS -m3 -o /dev/null http://127.0.0.1:8090/healthz"
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx console; then
  check "console answers on loopback" "curl -fsS -m5 -o /dev/null http://127.0.0.1:7420/healthz"
fi

PUBLIC_IP="$(curl -fsS -m5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<EOF

$(printf '\033[1m')$([ "$fail" -eq 0 ] && echo "Up, and every check passed." || echo "Up, with $fail failed check(s) above.")$(printf '\033[0m')

  Point an agent at the gateway. Its calls are then metered, budgeted and
  policy-checked wherever that agent runs:

      ANTHROPIC_BASE_URL=http://$PUBLIC_IP:4100

${CONSOLE_PASSWORD:+  Console sign-in, shown once and stored nowhere:

      user      $CONSOLE_USER
      password  $CONSOLE_PASSWORD

}  The console is on loopback by design. Reach it over your own tunnel:

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
