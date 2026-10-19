#!/usr/bin/env bash
# The agent stack on one machine, ready for agents that live somewhere else.
#
#   curl -fsSL https://raw.githubusercontent.com/TAIPANBOX/stack-single/main/install.sh | bash
#
# or, from a clone:
#
#   ./install.sh
#
# Once it is installed, `./install.sh status` runs the same checks again against the
# running stack and changes nothing. See the README, "Checking an installed box again".
#
# What this is NOT: `stack-up`, which is the local sandbox. That one needs
# Rust, Go and Node on your machine to build from source and stops when you
# press Ctrl-C. This one is for a box you will point real agents at: the
# toolchains live inside the images, the services come back after a reboot,
# and the console has a sign-in that exists.
#
# What this box does NOT run, so you can compare before installing rather
# than after: none of stack-up's governance routines (a FinOps export, a
# crypto-inventory trend, a quality-drift check, an identity-anomaly sweep,
# an on-box chain verification, the record seal and an opt-in fire drill) run here
# on any schedule; stack-k8s runs three of
# the four safe ones as CronJobs, stack-up runs its six default ones as OS timers, and
# this compose file runs none of them. See the README's "What this box does
# not run" section for the rest of the comparison, including the memory
# plane.
#
# The gateway is published to the host's loopback only, until you say
# otherwise. Publishing an enforcement plane to the internet is a decision, not
# a default, so it is one word you type rather than one you inherit:
#
#   GATEWAY_BIND=0.0.0.0 ./install.sh     # first run: agents elsewhere can call it
#
# A browser for the egress plane is the other opt-in, and it is opt-in for a
# size rather than for a risk: about 1 GB against 15 MB. Without it the fetcher
# runs no JavaScript, which is right for most boxes and wrong for agents that
# read pages assembled in the browser.
#
#   WITH_BROWSER=1 ./install.sh           # also builds stack/scopyx-browser:dev
#   WITH_RECORD=1 ./install.sh            # also builds stack/trailryx:dev
#   WITH_TYPED=1 ./install.sh             # pulls AND starts the typed plane (stub backend)
#   TYPED_MODE=jev TYPED_JEV_KEY_FILE=/path/to/key ./install.sh
#   TYPED_MODE=own-model TYPED_MODEL_URL=http://host.docker.internal:11434/v1 \
#     TYPED_MODEL_NAME=qwen2.5:7b ./install.sh
#   TYPED_TRAINING=1 (with any typed mode above) also switches on typryx's local
#     training log, in a volume on this box; off unless you ask, 0 turns it off
#   WITH_DELEGATION=1 ./install.sh        # pulls AND starts vouchryx
#   WITH_CLOSURE=1 ./install.sh           # one secret the gateway and the console
#     share, so a person can close a retained reservation with evidence; off
#     unless asked. See section 3d and the README.
#   TYPED_RISK_SIGNAL=1 (with any typed answers above, never with them off) also
#     starts typryx's wardryx-proxy and points ONLY the MCP broker's policy
#     client at it, so a tool call carries typryx's risk class to wardryx; it
#     is off unless you ask, 0 turns it off. See section 0b and the README.
#   RUN_BUDGET_CEILING_USD=2.50 ./install.sh   # the most a caller can make one
#     run's budget (tokenfuse 1.5.0), 5.00 unless you say otherwise
#   TOKENFUSE_FIREWALL=shadow ./install.sh     # the agent firewall: enforce (the
#     default), shadow or off; see section 0d and the README
#   CLIENT_KEYS_FILE=/path/keys.txt IDENTITY_MAP_FILE=/path/identity.json ./install.sh
#     # who may call the gateway (secret:key_id lines) and which agent ids and
#     # unit each key speaks for; kept on a re-run, checked by the gateway image
#     # itself before anything restarts. Given neither, the installer mints a key
#     # for the console's copilot and one for your agents (written to
#     # $STACK_DIR/agent-key), each bound to its own agent ids: the gateway never
#     # answers a caller without a key. See section 0f.
#   OPENAI_DOOR=1 OPENAI_DOOR_UPSTREAM=https://api.openai.com/v1/chat/completions \
#     OPENAI_DOOR_CLIENT_KEYS_FILE=/path/keys.txt OPENAI_DOOR_IDENTITY_MAP_FILE=/path/map.json ./install.sh
#     # a second gateway on port 4110 for agents that speak the OpenAI wire, with
#     # keys and a map of its own; off unless asked, 0 turns it off. See section 0g.
#
# The typed-answer plane (typryx) answers a typed question from one of the
# templates baked into its image, with a probability for every option. The
# operator chooses where the answers come from, TYPED_MODE, and what leaves
# the box depends on it (section 0b below, and README, "Typed answers: choose
# where your data goes"):
#
#   TYPED_MODE=jev        the named fields of each question go to TypeSafe's
#                         hosted API; needs TYPED_JEV_KEY_FILE, a PATH to a
#                         file holding the key (metered, and never the default)
#   TYPED_MODE=own-model  a model server you run (Ollama, vLLM); needs
#                         TYPED_MODEL_URL (ending in /v1) and TYPED_MODEL_NAME,
#                         optionally TYPED_MODEL_KEY_FILE; nothing leaves your
#                         own hardware
#   TYPED_MODE=off        typryx is not installed (the default)
#
# WITH_TYPED=1 with no TYPED_MODE is unchanged: typryx on its free, deterministic
# stub backend, which makes no outbound call, recorded as TYPED_MODE=stub. With a
# terminal and nothing set,
# the installer asks. Without one, the choice is the environment's alone.
#
# WITH_TYPED=1 also brings up tokenfuse's MCP broker in front of it
# (tokenfuse-mcp-broker, same pinned image as the gateway, unchanged code,
# fronting typryx by configuration alone), bound to ${GATEWAY_BIND:-127.0.0.1}
# like the gateway itself: closed by default, one word to widen. This is the
# one profile this launcher starts on its own rather than leaving for a
# second manual `docker compose --profile typed up -d` (the way `record` and
# `egress` still do), so install.sh's own end-of-run checks can verify it.
#
# The delegation plane (vouchryx) lets the gateway verify a PROVED delegation
# chain instead of trusting a claimed one. It is off by default and needs the
# operator to name the trusted upstream issuer(s) that mint the subject and
# actor tokens it exchanges: VOUCHRYX_TRUSTED_ISSUERS, one `iss|aud|jwks-path`
# per line, the jwks-path readable inside ./delegation. With neither that nor
# WITH_DELEGATION_DEMO_ISSUER=1 (a clearly-labelled, self-signed issuer for
# trying this out, never a production posture), WITH_DELEGATION=1 refuses
# before anything starts, naming what is missing. Like WITH_TYPED, this
# brings vouchryx up on its own rather than leaving it for a second manual
# command, because the gateway needs its JWKS on disk before it can start.
#
# Re-running never changes an existing box: the value lives in .env from the
# first run, and .env is left alone.
#
# Requires: a Debian or Ubuntu host, root, and outbound internet. Everything
# else it installs. Every image is PULLED from ghcr.io and nothing is compiled.
# `BUILD_FROM_SOURCE=1`
# restores the old behaviour, and that path is the one that costs roughly 3GB
# of disk and a long wait, most of it Rust.
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/TAIPANBOX/stack-k8s/main}"
# The image definitions come from stack-k8s as a whole, because some of them
# need files beside the Dockerfile (see the fetch below).
REPO_TARBALL="${REPO_TARBALL:-https://api.github.com/repos/TAIPANBOX/stack-k8s/tarball/main}"
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
# Where the gateway is actually reached from outside its own container: the
# bind with 0.0.0.0 mapped to loopback (every address includes it) and an
# IPv6 literal bracketed, as a URL needs. Both section 8's own health check and
# the delegation plane's TOKENFUSE_DELEGATION_URL (the origin a hand-off proof's
# DPoP `htu` is checked against) need the identical answer; two copies of this
# case statement disagreeing would be the same trap CLAUDE.md's WARDRYX_DB story
# already names, one variable over.
#
# A function, called again after every `. ./.env`, and not a value computed
# once here. The bind this run was given is only the bind the box HAS on a first
# install: on a re-run `.env` is sourced over it (the README's way to change the
# bind on an installed box is to edit GATEWAY_BIND there), and a probe worked
# out before that read the environment's default, loopback, and FAILed `gateway
# answers on 127.0.0.1:4100` on a healthy box whose gateway is published on one
# other address (measured 2026-10-13, Debian 13: FAIL with nothing in the
# environment, ok with GATEWAY_BIND exported, `curl http://192.168.1.10:4100/healthz`
# 200 throughout). The same stale value would have minted
# TOKENFUSE_DELEGATION_URL from the wrong address. CLAUDE.md invariant 11, gate
# scripts/bind-is-honoured.sh.
# gateway-probe: begin
gateway_probe_resolve() {
  case "$GATEWAY_BIND" in
    0.0.0.0) GATEWAY_PROBE=127.0.0.1 ;;
    *:*)     GATEWAY_PROBE="[$GATEWAY_BIND]" ;;
    *)       GATEWAY_PROBE="$GATEWAY_BIND" ;;
  esac
}
# gateway-probe: end
gateway_probe_resolve

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

# Whether the compose project has a service called NAME, for the `if` that
# decides whether a group of checks or a step applies at all. The list is read to
# its end before anything looks at it, and not piped into `grep -q`: grep exits at
# its first match, compose is still writing the rest of the list, hits the closed
# pipe and exits non-zero, and under `set -o pipefail` that fails the pipeline
# although the name was there (check() in section 8 has the measured case, for a
# log). Here a false answer is quieter than a red check: the console's checks, or
# the broker's, are skipped, and the run still ends "every check passed".
# (gate: scripts/checks-survive-a-closed-pipe.sh lifts this and runs it.)
# compose-has: begin
compose_has() { # NAME
  local out
  out="$("${COMPOSE[@]}" ps --services 2>/dev/null)" || return 1
  grep -qx -- "$1" <<<"$out"
}
# compose-has: end

# A check's command string is evaluated with pipefail OFF, in a subshell, and that
# is deliberate. Several checks read a container's log through a pipe,
# `$DC logs svc 2>&1 | grep -q PATTERN`, and `grep -q` exits at its first match.
# `docker compose logs` is still writing, hits the closed pipe and exits 255, and
# under the `set -o pipefail` this script runs with, that failed the pipeline
# although the line WAS in the log. Measured 2026-10-13 on Debian 13 (Docker
# 26.1.5, Compose 2.26.1): `set -o pipefail; docker compose logs tokenfuse-gateway
# 2>&1 | grep -qF 'client auth: ON (3 key(s))'`, five times, returned 0 255 255 0
# 255; the same without -q, where grep reads everything, 0 five times. It made two
# installs report `FAIL client keys: the gateway holds 3` and `FAIL identity map:
# the gateway reads it` on a healthy box, and it is a race a CI runner happens to
# win. The other direction is worse: a check written the negative way,
# `! $DC logs svc 2>&1 | grep -qE BAD`, read ok while the bad line WAS in the log,
# because the 255 failed the pipeline and `!` turned that into a pass.
#
# So the verdict of a check is its reader's, the last command's, which is what a
# pipeline's status is without pipefail: grep found the line, or it did not. A
# producer that could not run at all leaves the reader nothing to find, so a
# positive check still FAILs, and the one negative check that would read ok on an
# unreadable log (identity map: every key is bound) is paired, on the same log,
# with a positive one that does not. Fixed here once rather than at each pipeline,
# so a check added next month cannot bring the race back.
# (gate: scripts/checks-survive-a-closed-pipe.sh lifts both helpers and runs this
# file's own log checks against a stub docker that exits 255 when its reader goes.)
# check-helpers: begin
check() { # name, command
  [ "$#" -eq 2 ] || die "internal: check() got $# arguments, expected 2 (\$1='${1:-}')"
  if ( set +o pipefail; eval "$2" ) >/dev/null 2>&1; then printf '   ok    %s\n' "$1"; else printf '   FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}
# The same, for a check that reads a container's LOG: retried for up to ten
# seconds. A log line is written once, some milliseconds after the process
# starts, and `docker compose logs` read moments after `up` has once come
# back without a line that was there a minute later: 2026-09-14, an arm64
# box, `gateway exports agent events` FAIL on run 1 with the line stamped
# nine seconds before the check, ok on run 2 with the same container and no
# restart. A one-shot read of a log is a race with the log driver; a check
# that stays red for ten seconds is a real absence.
check_log() { # name, command
  [ "$#" -eq 2 ] || die "internal: check_log() got $# arguments, expected 2 (\$1='${1:-}')"
  local left=10
  while [ "$left" -gt 0 ]; do
    if ( set +o pipefail; eval "$2" ) >/dev/null 2>&1; then printf '   ok    %s\n' "$1"; return 0; fi
    sleep 1; left=$((left - 1))
  done
  printf '   FAIL  %s\n' "$1"; fail=$((fail+1))
}
# check-helpers: end

# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
probe() { docker run --rm --network "$NET" busybox:1.36 wget -q -T5 -O /dev/null "$1"; }
# argv-free-http: begin
# A request that carries a credential goes to a throwaway busybox's STDIN and is sent
# with nc. It is never a --header on a command line: docker run, the container's own
# command line and ps would each show the key for as long as the request lasts, and
# a container's command line stays in docker inspect (the 2026-10-17 review's F-015).
# The headers are CRLF-terminated lines in one string, and the body follows a blank
# line. Prints the whole response. (gate: scripts/no-secret-on-argv.sh lifts this block.)
# shellcheck disable=SC2329,SC2317  # invoked indirectly, from http_status() and the checks that call it
http_request() { # method, url, headers (CRLF-terminated, may hold a key), body
  # Content-Length counts BYTES. Under a UTF-8 locale ${#body} counts characters, which
  # is shorter than the bytes sent for any non-ASCII body, so the server would stop reading early.
  local LC_ALL=C
  local method="$1" url="$2" hdrs="$3" body="$4" rest hostport path
  rest="${url#*://}"
  hostport="${rest%%/*}"
  path="/"
  [ "$rest" = "$hostport" ] || path="/${rest#*/}"
  {
    printf '%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n' "$method" "$path" "$hostport"
    printf '%s' "$hdrs"
    [ -z "$body" ] || printf 'Content-Length: %s\r\n' "${#body}"
    printf '\r\n%s' "$body"
  # nc must not see end-of-input on its stdin before the server has answered: busybox nc
  # closes the connection the moment stdin ends, and the real servers (Go net/http) then
  # cancel the request, so they answer nothing (measured 2026-10-19 against tokenfuse
  # v1.18.0: nc returned 0 and no bytes for healthz and for every key check; wget got 200).
  # So nc reads a FIFO, the request is written into it, and the FIFO stays open until nc
  # exits, which is when the server has answered and closed. No secret is on any argv.
  } | docker run -i --rm --network "$NET" busybox:1.36 \
        sh -c 'f=/tmp/nc-in; mkfifo "$f" || exit 1; nc -w 10 "$1" "$2" < "$f" & pid=$!; exec 3>"$f"; cat >&3; wait "$pid"' \
        sh "${hostport%%:*}" "${hostport##*:}"
}
# The status code on a response's first line, 0 when nothing answered.
# shellcheck disable=SC2329,SC2317  # invoked indirectly, from http_status() and the checks that call it
status_of() {
  local line code_
  line="${1%%$'\n'*}"
  read -r _ code_ _ <<<"${line%$'\r'}" || true
  printf '%s' "${code_:-0}"
}
# Prints the HTTP status only, so a check can assert 401 and 403 as PASSES. The
# Authorization header is sent even when the key is empty, as it always was.
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
http_status() { status_of "$(http_request GET "$1" "Authorization: Bearer $2"$'\r\n' "")"; }
# argv-free-http: end
# Same as http_status(), minus the header entirely: an empty bearer token is still a
# credential, and the point of this one is that none was presented at all.
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
codenokey() { docker run --rm --network "$NET" busybox:1.36 \
           wget -S -q -T5 -O /dev/null "$1" 2>&1 \
         | awk '/^  HTTP\//{c=$2} END{print c+0}'; }

# install_only check|check_log NAME COMMAND: a check that writes to the stack, or sends it a
# request the stack records. The install runs it; `status` says it skipped it and runs nothing.
install_only() {
  if [ "${STATUS:-0}" = 1 ]; then printf '   skip  %s  (install only: it writes to the stack)\n' "$2"; return 0; fi
  "$@"
}

# every check the verification runs, in the order it runs them. section 8 calls it
# after the install; `status` calls it against a stack that is already up. The list is
# written once, here, and both callers run this function (see status_main below).
stack_checks() {
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
# container sees and therefore what the check should be asking about. The
# planes and both gateways are on `core` (or reach it), and the agents' network,
# the browser's and the proxy's are not: so this is the planes' own view.
NET="agent-stack_core"
docker network inspect "$NET" >/dev/null 2>&1 || die "network $NET is missing: the stack did not start."
# Where the gateway is probed: the address the operator chose, not loopback.
# With GATEWAY_BIND set to ONE address (a tailnet address is the shape an
# appliance wants: reachable from the customer's clouds over a private mesh,
# not from the LAN) Docker publishes on that address only, so loopback
# refuses, and this line read FAIL twice on a healthy box while the same probe
# against that address answered 200 and "published on $GATEWAY_BIND only"
# below passed (#54, measured 2026-09-17). GATEWAY_PROBE itself comes from
# gateway_probe_resolve at the top of this file, called again after each read of
# .env, so on a re-run it follows the bind the box has, not the run's default.
check "gateway answers on $GATEWAY_PROBE:4100" "curl -fsS -m5 -o /dev/null http://$GATEWAY_PROBE:4100/healthz"
# The bus half of the stack. tokenfuse logs this line once at start when
# TOKENFUSE_EVENTS_PATH is set and the file could be opened; without it the
# exporter is off and idryx loads an empty log forever. Read from the
# gateway's own log rather than the file: a fresh box has served no traffic,
# so the file is legitimately empty and its size proves nothing yet.
check_log "gateway exports agent events" "$DC logs tokenfuse-gateway 2>&1 | grep -q 'NDJSON export enabled'"
# The run-budget ceiling (section 0c) is read from the gateway's own start-up
# line, not from the variable: tokenfuse 1.5.0 logs it once when the clamp is
# armed, so a gateway older than 1.5.0, or one that read no ceiling, has no such
# line and this goes red. Reading compose's environment instead would call a
# box green whose gateway ignored the setting.
check_log "gateway clamps a run budget to a ceiling" \
      "$DC logs tokenfuse-gateway 2>&1 | grep -q 'run budget ceiling: a caller-declared or default budget is clamped to it'"
check "cloud answers inside"         "probe http://tokenfuse-cloud:8080/healthz"
check "wardryx answers inside"       "probe http://wardryx:8090/healthz"
check "idryx answers inside"         "probe http://idryx:8081/healthz"
check "policy store is up"           "$DC exec -T policy-db pg_isready -U wardryx -d wardryx"
# Not the same question as the line above. pg_isready asks the database;
# /readyz asks wardryx whether IT can reach the store with the DSN and the
# network it was given (wardryx 1.0.3, #63), answering 503 when it cannot,
# while /healthz stays 200 and a policy write fails. A wrong WARDRYX_DB, or a
# store the plane cannot resolve, passes both checks above and fails here.
check "policy plane reaches its store" "probe http://wardryx:8090/readyz"

# The three below are about the KEYS, and they exist because a plane with a
# malformed key spec starts cleanly, authenticates nobody, and answers 401 to
# its own console. Reachability alone would have called that deployment green.
check "policy plane accepts its admin key"   "[ \"\$(http_status http://wardryx:8090/v1/policies '$WARDRYX_ADMIN')\" = 200 ]"
check "policy plane rejects an unknown key"  "[ \"\$(http_status http://wardryx:8090/v1/policies nonsense-not-a-key)\" = 401 ]"
check "gateway's key cannot write policy"    "[ \"\$(http_status http://wardryx:8090/v1/policies '$WARDRYX_GATEWAY')\" = 403 ]"

# The gateway's own admin key, the same shape of check for the same reason:
# this one MUST fail to pass, exactly like the "not reachable from the host"
# checks below. A gateway that answers /v1/runs to nobody in particular has
# reopened the routes TOKENFUSE_ALLOW_OPEN_OBS used to hold open on purpose.
check "gateway refuses /v1/runs without the admin key" \
      "c=\$(codenokey http://tokenfuse-gateway:4100/v1/runs); case \"\$c\" in 401|403) true ;; *) false ;; esac"
check "gateway serves /v1/runs with the admin key" \
      "[ \"\$(http_status http://tokenfuse-gateway:4100/v1/runs '$GATEWAY_ADMIN')\" = 200 ]"

# Client keys and the identity map (sections 0f and 3e), only on a box that has
# them. Read from the running gateway, not from .env: its own start-up lines, and
# two calls it must refuse 401. A gateway that did NOT hold the keys refuses the
# same call before anything reaches a provider, so a 401 here can only be the
# gateway asking for a key, never a provider's: measured 2026-10-13 on a gateway
# with the keys taken out, 400 identity_required (no agent id while the policy
# plane enforces), and 402 with an agent id, because each call also declares a
# budget of one micro-dollar. busybox wget prints no header after an error
# status, so the status is all there is to read. No call
# here names an agent: a mismatch would be a high-severity event on the bus, and
# an installer must not page its operator on every run (CI's identity leg sends
# that one, see .github/workflows/install.yml).
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
fuse_refusal() { # client key or "" for none, then main (default) or openai: prints the status of a metered call
  local hdrs url body
  url=http://tokenfuse-gateway:4100/v1/messages
  local body='{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"install check"}]}'
  if [ "${2:-main}" = openai ]; then
    # The OpenAI door's own route and body shape: the other route answers 400 on
    # this door before any key is asked for.
    url=http://tokenfuse-gateway-openai:4100/v1/chat/completions
    body='{"model":"gpt-4o-mini","max_tokens":1,"messages":[{"role":"user","content":"install check"}]}'
  fi
  hdrs="Content-Type: application/json"$'\r\n'"x-fuse-run-id: install-check"$'\r\n'"x-fuse-budget-usd: 0.000001"$'\r\n'
  [ -z "$1" ] || hdrs+="x-fuse-key: $1"$'\r\n'
  status_of "$(http_request POST "$url" "$hdrs" "$body")"
}
if [ "$IDENTITY_KEYS_COUNT" -gt 0 ]; then
  check_log "client keys: the gateway holds $IDENTITY_KEYS_COUNT" \
        "$DC logs tokenfuse-gateway 2>&1 | grep -qF 'client auth: ON ($IDENTITY_KEYS_COUNT key(s))'"
  install_only check "client keys: a call with no key is refused" \
        "[ \"\$(fuse_refusal '')\" = 401 ]"
  install_only check "client keys: a call with an unknown key is refused" \
        "[ \"\$(fuse_refusal install-check-not-a-client-key)\" = 401 ]"
fi
if [ "$IDENTITY_MAP_ON" = 1 ]; then
  check_log "identity map: the gateway reads it" \
        "$DC logs tokenfuse-gateway 2>&1 | grep -qF 'identity map: ON ('"
  check "identity map: every key is bound and every binding has a key" \
        "! $DC logs tokenfuse-gateway 2>&1 | grep -qE 'has no keys\\[\\] binding|has no matching TOKENFUSE_CLIENT_KEYS entry'"
fi
# The keys this installer minted (section 0f, CLAUDE.md invariant 35), only on a box
# that runs them. The agents' key is in its file, which only its owner can read, and
# is the one .env holds; Felyx holds its own key, and the id the console names it
# with is the one the minted map binds that key to (a RECORD_TRUST_DOMAIN changed
# by hand after the install turns this red until the installer runs again).
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
agent_key_file_ok() {
  local f="$STACK_DIR/agent-key"
  [ -n "${GATEWAY_AGENT_KEY:-}" ] && [ -f "$f" ] && [ "$(stat -c %a "$f")" = 600 ] && [ "$(cat "$f")" = "$GATEWAY_AGENT_KEY" ]
}
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
felyx_key_bound() {
  local id
  [ -n "$("${COMPOSE[@]}" exec -T console printenv GENARYX_COPILOT_FUSE_KEY 2>/dev/null)" ] || return 1
  id="$("${COMPOSE[@]}" exec -T console printenv GENARYX_COPILOT_AGENT_ID 2>/dev/null)" || return 1
  [ -n "$id" ] && grep -qF "{\"key_id\": \"felyx\", \"unit\": \"console\", \"agents\": [\"$id\"]}" "$STACK_DIR/identity/identity.json"
}
if [ "${IDENTITY_MINTED:-0}" = 1 ]; then
  check "client keys: the agents' key is in $STACK_DIR/agent-key, readable by its owner alone" "agent_key_file_ok"
  if compose_has console; then
    check "client keys: Felyx holds its own key, bound to the id the console names it with" "felyx_key_bound"
  fi
fi

# The OpenAI door (OPENAI_DOOR=1, section 0g), on every box that asked for it and
# never skipped there: a door that did not come up must turn these red. The same
# questions the gateway is asked: it answers on the operator's bind and nowhere
# wider, serves the OpenAI wire, exports to its own file, clamps a run budget, holds
# its own keys and map, and refuses a call with no key or an unknown one before
# anything reaches the upstream (the call's budget is one micro-dollar, and no agent
# is named, for the reason the gateway's checks above give).
if [ "$DOOR_ON" = 1 ]; then
  check "openai door answers on $GATEWAY_PROBE:4110" "curl -fsS -m5 -o /dev/null http://$GATEWAY_PROBE:4110/healthz"
  case "$GATEWAY_BIND" in
    127.0.0.1|localhost|::1|0.0.0.0) ;;
    *) check "openai door is NOT on loopback" "! curl -fsS -m3 -o /dev/null http://127.0.0.1:4110/healthz" ;;
  esac
  check "openai door published on $GATEWAY_BIND only" \
        "$DC port tokenfuse-gateway-openai 4100 | grep -q '^${GATEWAY_BIND}:'"
  check_log "openai door serves the OpenAI wire" \
        "$DC logs tokenfuse-gateway-openai 2>&1 | grep -q 'serving one door.*/v1/chat/completions'"
  check_log "openai door exports agent events" \
        "$DC logs tokenfuse-gateway-openai 2>&1 | grep -q 'NDJSON export enabled'"
  check_log "openai door clamps a run budget to a ceiling" \
        "$DC logs tokenfuse-gateway-openai 2>&1 | grep -q 'run budget ceiling: a caller-declared or default budget is clamped to it'"
  check_log "openai door: client keys: the door holds ${IDENTITY_openai_KEYS_COUNT:-0}" \
        "$DC logs tokenfuse-gateway-openai 2>&1 | grep -qF 'client auth: ON (${IDENTITY_openai_KEYS_COUNT:-0} key(s))'"
  check_log "openai door: identity map: the door reads it" \
        "$DC logs tokenfuse-gateway-openai 2>&1 | grep -qF 'identity map: ON ('"
  check "openai door: every key is bound and every binding has a key" \
        "! $DC logs tokenfuse-gateway-openai 2>&1 | grep -qE 'has no keys\\[\\] binding|has no matching TOKENFUSE_CLIENT_KEYS entry'"
  install_only check "openai door: a call with no key is refused" \
        "[ \"\$(fuse_refusal '' openai)\" = 401 ]"
  install_only check "openai door: a call with an unknown key is refused" \
        "[ \"\$(fuse_refusal install-check-not-a-client-key openai)\" = 401 ]"
fi

check "cloud is NOT on the host"     "! curl -fsS -m3 -o /dev/null http://127.0.0.1:8080/healthz"
check "wardryx is NOT on the host"   "! curl -fsS -m3 -o /dev/null http://127.0.0.1:8090/healthz"
# The companion of the first check, for a bind that is one address rather
# than every address: loopback must then REFUSE, the way the cloud and wardryx
# must refuse above, and this one has to fail to pass for the same reason. A
# gateway that answers on an address the operator did not name is published
# wider than they decided, and the check below reads Docker's rule for the
# named address without asking whether another one answers as well.
case "$GATEWAY_BIND" in
  127.0.0.1|localhost|::1|0.0.0.0) ;;
  *) check "gateway is NOT on loopback" "! curl -fsS -m3 -o /dev/null http://127.0.0.1:4100/healthz" ;;
esac
# Whether a mapping EXISTS at all, read from the container Docker is actually
# running, apart from whether it is on the right address (the next check).
# On 2026-09-17, after a reboot had failed the gateway's first bind, `up -d`
# printed `Started` for a container with no port mapping: healthz unreachable
# and `docker port` empty until `up -d --force-recreate tokenfuse-gateway`
# (#56). `Started` is compose's word for the container; this is Docker's
# word for the port.
check "gateway has a port mapping" \
      "docker port \"\$($DC ps -q tokenfuse-gateway)\" 4100/tcp | grep -q ."
# Not the variable, the rule Docker actually wrote. A default that says
# loopback while the published port says otherwise is worse than no default at
# all, because the banner then tells you the box is closed while it is open.
check "gateway published on $GATEWAY_BIND only" \
      "$DC port tokenfuse-gateway 4100 | grep -q '^${GATEWAY_BIND}:'"

# The chain verifier (agent-conform watch-dir). Two questions, because "running"
# is not "verifying". It has to be up and its first pass must have printed a line
# for a stream (PASS, or NOTE for an empty one: a fresh box has served no traffic
# and only empty streams): a verifier that exited 2 on a bus it could not read
# is restarting and prints errors instead. And its account must be able to write
# its own stream and nothing else on the bus, which is the only thing that
# contains it (compose cannot mount one file of a volume): both are asked of a
# throwaway busybox run as the verifier's own uid against the live volume, the
# second one a check that must fail to pass.
check_log "chain verifier is running and has read the bus" \
      "$DC ps --status running --services | grep -qx agent-conform && $DC logs agent-conform 2>&1 | grep -qE '(PASS|NOTE) [a-z-]+\\.ndjson'"
install_only check "chain verifier can write its own stream" \
      "docker run --rm --user 10002:10002 --group-add 10001 -v agent-stack_events:/e busybox:1.36 sh -c ': >> /e/agent-conform.ndjson'"
install_only check "chain verifier cannot write another plane's stream" \
      "! docker run --rm --user 10002:10002 --group-add 10001 -v agent-stack_events:/e busybox:1.36 sh -c ': >> /e/wardryx.ndjson'"
install_only check "chain verifier cannot create a file on the bus" \
      "! docker run --rm --user 10002:10002 --group-add 10001 -v agent-stack_events:/e busybox:1.36 sh -c ': > /e/not-its-own.ndjson'"

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
if compose_has console; then
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
if compose_has console; then
  check "console answers on loopback" "curl -fsS -m5 -o /dev/null http://127.0.0.1:7420/healthz"
  # Reachability is not usefulness. The console comes up perfectly whether or
  # not it can resolve the planes behind it, and the difference is only visible
  # as an Overview that says "No environment found" after you sign in - which
  # is exactly the moment it is most expensive to discover.
  check "console resolves the money plane" \
        "$DC exec -T console printenv TOKENFUSE_CLOUD_ADMIN_KEY"
  check "console resolves the policy plane" \
        "$DC exec -T console printenv WARDRYX_ADMIN_KEY"
  # Resolving the planes is still not the bus. The console keeps its history
  # in a store it has to CREATE at startup; with TAIPAN_HOME pointed at a
  # root-owned config directory it could not, logged one line and served on
  # with an empty Bus Explorer, on every install from 2026-08-31 to
  # 2026-09-14, and the two checks above were green throughout (genaryx#71,
  # #49). The console's own startup line is the only place this shows.
  check_log "console's bus is live" \
        "$DC logs console 2>&1 | grep -q 'bus LIVE' && ! $DC logs console 2>&1 | grep -q 'bus startup failed'"
  # The password section 7 printed has to work. The console reads whether it
  # has an operator once, at startup (stack-k8s GOTCHAS 50), and section 7 sets
  # one on a console that is already running, so a fresh box answered
  # `"configured":false` here and refused every sign-in with 503 while the
  # password was still on the screen. Retried like a log check: the console
  # was restarted moments ago.
  check_log "console knows its operator" \
        "curl -fsS -m5 http://127.0.0.1:7420/api/auth/session | grep -q '\"configured\":true'"
fi

# The typed plane's own door, only when WITH_TYPED actually brought it up
# (section 5): a check that asked a service nothing started would prove
# nothing, the same reasoning every other opt-in check here follows.
if compose_has tokenfuse-mcp-broker; then
  # Not `docker compose exec ... curl`: the same reason as the money and
  # policy planes above, this image has neither curl nor a shell. The MCP
  # wire is JSON-RPC over HTTP, so this is one wget POST with the right
  # headers, from the same throwaway busybox that probes everything else
  # here.
  # shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
  mcp_status() { # url, key (may be empty), method
    local url="$1" key="${2:-}" method="$3" hdrs body
    hdrs="Content-Type: application/json"$'\r\n'"X-Fuse-Mcp-Upstream: typryx"$'\r\n'
    [ -z "$key" ] || hdrs+="x-fuse-key: $key"$'\r\n'
    body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\"}"
    status_of "$(http_request POST "$url" "$hdrs" "$body")"
  }
  # shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
  mcp_refused_without_key() { # url: a tools/call with no credential is refused; with tokens on, by name
    local out status
    out="$(http_request POST "$1" "Content-Type: application/json"$'\r\n'"X-Fuse-Mcp-Upstream: typryx"$'\r\n' \
          '{"jsonrpc":"2.0","id":1,"method":"tools/call"}')"
    status="$(status_of "$out")"
    case "$status" in 401|403) ;; *) return 1 ;; esac
    # Under require a call with no credential at all is refused 401 before the agent door is
    # asked (the broker's "unauthorized" body); a static key the list does not name gets
    # agent_token_required. Either is the refusal this check exists for; 403 is not, there.
    if [ "$(identity_env_get TOKENFUSE_AGENT_TOKENS)" = require ]; then
      [ "$status" = 401 ] && grep -q -E 'agent_token_required|unauthorized' <<<"$out"
    fi
  }
  MCP_BROKER_KEY="$(sed -n 's/^TOKENFUSE_MCP_KEYS=\([^:]*\):.*/\1/p' .env 2>/dev/null | head -1)"
  # Named "reaches typryx", not "answers": the MCP wire reports an upstream
  # refusal as a JSON-RPC error object over HTTP 200, so this proves only that
  # the broker is up, authenticated the caller and forwarded to typryx.
  check "typed plane: broker reaches typryx for tools/list" \
        "[ \"\$(mcp_status http://tokenfuse-mcp-broker:4200/mcp '$MCP_BROKER_KEY' tools/list)\" = 200 ]"
  # The answer itself, read from the body: an `ask` whose typryx credential
  # travels only as the handle {{secret:typryx_key}}, resolved from the
  # broker's vault, must come back as a result with "isError":false. This is
  # the whole path (broker door, vault, _meta credential, typryx's own door,
  # a template, the stub backend), and it needs typryx v0.2.0 or later:
  # _meta credential reading is typryx#6, not in v0.1.0.
  # shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
  mcp_ask_answered() { # url, key
    local hdrs
    hdrs="Content-Type: application/json"$'\r\n'"X-Fuse-Mcp-Upstream: typryx"$'\r\n'"x-fuse-key: $2"$'\r\n'
    # The broker is a policy enforcement point on every box (invariant 36): it
    # asks wardryx about each tools/call and refuses one it cannot attribute, so
    # the check names an agent. No starter rule targets this id, so wardryx
    # allows it.
    hdrs+="x-fuse-agent-id: agent://local.invalid/install-check"$'\r\n'
    http_request POST "$1" "$hdrs" \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"template":"eval.outcome_met","state":{"task":"2+2","final_answer":"4"}},"_meta":{"typryx/key":"{{secret:typryx_key}}"}}}' \
      | grep -q '"isError":false'
  }
  if [ "$TYPED_PLANE" = jev ]; then
    # Not asked on purpose: this ask would go to TypeSafe's API, on every run
    # of this installer, spending on the operator's account and sending them a
    # question they did not write. typryx refuses to start on a missing or
    # empty key file (exit 2), so "typryx is running" below is what a wrong
    # key PATH looks like; a wrong key VALUE shows on the first real ask.
    [ "${STATUS:-0}" = 1 ] || note "jev: the ask check is skipped, it would send a question to TypeSafe and spend on every run"
  else
    install_only check "typed plane: an ask through the broker is answered" \
          "mcp_ask_answered http://tokenfuse-mcp-broker:4200/mcp '$MCP_BROKER_KEY'"
  fi
  if [ "$TYPED_PLANE" = jev ] || [ "$TYPED_PLANE" = own-model ]; then
    check_log "typed plane: typryx is running on its $TYPED_PLANE backend" \
          "$DC ps --status running --services | grep -qx typryx"
  fi
  # The typed risk signal (TYPED_RISK_SIGNAL=1), only when its proxy actually
  # came up. Three things are asked, none of which the broker's own checks
  # above can see. The proxy answers on the network it is meant to be on
  # (through it, wardryx's /healthz: a 200 here is the proxy AND its upstream).
  # It does NOT answer from the planes' network (core) and is not on the host:
  # both must fail to pass, because the proxy runs without a credential and who
  # can reach it is its only protection. And only the broker's policy client was
  # pointed at it: the LLM gateway keeps asking wardryx directly.
  if compose_has typryx-wardryx-proxy; then
    # shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
    risk_probe() { docker run --rm --network agent-stack_risk-signal busybox:1.36 wget -q -T5 -O /dev/null "$1"; }
    check "typed risk signal: the proxy answers on its own network" \
          "risk_probe http://typryx-wardryx-proxy:4330/healthz"
    check "typed risk signal: the proxy is NOT reachable from the planes' network" \
          "! probe http://typryx-wardryx-proxy:4330/healthz"
    check "typed risk signal: the proxy is NOT on the host" \
          "! curl -fsS -m3 -o /dev/null http://127.0.0.1:4330/healthz"
    check "typed risk signal: only the broker's policy client points at the proxy" \
          "[ \"\$($DC exec -T tokenfuse-mcp-broker printenv TOKENFUSE_WARDRYX_URL)\" = http://typryx-wardryx-proxy:4330 ] && [ \"\$($DC exec -T tokenfuse-gateway printenv TOKENFUSE_WARDRYX_URL)\" = http://wardryx:8090 ]"
    if [ "$TYPED_PLANE" = stub ]; then
      # The whole path, read off the bus: the ask check above made the broker
      # call wardryx through the proxy, and a decision wardryx recorded carries
      # the signal typryx added. Only on the stub, whose answer is immediate:
      # a real backend can miss the proxy's deadline, and a missing signal is
      # then correct, so the same read would fail a healthy box.
      install_only check_log "typed risk signal: a tool call's decision carries typryx's signal" \
            "docker run --rm -v agent-stack_events:/e:ro busybox:1.36 grep -q action.risk_class /e/wardryx.ndjson"
    else
      [ "${STATUS:-0}" = 1 ] || note "$TYPED_PLANE: whether a signal arrives is not checked, it depends on the backend answering inside the proxy's deadline"
    fi
  fi
  # Must fail to pass, like the admin-key checks above: a call this broker
  # would forward with nobody's key on it is the same open door those checks
  # exist to catch on a different plane.
  # Refused with no credential at all. With agent tokens on (the default) the broker names the refusal
  # agent_token_required; with them off it is a plain 401 or 403.
  install_only check "typed plane: a tools/call with no broker key is refused" \
        "mcp_refused_without_key http://tokenfuse-mcp-broker:4200/mcp"
fi

# The delegation plane's own checks, only when WITH_DELEGATION actually
# brought vouchryx up: the same reasoning as the typed plane above, a check
# that asked a service nothing started would prove nothing.
if compose_has vouchryx; then
  # Must fail to pass, exactly like "cloud is NOT on the host" above: vouchryx
  # is a real running service, deliberately never published (compose.yaml's
  # own comment on it says so), and a reachable JWKS endpoint on the host
  # would be the same open door those checks exist to catch on the money and
  # policy planes.
  check "vouchryx is NOT on the host" \
        "! curl -fsS -m3 -o /dev/null http://127.0.0.1:4310/.well-known/jwks.json"
  check "vouchryx answers inside" "probe http://vouchryx:4310/.well-known/jwks.json"
  # Reachability is not the same as the gateway actually trusting it: this
  # reads the environment variable this run wrote, the same shape "console
  # resolves the money plane" checks a wired value rather than a live call.
  check "gateway resolves the delegation door" \
        "$DC exec -T tokenfuse-gateway printenv TOKENFUSE_DELEGATION_ISSUER"
fi
}

# ---- status: the same checks, against the stack already installed -------------
# `./install.sh status` changes nothing. It reads .env and the running stack, runs
# stack_checks (the list section 8 runs, not a copy of it), and prints one line per
# check. No package, image, container or file is touched; the checks that would write
# are skipped and marked so. It runs as root or as a user in the docker group.
status_facts() { # what the install decided, read back from .env and the running stack
  IDENTITY_KEYS_COUNT=0; IDENTITY_MAP_ON=0; IDENTITY_openai_KEYS_COUNT=0; IDENTITY_MINTED=0
  DOOR_ON=0; TYPED_PLANE=off; TYPED_RISK_ON=0
  if [ "${GATEWAY_IDENTITY_MINTED:-}" = 1 ]; then IDENTITY_MINTED=1; fi
  if [ -n "${GATEWAY_CLIENT_KEYS:-}" ]; then
    IDENTITY_KEYS_COUNT=$(( $(printf '%s' "$GATEWAY_CLIENT_KEYS" | tr -cd ',' | wc -c) + 1 ))
  fi
  if [ -n "${GATEWAY_IDENTITY_MAP:-}" ]; then IDENTITY_MAP_ON=1; fi
  if [ -n "${OPENAI_DOOR_CLIENT_KEYS:-}" ]; then
    IDENTITY_openai_KEYS_COUNT=$(( $(printf '%s' "$OPENAI_DOOR_CLIENT_KEYS" | tr -cd ',' | wc -c) + 1 ))
  fi
  if compose_has tokenfuse-gateway-openai; then DOOR_ON=1; fi
  if compose_has typryx; then
    TYPED_PLANE=stub
    case "${TYPED_MODE:-}" in jev) TYPED_PLANE=jev ;; own-model) TYPED_PLANE=own-model ;; esac
  fi
  if compose_has typryx-wardryx-proxy; then TYPED_RISK_ON=1; fi
}
status_main() {
  STATUS=1
  [ -f "$STACK_DIR/.env" ] || die "nothing is installed in $STACK_DIR (there is no .env there), so there is no stack to check. Set STACK_DIR if it lives elsewhere. Nothing was changed."
  cd "$STACK_DIR"
  # shellcheck disable=SC1091  # generated at install time, not in this repo
  . ./.env
  gateway_probe_resolve
  [ -n "${GATEWAY_CLIENT_KEYS:-}" ] \
    || die "$STACK_DIR/.env holds no client keys: this box was installed before the gateway required them, and compose will not start it without them. Run ./install.sh once to mint them. Nothing was changed."
  if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
  else die "no docker compose on this machine, so the stack cannot be read. Nothing was changed."; fi
  status_facts
  printf 'status of the stack in %s\n' "$STACK_DIR"
  fail=0
  stack_checks
  EXPLAINED=1
  if [ "$fail" -eq 0 ]; then printf '\nevery check passed\n'; exit 0; fi
  printf '\n%s check(s) failed\n' "$fail"
  exit 1
}
if [ "${1:-}" = status ]; then status_main; fi

# ---- 0. preflight -----------------------------------------------------------
[ "$(id -u)" = "0" ] || die "run as root: this installs packages and a firewall rule."
[ -r /etc/os-release ] || die "no /etc/os-release: this expects Debian or Ubuntu."
# shellcheck disable=SC1091  # lives on the target machine, not in this repo
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die "this expects Debian or Ubuntu; found ${PRETTY_NAME:-unknown}." ;;
esac

# smtp-tls: begin
# heraldyx 0.8.0 sends mail only over TLS: STARTTLS by default, implicit TLS on port 465 on its own, and
# plain only to a loopback host. SMTP_TLS is written into .env as HERALDYX_SMTP_TLS. Unset is heraldyx's
# own default and writes nothing new. A value it does not read is refused here, before anything is installed,
# because heraldyx itself refuses to start on one. The refusal never echoes the value.
smtp_tls_valid() { # VALUE: one of the modes heraldyx reads, or empty for its default
  case "$1" in ""|starttls|implicit|plain) return 0 ;; *) return 1 ;; esac
}
smtp_tls_loopback() { # HOST[:PORT]: true when the host is one plain may be used with
  case "${1%:*}" in 127.*|localhost|'[::1]'|::1) return 0 ;; *) return 1 ;; esac
}
smtp_tls_resolve() {
  smtp_tls_valid "${SMTP_TLS:-}" \
    || die "SMTP_TLS must be starttls, implicit or plain, or unset for heraldyx's default (STARTTLS, or implicit on port 465). Nothing was installed."
  if [ "${SMTP_TLS:-}" = plain ] && [ -n "${SMTP_HOST:-}" ] && ! smtp_tls_loopback "$SMTP_HOST"; then
    die "SMTP_TLS=plain is for a loopback host only (127.0.0.0/8, ::1 or localhost), and SMTP_HOST is not one. Nothing was installed."
  fi
}
smtp_tls_resolve
# smtp-tls: end

# ---- 0b. typed answers: where does the data go? ------------------------------
# @decided 2026-09-30: an operator chooses where typed answers come from, one
# of three, and the choice is made and checked HERE, before a package is
# installed or a file is written (invariant 6, fail before doing half the job):
#
#   TYPED_MODE=jev        the named fields of each question go to TypeSafe's
#                         hosted Jev API. Needs TYPED_JEV_KEY_FILE, the PATH of
#                         a file holding the key (never the key itself).
#   TYPED_MODE=own-model  a model server the operator runs (Ollama, vLLM).
#                         Needs TYPED_MODEL_URL (ending in /v1) and
#                         TYPED_MODEL_NAME; TYPED_MODEL_KEY_FILE is optional.
#   TYPED_MODE=off        typryx is not installed. The default.
#
# WITH_TYPED=1 with no TYPED_MODE is exactly what it was before this existed:
# typryx on its stub backend, which makes no outbound call. The installer records
# that as TYPED_MODE=stub in .env, so a plain re-run keeps the stub, and
# TYPED_MODE=off turns it off.
#
# TYPED_TRAINING=1 (@decided 2026-09-30, off by default) sets typryx's
# TYPRYX_TRAINING_DIR to a directory inside the typryxdata volume, beside the
# ledger, so the operator can fine-tune a model of their own. It needs typryx
# installed (refused otherwise), it is independent of the mode and survives a
# change of mode, and TYPED_TRAINING=0 turns it off. It writes no .env line
# unless asked: off renders exactly what it rendered before.
#
# TYPED_RISK_SIGNAL=1 (@claude 2026-10-04, from the estate audit's launcher spec; off
# by default) puts typryx in front
# of wardryx on the MCP path only: `typryx wardryx-proxy` asks typryx
# `action.risk_class` about each tool call the broker is about to make and adds
# the answer as a signal, which a `hold_if_signal` policy rule can turn into a
# hold for a person, never a deny. It needs typryx installed (refused
# otherwise, naming what to set), it is independent of the mode and survives a
# change of mode, and TYPED_RISK_SIGNAL=0 turns it off. It writes three .env
# lines only when asked: off renders exactly what it rendered before. Nothing
# seeds a policy that reads the signal; until the operator writes one the
# signal changes nothing. (gate: scripts/typed-risk-signal.sh lifts this block
# too.)
#
# A key is only ever a FILE. It is copied into ./typed (0400, owned by the uid
# typryx runs as), mounted read only, named in .env by its path inside the
# container, and never expanded into a print call, an environment value or a
# log line. (gate: scripts/typed-data-mode.sh lifts this block out and runs it.)
#
# The block is functions only, so the gate can run it on its own; the calls are
# below: typed_resolve now, typed_apply once .env exists (section 3).
# typed-mode: begin
TYPED_PLANE=off        # off | stub | jev | own-model, what this run installs
TYPED_EXPLICIT=0       # 1 when this run's environment chose or changed the mode
TYPED_SAVED_MODE=""    # what .env already holds for TYPED_MODE, if anything
TYPED_URL=""
TYPED_NAME=""
TYPED_TIMEOUT=""
TYPED_TRAIN=""         # "" (this run says nothing), 1 (log on) or 0 (log off)
TYPED_RISK=""          # "" (this run says nothing), 1 (signal on) or 0 (signal off)
TYPED_RISK_ON=0        # 1 when this box runs the risk-signal proxy after this run

# The variables compose's typryx service reads that this block owns. Dropped as
# a set when the mode changes, so a switch never leaves the old mode's lines
# behind to be read by the new one.
TYPED_OWNED=(TYPRYX_BACKEND TYPRYX_JEV_KEY_FILE TYPRYX_OPENAI_URL TYPRYX_OPENAI_MODEL TYPRYX_OPENAI_KEY_FILE TYPRYX_TIMEOUT_MS)
# The risk signal's own three lines: the flag itself, and the two values compose
# hands the MCP broker's wardryx client (mode `enforce`, URL the proxy). Apart
# from TYPED_OWNED on purpose: the signal is the operator's own choice and
# survives a change of mode, like the training log.
TYPED_RISK_OWNED=(TYPED_RISK_SIGNAL TYPED_RISK_WARDRYX_MODE TYPED_RISK_WARDRYX_URL)

typed_env_get() { # NAME: what .env holds for NAME, single quotes removed
  local v
  [ -f "$STACK_DIR/.env" ] || return 0
  v="$(sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env")"
  v="${v#\'}"
  v="${v%\'}"
  printf '%s' "$v"
}

# A readable regular file with something other than whitespace in it. Prints
# nothing: what is in the file is the one thing this block never shows.
typed_file_ok() {
  [ -n "$1" ] && [ -f "$1" ] && [ -r "$1" ] && LC_ALL=C grep -q '[^[:space:]]' "$1"
}

typed_url_ok() {
  local re='^https?://[^[:space:]/?#@]+(/[^[:space:]?#@]*)?/v1$'
  [[ "$1" =~ $re ]]
}

typed_set_env() { # NAME VALUE: replace or add NAME in .env, single-quoted
  local tmp val
  val="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf "%s='%s'\n" "$1" "$val" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
}

typed_forget_env() { # NAME...: drop these lines from .env
  local tmp pat
  pat="^($(IFS='|'; printf '%s' "$*"))="
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -Ev "$pat" "$STACK_DIR/.env" || true; } >"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
}

# SRC DST: a copy of a key file the container can read and nothing else can
# change. A copy rather than a mount of the operator's own file, because a bind
# mount keeps host ownership and a key the operator keeps 0600 for themselves
# is unreadable by uid 20005 (typryx, CLAUDE.md invariant 41).
typed_install_key() {
  local dir="$STACK_DIR/typed"
  mkdir -p "$dir" || die "could not create $dir"
  chmod 0755 "$dir" || die "could not set the mode of $dir"
  ( umask 077; cat "$1" >"$dir/$2.tmp" ) || die "could not copy the key file into $dir"
  chown 20005:20005 "$dir/$2.tmp" || die "could not hand the key file to the uid typryx runs as"
  chmod 0400 "$dir/$2.tmp" || die "could not set the mode of the key file"
  mv -f "$dir/$2.tmp" "$dir/$2" || die "could not put the key file in place"
  note "key file installed at $dir/$2 (read only; its contents are never shown)"
}

# Decide what this run installs, and refuse, naming what is missing, before
# anything has been touched. Sets TYPED_PLANE.
typed_resolve() {
  local want="${TYPED_MODE:-}" mode

  TYPED_SAVED_MODE="$(typed_env_get TYPED_MODE)"
  case "$TYPED_SAVED_MODE" in
    ""|jev|own-model|stub|off) ;;
    *) die ".env holds an unknown TYPED_MODE; it must be jev, own-model, stub or off. Nothing was changed." ;;
  esac
  case "$want" in
    ""|jev|own-model|off) ;;
    *) die "TYPED_MODE must be jev, own-model or off. Nothing was installed." ;;
  esac

  # @decided 2026-09-30: typryx's local training log is opt-in and off by
  # default. TYPED_TRAINING=1 turns it on, 0 turns it off again, and nothing
  # set leaves a box as it is. It is read apart from TYPED_EXPLICIT on purpose:
  # asking for the log is not choosing a mode, so it must not trip the "a
  # setting with no mode" refusal below when WITH_TYPED=1 is the stub.
  TYPED_TRAIN="${TYPED_TRAINING:-}"
  case "$TYPED_TRAIN" in
    ""|0|1) ;;
    *) die "TYPED_TRAINING must be 1 (log on) or 0 (log off). Nothing was installed." ;;
  esac

  # @claude 2026-10-04: the typed risk signal is opt-in and off by default,
  # read apart from TYPED_EXPLICIT for the training log's reason: asking for it
  # is not choosing a mode.
  TYPED_RISK="${TYPED_RISK_SIGNAL:-}"
  case "$TYPED_RISK" in
    ""|0|1) ;;
    *) die "TYPED_RISK_SIGNAL must be 1 (signal on) or 0 (signal off). Nothing was installed." ;;
  esac

  TYPED_EXPLICIT=0
  if [ -n "$want" ] || [ -n "${TYPED_JEV_KEY_FILE:-}${TYPED_MODEL_URL:-}${TYPED_MODEL_NAME:-}${TYPED_MODEL_KEY_FILE:-}${TYPED_MODEL_TIMEOUT_MS:-}" ]; then
    TYPED_EXPLICIT=1
  fi

  # The order: this run's TYPED_MODE, then a jev or own-model choice an earlier
  # run saved, then WITH_TYPED=1 or a stub an earlier run saved, then off. A
  # saved `off` is the weakest of these on purpose: an explicit WITH_TYPED=1 is a
  # newer, louder answer than "not asked for yet".
  if [ -n "$want" ]; then
    mode="$want"
  elif [ "$TYPED_SAVED_MODE" = jev ] || [ "$TYPED_SAVED_MODE" = own-model ]; then
    mode="$TYPED_SAVED_MODE"
  elif [ -n "${WITH_TYPED:-}" ] || [ "$TYPED_SAVED_MODE" = stub ]; then
    mode=stub
  else
    mode=off
  fi
  if [ "$TYPED_EXPLICIT" = 1 ] && [ -z "$want" ] && { [ "$mode" = off ] || [ "$mode" = stub ]; }; then
    die "a TYPED_* setting was given without TYPED_MODE, so it would be ignored. Set TYPED_MODE=jev or TYPED_MODE=own-model with it. Nothing was installed."
  fi
  if [ "$TYPED_TRAIN" = 1 ] && [ "$mode" = off ]; then
    die "TYPED_TRAINING=1 has no typryx to log for: typed answers are off. Set WITH_TYPED=1 or TYPED_MODE=jev or TYPED_MODE=own-model with it. Nothing was installed."
  fi

  if [ "$TYPED_RISK" = 1 ] && [ "$mode" = off ]; then
    die "TYPED_RISK_SIGNAL=1 has no typryx to ask: typed answers are off. Set WITH_TYPED=1 or TYPED_MODE=jev or TYPED_MODE=own-model with it. Nothing was installed."
  fi
  # What this box runs once the run is over: this run's word if it said one,
  # else what an earlier run saved, and never with typryx off.
  case "$TYPED_RISK" in
    1) TYPED_RISK_ON=1 ;;
    0) TYPED_RISK_ON=0 ;;
    *) if [ "$(typed_env_get TYPED_RISK_SIGNAL)" = 1 ]; then TYPED_RISK_ON=1; else TYPED_RISK_ON=0; fi ;;
  esac
  if [ "$mode" = off ]; then
    if [ "$TYPED_RISK_ON" = 1 ]; then
      note "TYPED_RISK_SIGNAL is saved in .env and does nothing while typed answers are off"
    fi
    TYPED_RISK_ON=0
  fi

  case "$mode" in
    off)
      if [ "$want" = off ] && [ -n "${WITH_TYPED:-}" ]; then
        note "TYPED_MODE=off: typryx is not installed, and WITH_TYPED=1 does not override it"
      fi
      ;;
    stub)
      if [ -n "${WITH_TYPED:-}" ]; then
        note "typed answers: WITH_TYPED=1 with no TYPED_MODE, so typryx runs on its stub backend (no outbound call), as before TYPED_MODE existed"
      else
        note "typed answers: the stub backend (no outbound call), kept from an earlier run. TYPED_MODE=off turns it off"
      fi
      ;;
    jev)
      if [ -n "${TYPED_JEV_KEY_FILE:-}" ]; then
        typed_file_ok "$TYPED_JEV_KEY_FILE" \
          || die "TYPED_MODE=jev: TYPED_JEV_KEY_FILE does not name a readable, non-empty file. It must be the PATH of a file holding your Jev key, never the key itself. Nothing was installed."
      elif typed_file_ok "$STACK_DIR/typed/jev-key"; then
        note "typed answers (jev): using the key file an earlier run installed in $STACK_DIR/typed"
      else
        die "TYPED_MODE=jev needs TYPED_JEV_KEY_FILE=/path/to/a/file/holding/your/Jev/key (a file, not the key itself). Nothing was installed."
      fi
      ;;
    own-model)
      TYPED_URL="${TYPED_MODEL_URL:-}"
      [ -n "$TYPED_URL" ] || TYPED_URL="$(typed_env_get TYPRYX_OPENAI_URL)"
      TYPED_NAME="${TYPED_MODEL_NAME:-}"
      [ -n "$TYPED_NAME" ] || TYPED_NAME="$(typed_env_get TYPRYX_OPENAI_MODEL)"
      [ -n "$TYPED_URL" ] \
        || die "TYPED_MODE=own-model needs TYPED_MODEL_URL, the base URL of an OpenAI-compatible server ending in /v1 (http://host.docker.internal:11434/v1 for an Ollama on this box). Nothing was installed."
      typed_url_ok "$TYPED_URL" \
        || die "TYPED_MODEL_URL must be an http or https URL with a host, no credentials, and ending in /v1 (an OpenAI-compatible base URL). Nothing was installed."
      [ -n "$TYPED_NAME" ] \
        || die "TYPED_MODE=own-model needs TYPED_MODEL_NAME, the model the server should run (qwen2.5:7b for an Ollama). Nothing was installed."
      case "$TYPED_NAME" in
        *[[:space:]]*) die "TYPED_MODEL_NAME must not contain whitespace. Nothing was installed." ;;
      esac
      if [ -n "${TYPED_MODEL_KEY_FILE:-}" ]; then
        typed_file_ok "$TYPED_MODEL_KEY_FILE" \
          || die "TYPED_MODEL_KEY_FILE does not name a readable, non-empty file. It must be the PATH of a file holding the server's key, never the key itself. Nothing was installed."
      fi
      # A model on a CPU answers in about two seconds (measured p50 2130 ms for
      # qwen2.5:7b on 8 vCPUs) and typryx's own default bound is 2000 ms, so
      # left alone most answers would be refused as timed out. Kept if an
      # earlier run or the operator already set one.
      TYPED_TIMEOUT="${TYPED_MODEL_TIMEOUT_MS:-}"
      [ -n "$TYPED_TIMEOUT" ] || TYPED_TIMEOUT="$(typed_env_get TYPRYX_TIMEOUT_MS)"
      [ -n "$TYPED_TIMEOUT" ] || TYPED_TIMEOUT=30000
      case "$TYPED_TIMEOUT" in
        *[!0-9]*) die "TYPED_MODEL_TIMEOUT_MS must be a whole number of milliseconds. Nothing was installed." ;;
      esac
      ;;
  esac
  if [ "$mode" != jev ] && [ -n "${TYPED_JEV_KEY_FILE:-}" ]; then
    note "TYPED_JEV_KEY_FILE is ignored: TYPED_MODE is not jev"
  fi
  if [ "$mode" != own-model ] && [ -n "${TYPED_MODEL_URL:-}${TYPED_MODEL_NAME:-}${TYPED_MODEL_KEY_FILE:-}" ]; then
    note "TYPED_MODEL_* is ignored: TYPED_MODE is not own-model"
  fi
  TYPED_PLANE="$mode"
}

# Write the decision where compose reads it. Called once .env exists. Touches
# nothing when this run chose nothing: a re-run never changes a box (invariant 2).
typed_apply() {
  case "$TYPED_PLANE" in
    off)
      [ "$TYPED_EXPLICIT" = 0 ] || typed_set_env TYPED_MODE off
      ;;
    stub)
      # A box whose mode this block has managed goes back to compose's own
      # default, the stub. A box it never managed keeps what its operator
      # wrote in .env, which is what WITH_TYPED=1 has always done. The stub is
      # recorded as TYPED_MODE=stub, so a plain re-run keeps it (invariant 18);
      # a box that already records it is left as it is.
      if [ "$TYPED_SAVED_MODE" != stub ]; then
        [ -z "$TYPED_SAVED_MODE" ] || typed_forget_env "${TYPED_OWNED[@]}"
        typed_set_env TYPED_MODE stub
      fi
      mkdir -p "$STACK_DIR/typed" || die "could not create $STACK_DIR/typed"
      ;;
    jev)
      mkdir -p "$STACK_DIR/typed" || die "could not create $STACK_DIR/typed"
      if [ "$TYPED_EXPLICIT" = 1 ]; then
        typed_forget_env "${TYPED_OWNED[@]}"
        typed_set_env TYPED_MODE jev
        typed_set_env TYPRYX_BACKEND jev
        typed_set_env TYPRYX_JEV_KEY_FILE /run/typed/jev-key
        [ -z "${TYPED_JEV_KEY_FILE:-}" ] || typed_install_key "$TYPED_JEV_KEY_FILE" jev-key
        note "typed answers: jev. The named fields of each question leave this box for TypeSafe's API"
      fi
      ;;
    own-model)
      mkdir -p "$STACK_DIR/typed" || die "could not create $STACK_DIR/typed"
      if [ "$TYPED_EXPLICIT" = 1 ]; then
        typed_forget_env "${TYPED_OWNED[@]}"
        typed_set_env TYPED_MODE own-model
        typed_set_env TYPRYX_BACKEND openai-logprobs
        typed_set_env TYPRYX_OPENAI_URL "$TYPED_URL"
        typed_set_env TYPRYX_OPENAI_MODEL "$TYPED_NAME"
        [ -z "$TYPED_TIMEOUT" ] || typed_set_env TYPRYX_TIMEOUT_MS "$TYPED_TIMEOUT"
        if [ -n "${TYPED_MODEL_KEY_FILE:-}" ]; then
          typed_install_key "$TYPED_MODEL_KEY_FILE" model-key
          typed_set_env TYPRYX_OPENAI_KEY_FILE /run/typed/model-key
        fi
        note "typed answers: own-model. Questions go to $TYPED_URL and nowhere else"
      fi
      ;;
  esac
  # The training log, apart from the mode: it is the operator's own record and
  # survives a change of mode. The path is inside the typryxdata volume, beside
  # the ledger (compose.yaml sets TYPRYX_LEDGER_DIR there) that holds the human
  # truths `typryx export --training` pairs the log with.
  case "$TYPED_TRAIN" in
    1)
      typed_set_env TYPRYX_TRAINING_DIR /var/lib/typryx/training
      note "typed answers: the local training log is ON (volume typryxdata, never leaves this box). Export it with the command in the README"
      ;;
    0) typed_forget_env TYPRYX_TRAINING_DIR ;;
  esac
  # The risk signal, apart from the mode like the log above. On: the flag and
  # the two values compose reads for the MCP broker's policy client. The URL is
  # the proxy, never wardryx itself; the LLM gateway keeps its own direct URL.
  case "$TYPED_RISK" in
    1)
      typed_set_env TYPED_RISK_SIGNAL 1
      typed_set_env TYPED_RISK_WARDRYX_MODE enforce
      typed_set_env TYPED_RISK_WARDRYX_URL http://typryx-wardryx-proxy:4330
      note "typed risk signal: ON. The MCP broker now asks wardryx about every tool call through typryx's proxy, enforces what wardryx decides, and needs x-fuse-agent-id on each call"
      case "$TYPED_PLANE" in
        stub) note "  the backend is the stub: its answer is a fixed pick, not a classification, so this only shows the wiring" ;;
        jev)  note "  the backend is Jev: every tool call through the broker is one metered ask at TypeSafe, capped per hour by typryx" ;;
      esac
      note "  nothing seeds a hold_if_signal policy: until you write one, the signal changes no decision (README has an example)"
      ;;
    0) typed_forget_env "${TYPED_RISK_OWNED[@]}" ;;
  esac
}
# typed-mode: end
typed_resolve

# ---- 0c. the run-budget ceiling --------------------------------------------
# tokenfuse 1.5.0 (invariant 73) can clamp the budget a caller declares for a
# run. A run's budget used to be whatever the agent said in x-fuse-budget-usd,
# and the next call of an open run could widen it, so on a box with no client
# keys and no identity map the per-run ceiling was the agent's own word. The
# gateway reads TOKENFUSE_MAX_RUN_BUDGET_USD; compose.yaml sets it from
# RUN_BUDGET_CEILING_USD with a default of 5.00, which is tokenfuse's own
# default run budget, so an ordinary run is unchanged and only a caller-declared
# larger budget is clamped. A budget set in the Cloud is never clamped.
#
# One variable moves it: RUN_BUDGET_CEILING_USD, a positive number of dollars
# with at most six decimals, the one form tokenfuse reads (it exits 2 on
# anything else, and a gateway that exits at start is a stack that does not
# come up). So the value is checked HERE, before a package is installed or a
# file written, whether it came from this run's environment or was left in
# .env by a hand edit; a refusal never echoes what it was given. Nothing set
# writes nothing: a default box carries no line and compose supplies 5.00. A
# run that sets it replaces the .env line. (gate: scripts/run-budget-ceiling.sh
# lifts this block out and runs it.)
# run-budget-ceiling: begin
CEILING_SET=""   # what this run puts in .env, "" when it says nothing

ceiling_valid() { # VALUE: digits, optionally a point and 1-6 digits, above zero
  local LC_ALL=C   # [0-9] means ASCII digits here, as it does to tokenfuse
  [[ "$1" =~ ^[0-9]{1,12}(\.[0-9]{1,6})?$ ]] && [[ "$1" =~ [1-9] ]]
}

ceiling_resolve() {
  local saved=""
  CEILING_SET="${RUN_BUDGET_CEILING_USD:-}"
  if [ -n "$CEILING_SET" ] && ! ceiling_valid "$CEILING_SET"; then
    die "RUN_BUDGET_CEILING_USD must be a positive number of US dollars with at most six decimals (5 or 2.50, never 0, a sign or an exponent): tokenfuse refuses to start on anything else. Nothing was installed."
  fi
  if [ -f "$STACK_DIR/.env" ]; then
    saved="$(sed -n "/^RUN_BUDGET_CEILING_USD=/{s///p;q;}" "$STACK_DIR/.env")"
    saved="${saved#\'}"
    saved="${saved%\'}"
  fi
  if [ -n "$saved" ] && ! ceiling_valid "$saved"; then
    die ".env holds a RUN_BUDGET_CEILING_USD that is not a positive number of dollars with at most six decimals, so the gateway would refuse to start. Fix or remove that line. Nothing was changed."
  fi
}

# Write the decision where compose reads it. Called once .env exists.
ceiling_apply() {
  local tmp
  [ -n "$CEILING_SET" ] || return 0
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^RUN_BUDGET_CEILING_USD=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf 'RUN_BUDGET_CEILING_USD=%s\n' "$CEILING_SET" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
  note "run-budget ceiling: $CEILING_SET USD per run (a caller-declared budget above it is clamped; a Cloud budget is not)"
}
# run-budget-ceiling: end
ceiling_resolve
[ "$(uname -m)" = "x86_64" ] || note "architecture $(uname -m): the images build from source, so this should work, but it is untested off x86_64."

# ---- 0d. the agent firewall's mode -----------------------------------------
# tokenfuse runs an agent firewall: taint tracking that judges what a run may do
# after it has read untrusted input. Its mode is TOKENFUSE_FIREWALL, one of
# enforce, shadow or off. This launcher runs it in enforce by default, from
# compose.yaml (`${TOKENFUSE_FIREWALL:-enforce}`), a decision made for every box
# (CLAUDE.md invariant 27). The one switch back is this variable.
#
# tokenfuse exits at start on any other value (crates/gateway/src/firewall.rs,
# from_env, since v1.11.1), so a misspelling stops the gateway rather than running
# it in shadow. The value is checked HERE, before a
# package is installed or a file written, whether it came from this run's
# environment or was left in .env; a refusal never echoes what it was given.
# Nothing set writes nothing: a default box carries no line and compose supplies
# enforce. A run that sets it replaces the .env line. (gate:
# scripts/firewall-is-enforce.sh lifts this block out and runs it.)
# firewall-mode: begin
FIREWALL_SET=""   # what this run puts in .env, "" when it says nothing

firewall_valid() { # VALUE: exactly one of the three modes tokenfuse reads
  case "$1" in
    off|shadow|enforce) return 0 ;;
    *) return 1 ;;
  esac
}

firewall_resolve() {
  local saved=""
  FIREWALL_SET="${TOKENFUSE_FIREWALL:-}"
  if [ -n "$FIREWALL_SET" ] && ! firewall_valid "$FIREWALL_SET"; then
    die "TOKENFUSE_FIREWALL must be enforce, shadow or off. tokenfuse refuses to start on any other value. Nothing was installed."
  fi
  if [ -f "$STACK_DIR/.env" ]; then
    saved="$(sed -n "/^TOKENFUSE_FIREWALL=/{s///p;q;}" "$STACK_DIR/.env")"
    saved="${saved#\'}"
    saved="${saved%\'}"
  fi
  if [ -n "$saved" ] && ! firewall_valid "$saved"; then
    die ".env holds a TOKENFUSE_FIREWALL that is not enforce, shadow or off, which tokenfuse refuses to start on. Fix or remove that line. Nothing was changed."
  fi
}

# Write the decision where compose reads it. Called once .env exists.
firewall_apply() {
  local tmp
  [ -n "$FIREWALL_SET" ] || return 0
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^TOKENFUSE_FIREWALL=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf 'TOKENFUSE_FIREWALL=%s\n' "$FIREWALL_SET" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
  note "agent firewall: $FIREWALL_SET (enforce is the default; shadow and off are the way back)"
}
# firewall-mode: end
firewall_resolve

# ---- 0e. personal data in prompts and tool arguments (PII) ------------------
# tokenfuse runs two PII scanners (email, card and phone numbers): TOKENFUSE_DLP_PII
# on the gateway and TOKENFUSE_MCP_DLP_PII on the MCP broker. This launcher runs
# both in shadow by default, from compose.yaml (`${TOKENFUSE_DLP_PII:-shadow}`), a
# decision made for every box (CLAUDE.md invariant 28). This one variable is the
# switch for both: off, mask or block.
#
# Shadow records and forwards: it adds a note to the response, and the prompt and
# the tool arguments go on unchanged. Mask rewrites them and block refuses the
# call. tokenfuse exits at start on any other value (defaults.rs,
# dlp_pii_mode_from, and main.rs for the broker, since v1.12.0), so a misspelling
# stops the gateway or the broker rather than switching detection off. The value is checked HERE, before a
# package is installed or a file written; a refusal never echoes what it was given.
# Nothing set writes nothing: a default box carries no line and compose supplies
# shadow. A run that sets it replaces the .env line. (gate:
# scripts/pii-is-shadow.sh lifts this block out and runs it.)
# pii-mode: begin
PII_SET=""   # what this run puts in .env, "" when it says nothing

pii_valid() { # VALUE: exactly one of the four modes tokenfuse reads
  case "$1" in
    off|shadow|mask|block) return 0 ;;
    *) return 1 ;;
  esac
}

pii_resolve() {
  local saved=""
  PII_SET="${TOKENFUSE_DLP_PII:-}"
  if [ -n "$PII_SET" ] && ! pii_valid "$PII_SET"; then
    die "TOKENFUSE_DLP_PII must be off, shadow, mask or block. tokenfuse refuses to start on any other value. Nothing was installed."
  fi
  if [ -f "$STACK_DIR/.env" ]; then
    saved="$(sed -n "/^TOKENFUSE_DLP_PII=/{s///p;q;}" "$STACK_DIR/.env")"
    saved="${saved#\'}"
    saved="${saved%\'}"
  fi
  if [ -n "$saved" ] && ! pii_valid "$saved"; then
    die ".env holds a TOKENFUSE_DLP_PII that is not off, shadow, mask or block, which tokenfuse refuses to start on. Fix or remove that line. Nothing was changed."
  fi
}

# Write the decision where compose reads it. Called once .env exists.
pii_apply() {
  local tmp
  [ -n "$PII_SET" ] || return 0
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^TOKENFUSE_DLP_PII=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf 'TOKENFUSE_DLP_PII=%s\n' "$PII_SET" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
  note "personal data (PII): $PII_SET (shadow is the default; off, mask and block are the other positions)"
}
# pii-mode: end
pii_resolve

# ---- 0f. client keys and the identity map ------------------------------------
# Who may call the gateway, which agent ids each caller may speak as, and which
# business unit its spend lands in (tokenfuse docs/20). On by default since
# 2026-10-17: compose refuses to start the gateway without client keys, and a box
# given no files gets keys this installer mints (the block after this one,
# CLAUDE.md invariant 35). The files below are how an operator brings their own.
#
# @decided 2026-10-13 (paraphrased): the installer takes the identity map and the
# client keys as FILES that a person or an onboarding agent prepares, keeps them
# across re-runs, checks them before anything restarts, mounts the map read only
# into the gateway, and says at the end which header an agent sends. CLAUDE.md
# invariant 29.
#
#   CLIENT_KEYS_FILE=/path/keys.txt       one secret:key_id per line, the line the
#                                         console's Onboard tab prints; blank lines
#                                         and # comments are ignored
#   IDENTITY_MAP_FILE=/path/identity.json tokenfuse's identity map, JSON: units[],
#                                         keys[] and prefixes[] (docs/20)
#
# The keys go into .env (0600) as GATEWAY_CLIENT_KEYS, single-quoted, and are never
# printed. The map is copied to ./identity/identity.json, 0444 like policy.yaml:
# it names units, owners, key ids and agent patterns, and holds no secret, so any
# uid the gateway runs as can read it through the bind mount, which keeps host
# ownership. Compose mounts ./identity read only at /etc/tokenfuse/identity.
#
# Checked twice, and neither check changes the running stack:
#   here, before a package is installed: each file is a readable regular file with
#     something in it and no NUL byte; each key line is secret:key_id, split on the
#     LAST colon as tokenfuse splits it, with a secret of 24 to 256 of
#     A-Z a-z 0-9 . _ ~ + / = @ : - and a key id of 1 to 128 of A-Z a-z 0-9 . _ -
#     (no comma, quote, dollar or space can reach .env or the spec), and no secret
#     given twice; the map starts with {. A value an earlier run left in .env is
#     held to the same grammar.
#   in section 3e, after the images are there and before anything restarts: the
#     gateway image this box runs reads the pair itself, in a throwaway container
#     with no network, as the uid it runs as, so its own parser is the judge, not a
#     copy of it here. Anything it refuses to start on is refused, and so are three
#     things it only warns about: a map that configures nothing (an empty file and
#     {} read as no map at all), a map key_id no client key carries, and a client
#     key the map does not bind (under strict=enforce, which this box runs, every
#     call with it is refused 403).
# Only then is anything written. A re-run that names neither file keeps both and
# checks them again; one that names a file replaces what it names, and a changed
# map restarts the gateway, which reads the map only at start. The map can be
# turned off by removing GATEWAY_IDENTITY_MAP from .env and running docker compose
# up -d tokenfuse-gateway; the keys cannot, the gateway requires them. (gate:
# scripts/identity-files-are-checked.sh lifts this block out and runs it.)
#
# The OpenAI door (section 0g) is a second gateway with a keys file and a map of its
# own, checked by this same block, run once for that door by name: identity_door
# main or identity_door openai says which gateway the functions act on, and every
# name below (the input variables, the .env lines, the directory, the service, the
# wire the check container serves) comes from it. One block for both doors, not a
# copy per door, because two copies of a security check drift apart.
# identity-files: begin
IDENTITY_MAP_PATH=/etc/tokenfuse/identity/identity.json  # where a gateway reads it, on either door
IDENTITY_KEYS_GIVEN=0    # 1 when this run named the door's keys file
IDENTITY_KEYS_NEW=""     # the spec this run's file gives, comma-joined; never printed
IDENTITY_MAP_SRC=""      # the absolute path of the map this run was given
IDENTITY_KEYS_COUNT=0    # client keys the gateway holds after this run (0 = off)
IDENTITY_MAP_ON=0        # 1 when the gateway reads an identity map after this run
IDENTITY_MAP_CHANGED=0   # 1 when this run installed a different map
IDENTITY_STAGE=""        # this run's staging directory, from identity_check to identity_apply
IDENTITY_DOOR=""         # the door the state above belongs to: main or openai

# NAME: which gateway the functions below act on. `main` is tokenfuse-gateway on
# 4100; `openai` is tokenfuse-gateway-openai, the OpenAI door on 4110 (CLAUDE.md
# invariant 32). The state above belongs to the door named last. The door it leaves
# keeps its own as IDENTITY_<door>_<field> (IDENTITY_openai_KEYS_COUNT), saved here
# and loaded back when that door is named again. printf -v and ${!name}, which bash
# 3.2 has, and no associative array or nameref, which it does not.
IDENTITY_FIELDS="KEYS_GIVEN KEYS_NEW MAP_SRC KEYS_COUNT MAP_ON MAP_CHANGED STAGE"
identity_door() {
  local f v
  if [ -n "$IDENTITY_DOOR" ]; then
    for f in $IDENTITY_FIELDS; do
      v="IDENTITY_$f"
      printf -v "IDENTITY_${IDENTITY_DOOR}_$f" '%s' "${!v}"
    done
  fi
  case "$1" in
    main)
      ID_KEYS_FILE_VAR=CLIENT_KEYS_FILE ID_MAP_FILE_VAR=IDENTITY_MAP_FILE
      ID_KEYS_ENV=GATEWAY_CLIENT_KEYS ID_MAP_ENV=GATEWAY_IDENTITY_MAP
      ID_DIR=identity ID_SERVICE=tokenfuse-gateway ID_LABEL="the gateway" ID_CHECK=""
      ID_WIRE=anthropic ID_ROUTE=/v1/messages ID_UPSTREAM=https://api.anthropic.com/v1/messages
      ;;
    openai)
      ID_KEYS_FILE_VAR=OPENAI_DOOR_CLIENT_KEYS_FILE ID_MAP_FILE_VAR=OPENAI_DOOR_IDENTITY_MAP_FILE
      ID_KEYS_ENV=OPENAI_DOOR_CLIENT_KEYS ID_MAP_ENV=OPENAI_DOOR_IDENTITY_MAP
      ID_DIR=identity-openai ID_SERVICE=tokenfuse-gateway-openai ID_LABEL="the OpenAI door" ID_CHECK=-openai
      # The door's own upstream, from section 0g: the gateway refuses the openai
      # wire with no upstream, so its check has to start with the one it will have.
      ID_WIRE=openai ID_ROUTE=/v1/chat/completions ID_UPSTREAM="${DOOR_UPSTREAM:-}"
      ;;
    *) die "internal: identity_door was given '$1', which is neither main nor openai" ;;
  esac
  IDENTITY_DOOR="$1"
  for f in $IDENTITY_FIELDS; do
    v="IDENTITY_${1}_$f"
    case "$f" in
      KEYS_NEW|MAP_SRC|STAGE) printf -v "IDENTITY_$f" '%s' "${!v:-}" ;;
      *) printf -v "IDENTITY_$f" '%s' "${!v:-0}" ;;
    esac
  done
}

identity_env_get() { # NAME: what .env holds for NAME, single quotes removed
  local v
  [ -f "$STACK_DIR/.env" ] || return 0
  v="$(sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env")"
  v="${v#\'}"
  v="${v%\'}"
  printf '%s' "$v"
}

identity_env_set() { # NAME VALUE: replace or add NAME in .env, single-quoted
  local tmp
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf "%s='%s'\n" "$1" "$2" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
}

# FILE MAXBYTES: prints why FILE cannot be read as an input, nothing when it can.
identity_file_why() {
  local f="$1" size
  if [ ! -e "$f" ]; then printf 'names nothing that exists'; return 0; fi
  if [ ! -f "$f" ]; then printf 'does not name a regular file'; return 0; fi
  if [ ! -r "$f" ]; then printf 'names a file this script cannot read'; return 0; fi
  size=$(( $(wc -c <"$f") ))
  if [ "$size" -gt "$2" ]; then printf 'names a file larger than %s bytes' "$2"; return 0; fi
  if [ "$(( $(tr -d '\000' <"$f" | wc -c) ))" != "$size" ]; then printf 'names a file holding a NUL byte'; return 0; fi
  if ! LC_ALL=C grep -q '[^[:space:]]' "$f"; then printf 'names an empty file'; return 0; fi
}

# ENTRY: prints why ENTRY is not a usable secret:key_id, nothing when it is. Never
# prints the entry: the secret is the one thing this block does not show.
identity_entry_why() {
  local LC_ALL=C secret key_id re_id='^[A-Za-z0-9._-]{1,128}$' re_chars='^[A-Za-z0-9._~+/=@:-]+$'
  case "$1" in
    *:*) ;;
    *) printf 'is not secret:key_id (it has no colon)'; return 0 ;;
  esac
  secret="${1%:*}"
  key_id="${1##*:}"
  if [[ ! "$key_id" =~ $re_id ]]; then
    printf 'has a key id (after its last colon) that is not 1 to 128 of A-Z a-z 0-9 . _ -'
  elif [ "${#secret}" -lt 24 ] || [ "${#secret}" -gt 256 ]; then
    printf 'has a secret that is not 24 to 256 characters long'
  elif [[ ! "$secret" =~ $re_chars ]]; then
    printf 'has a secret with a character outside A-Z a-z 0-9 . _ ~ + / = @ : -'
  fi
}

# Decide what this run was given, and refuse, naming what is wrong and never what
# a secret is, before anything has been touched.
identity_resolve() {
  local f why line secret n=0 count=0 spec="" seen=$'\n' kept first
  [ -n "$IDENTITY_DOOR" ] || die "internal: identity_resolve ran before identity_door named a door"
  if [ -n "${!ID_KEYS_FILE_VAR:-}" ]; then
    f="${!ID_KEYS_FILE_VAR}"
    why="$(identity_file_why "$f" 262144)"
    [ -z "$why" ] || die "$ID_KEYS_FILE_VAR $why. It must name a file of secret:key_id lines (README, \"Client keys and the identity map\"). Nothing was installed."
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in ""|"#"*) continue ;; esac
      why="$(identity_entry_why "$line")"
      [ -z "$why" ] || die "$ID_KEYS_FILE_VAR: line $n $why. Each line is secret:key_id. Nothing was installed."
      secret="${line%:*}"
      case "$seen" in
        *$'\n'"$secret"$'\n'*) die "$ID_KEYS_FILE_VAR: line $n gives a secret an earlier line already gave, and $ID_LABEL would keep only one of the two. Nothing was installed." ;;
      esac
      seen="$seen$secret"$'\n'
      spec="${spec:+$spec,}$line"
      count=$((count + 1))
    done <"$f"
    [ "$count" -gt 0 ] || die "$ID_KEYS_FILE_VAR names no key: every line in it is blank or a comment. Nothing was installed."
    [ "${#spec}" -le 65536 ] || die "$ID_KEYS_FILE_VAR gives more keys than fit in one environment value (65536 bytes). Nothing was installed."
    IDENTITY_KEYS_NEW="$spec"
    IDENTITY_KEYS_GIVEN=1
  else
    kept="$(identity_env_get "$ID_KEYS_ENV")"
    if [ -n "$kept" ]; then
      while IFS= read -r -d ',' line; do
        n=$((n + 1))
        why="$(identity_entry_why "$line")"
        [ -z "$why" ] || die ".env holds a $ID_KEYS_ENV whose entry $n $why. Give $ID_KEYS_FILE_VAR again, or remove that line. Nothing was changed."
      done <<<"$kept,"
    fi
  fi

  if [ -n "${!ID_MAP_FILE_VAR:-}" ]; then
    f="${!ID_MAP_FILE_VAR}"
    why="$(identity_file_why "$f" 1048576)"
    [ -z "$why" ] || die "$ID_MAP_FILE_VAR $why. It must name tokenfuse's identity map, a JSON file (README, \"Client keys and the identity map\"). Nothing was installed."
    first="$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/^\(.\).*/\1/p;q;}' "$f")"
    [ "$first" = "{" ] || die "$ID_MAP_FILE_VAR is not a JSON object: an identity map starts with {. Nothing was installed."
    IDENTITY_MAP_SRC="$(readlink -f -- "$f")" || die "could not resolve the path $ID_MAP_FILE_VAR names. Nothing was installed."
  else
    kept="$(identity_env_get "$ID_MAP_ENV")"
    if [ -n "$kept" ]; then
      [ "$kept" = "$IDENTITY_MAP_PATH" ] \
        || die ".env holds a $ID_MAP_ENV other than $IDENTITY_MAP_PATH, the one place this installer keeps the map. Fix or remove that line. Nothing was changed."
      [ -s "$STACK_DIR/$ID_DIR/identity.json" ] \
        || die ".env names an identity map and $STACK_DIR/$ID_DIR/identity.json is missing or empty, so $ID_LABEL would refuse to start. Give $ID_MAP_FILE_VAR again, or remove $ID_MAP_ENV from .env. Nothing was changed."
    fi
  fi
}

# IMAGE: the gateway image this box runs reads the pair this run will leave, the
# new file where one was given and the kept one where not, and the answer is read
# from what it prints. Called once the image is on the box and before anything
# restarts. Writes nothing outside the staging directory, which identity_apply
# moves into place or removes.
identity_check() {
  local img="$1" spec map="" stage name
  local logs="" status="" left=40 orphans unbound
  [ -n "$IDENTITY_DOOR" ] || die "internal: identity_check ran before identity_door named a door"
  # One name per STACK_DIR and door: a run cut short leaves its container behind,
  # and the next run on the same box removes it by this name before starting its
  # own. The gateway's has no door in it, the name it had before the OpenAI door.
  name="agent-stack-identity-check$ID_CHECK-$(printf '%s' "$STACK_DIR" | cksum | cut -d' ' -f1)"
  spec="$IDENTITY_KEYS_NEW"
  [ "$IDENTITY_KEYS_GIVEN" = 1 ] || spec="$(identity_env_get "$ID_KEYS_ENV")"
  if [ -n "$IDENTITY_MAP_SRC" ]; then
    map="$IDENTITY_MAP_SRC"
  elif [ -n "$(identity_env_get "$ID_MAP_ENV")" ]; then
    map="$STACK_DIR/$ID_DIR/identity.json"
  fi
  # What a run cut short left behind, for this door only (identity.check.* and
  # identity-openai.check.* do not match each other).
  rm -rf -- "${STACK_DIR:?}/$ID_DIR".check.*
  IDENTITY_STAGE=""
  IDENTITY_KEYS_COUNT=0
  IDENTITY_MAP_ON=0
  [ -n "$spec$map" ] || return 0
  [ -n "$img" ] || die "could not tell which gateway image this box runs for $ID_LABEL, so its identity files cannot be checked. Nothing was changed."
  [ -n "$ID_UPSTREAM" ] || die "internal: $ID_LABEL has no upstream to start its check with"

  # A new directory every run, never a path an earlier run removed: Docker
  # Desktop's file sharing has shown a container a re-created path as it was
  # before, an empty directory, and the gateway then reported the map missing
  # (measured 2026-10-13 on macOS; a Linux bind mount reads the path at start).
  stage="$(mktemp -d "${STACK_DIR:?}/$ID_DIR.check.XXXXXX")" || die "could not create a staging directory in $STACK_DIR"
  IDENTITY_STAGE="$stage"
  chmod 0755 "$stage" || die "could not set the mode of $stage"
  if [ -n "$map" ]; then
    cat "$map" >"$stage/identity.json" || die "could not stage the identity map"
    chmod 0444 "$stage/identity.json" || die "could not set the mode of the identity map"
  fi

  docker rm -f "$name" >/dev/null 2>&1 || true
  # The keys travel in this command's environment and `-e NAME` with no value,
  # never on a command line. The command is compose's own for the gateway: the
  # published image's ENTRYPOINT is the binary already, and the image
  # BUILD_FROM_SOURCE builds has none, so with no command it would not start
  # (measured 2026-10-13 with the entrypoint emptied: docker refused, no command).
  # The wire and the upstream are the door's own: the gateway refuses the openai
  # wire with no upstream, and with no network the upstream is never dialled.
  TOKENFUSE_CLIENT_KEYS="$spec" docker run -d --name "$name" --network none \
      -e "TOKENFUSE_WIRE=$ID_WIRE" \
      -e "TOKENFUSE_UPSTREAM=$ID_UPSTREAM" \
      -e TOKENFUSE_CLIENT_KEYS \
      -e "TOKENFUSE_IDENTITY_MAP=${map:+$IDENTITY_MAP_PATH}" \
      -v "$stage:/etc/tokenfuse/identity:ro" \
      "$img" /usr/local/bin/tokenfuse >/dev/null \
    || die "could not start $img to check the identity files of $ID_LABEL. Nothing was changed."
  while [ "$left" -gt 0 ]; do
    logs="$(docker logs "$name" 2>&1)"
    case "$logs" in *"tokenfuse gateway listening"*) break ;; esac
    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    [ "$status" = running ] || [ "$status" = created ] || break
    sleep 0.5
    left=$((left - 1))
  done
  logs="$(docker logs "$name" 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1 || true

  case "$logs" in
    *"tokenfuse gateway listening"*) ;;
    *)
      rm -rf -- "$stage"
      printf '%s\n' "$logs" | grep '^tokenfuse: ' | sed 's/^/   /' >&2 || true
      die "the gateway image ($img) would not start as $ID_LABEL with these identity files (its own words are above). Nothing was changed, and the running stack is as it was."
      ;;
  esac
  # The wire it served, from its own start-up line: a check that started on the
  # other wire read the files as a different gateway than the one that will.
  grep -q "serving one door.*$ID_ROUTE" <<<"$logs" || {
    rm -rf -- "$stage"
    die "the check of $ID_LABEL's identity files did not serve its wire ($ID_ROUTE), so it did not read them as $ID_LABEL will. Nothing was changed."
  }
  if [ -n "$spec" ]; then
    IDENTITY_KEYS_COUNT=$(( $(printf '%s' "$spec" | tr -cd ',' | wc -c) + 1 ))
    grep -qF "client auth: ON ($IDENTITY_KEYS_COUNT key(s))" <<<"$logs" || {
      rm -rf -- "$stage"
      die "$ID_LABEL did not take all $IDENTITY_KEYS_COUNT client key(s) it was given. Nothing was changed."
    }
  fi
  if [ -n "$map" ]; then
    grep -qF 'identity map: ON (' <<<"$logs" || {
      rm -rf -- "$stage"
      die "the identity map of $ID_LABEL configures nothing: no unit, no key binding, no prefix. An empty file and {} read as no map at all, and it would run with the map off. Nothing was changed."
    }
    IDENTITY_MAP_ON=1
  fi
  # The backticks are the gateway's own quoting around a key id, matched as text.
  # shellcheck disable=SC2016
  orphans="$(sed -n 's/^tokenfuse: identity map key_id `\([^`]*\)` has no matching TOKENFUSE_CLIENT_KEYS entry.*/\1/p' <<<"$logs" | sort -u | tr '\n' ' ')"
  if [ -n "$orphans" ]; then
    rm -rf -- "$stage"
    die "the identity map of $ID_LABEL binds key id(s) ${orphans}that no client key carries, so its bindings could never match a call. Give a secret:key_id line for each in $ID_KEYS_FILE_VAR, or drop the binding. Nothing was changed."
  fi
  # shellcheck disable=SC2016  # the gateway's backticks again, matched as text
  unbound="$(sed -n 's/^tokenfuse: client key `\([^`]*\)` has no keys\[\] binding.*/\1/p' <<<"$logs" | sort -u | tr '\n' ' ')"
  if [ -n "$unbound" ]; then
    rm -rf -- "$stage"
    die "client key id(s) ${unbound}have no keys[] binding in the identity map of $ID_LABEL, and under strict=enforce, which this box runs, every call with them is refused 403. Bind each in the map, or drop it from the keys file. Nothing was changed."
  fi
}

# Write what identity_check passed. Touches nothing that this run was not given:
# a re-run that names no file leaves .env and the map exactly as they were.
identity_apply() {
  local stage="$IDENTITY_STAGE"
  [ -n "$IDENTITY_DOOR" ] || die "internal: identity_apply ran before identity_door named a door"
  mkdir -p "$STACK_DIR/$ID_DIR" || die "could not create $STACK_DIR/$ID_DIR"
  chmod 0755 "$STACK_DIR/$ID_DIR" || die "could not set the mode of $STACK_DIR/$ID_DIR"
  if [ "$IDENTITY_KEYS_GIVEN" = 1 ]; then
    # The same keys again (a re-run of a minted box gives them on every run) leave
    # the line where it is: a re-run changes nothing it does not have to.
    [ "$(identity_env_get "$ID_KEYS_ENV")" = "$IDENTITY_KEYS_NEW" ] || identity_env_set "$ID_KEYS_ENV" "$IDENTITY_KEYS_NEW"
    note "client keys ($ID_LABEL): $IDENTITY_KEYS_COUNT key(s), kept in .env as $ID_KEYS_ENV (never printed)"
  fi
  if [ -n "$IDENTITY_MAP_SRC" ]; then
    if cmp -s "$stage/identity.json" "$STACK_DIR/$ID_DIR/identity.json"; then
      note "identity map ($ID_LABEL): the same as the one already installed, left as is"
    else
      mv -f "$stage/identity.json" "$STACK_DIR/$ID_DIR/identity.json" \
        || die "could not put the identity map in place"
      IDENTITY_MAP_CHANGED=1
      note "identity map ($ID_LABEL): installed at $STACK_DIR/$ID_DIR/identity.json (read only for $ID_SERVICE)"
    fi
    [ "$(identity_env_get "$ID_MAP_ENV")" = "$IDENTITY_MAP_PATH" ] \
      || identity_env_set "$ID_MAP_ENV" "$IDENTITY_MAP_PATH"
  fi
  [ -z "$stage" ] || rm -rf -- "$stage"
  IDENTITY_STAGE=""
}

# What the end of the run says about Felyx, the console's copilot, which calls
# this gateway like any agent does. With client keys on it needs a key, and
# whether it has one depends on GENARYX_COPILOT_FUSE_KEY in .env (compose hands
# it to a console from v1.1.44 on as GENARYX_COPILOT_FUSE_KEY_REF, CLAUDE.md
# invariant 16): set, Felyx presents it as x-fuse-key; empty, the default, it
# sends none and the gateway refuses it 401. The note used to say "sends no
# x-fuse-key" whatever the box held (found 2026-10-13 on a box that had given
# Felyx a key). Says nothing when client keys are off or Felyx has no provider
# key, since then it makes no call that could be refused. On a box whose keys the
# installer minted (the block below), Felyx's key is one of them and is bound, so
# the note says so and asks nothing of the operator. Prints no key value.
# (gate: scripts/felyx-through-the-gateway.sh lifts this and runs it.)
felyx_gateway_note() {
  [ "$IDENTITY_KEYS_COUNT" -gt 0 ] || return 0
  if [ "${IDENTITY_MINTED:-0}" = 1 ]; then
    printf '\n  Felyx, the console'"'"'s copilot, calls this gateway too, with the key this\n'
    printf '  installer minted for it (GENARYX_COPILOT_FUSE_KEY in .env, sent as x-fuse-key and\n'
    printf '  not printed here), bound in the identity map to its own agent id and no other.'
  elif [ -n "${GENARYX_COPILOT_FUSE_KEY:-}" ]; then
    printf '\n  Felyx, the console'"'"'s copilot, calls this gateway too. GENARYX_COPILOT_FUSE_KEY is\n'
    printf '  set, so a console from v1.1.44 on sends that key as x-fuse-key (an older one\n'
    printf '  ignores the setting and sends none). The key has to be one of the secrets in\n'
    printf '  your keys file, and with an identity map its key id needs a keys[] binding\n'
    printf '  whose agents include Felyx'"'"'s agent id, or the gateway refuses its calls\n'
    printf '  (README, "Client keys and the identity map").'
  else
    printf '\n  Felyx, the console'"'"'s copilot, calls this gateway and, with GENARYX_COPILOT_FUSE_KEY\n'
    printf '  empty (the default), sends no x-fuse-key, so while client keys are on its calls\n'
    printf '  are refused 401. To give it a key of its own, add a line for it to the keys\n'
    printf '  file, bind its key id in the identity map if you use one, and put the same\n'
    printf '  secret in %s/.env as GENARYX_COPILOT_FUSE_KEY (README, "Client keys and the\n' "$STACK_DIR"
    printf '  identity map").'
  fi
}
# identity-files: end

# ---- 0f, continued: keys for a box that was given none ---------------------------
# @decided 2026-10-17 (paraphrased): close the agent-security findings of the
# 2026-10-17 review, defaults first. The gateway never answers an unnamed caller:
# compose refuses to start it without GATEWAY_CLIENT_KEYS, and a box given no keys
# file gets keys this installer mints itself (CLAUDE.md invariant 35):
#
#   felyx   the console's copilot, bound to exactly agent://<td>/genaryx/felyx; its
#           secret is GENARYX_COPILOT_FUSE_KEY in .env, which the console sends
#   agents  the operator's own agents, bound to agent://<td>/agents/*; its secret is
#           GATEWAY_AGENT_KEY in .env and the file $STACK_DIR/agent-key (0600), whose
#           PATH the end of the run prints, never the key
#
# <td> is RECORD_TRUST_DOMAIN (from .env, else this run's environment, else local),
# the domain compose already names Felyx in. The agents' pattern stops short of
# Felyx's id, so an agent cannot speak as the copilot. The map has a unit each and no
# budget: it binds and attributes, and a budget is the operator's decision. A secret
# already in .env is never rewritten; an absent or empty one is minted with gen. The
# spec and the map are rebuilt from .env on every run, the same bytes each time, so a
# re-run restarts nothing, and they go through section 3e exactly like an operator's
# files: the gateway image reads them before anything restarts.
# GATEWAY_IDENTITY_MINTED=1 in .env says the installer owns them. An operator's own
# files replace them, both files together, because the minted map binds the minted
# key ids and nothing else. (gate: scripts/metered-doors-require-keys.sh lifts this
# block out and runs it.)
# identity-mint: begin
MINT_ON=0              # 1 when this run's client keys and map are the installer's own
MINT_DOMAIN=""         # the trust domain the minted map names
MINT_MAP=""            # the map composed for section 3e, removed once it is installed
IDENTITY_MINTED=0      # 1 when the gateway runs minted keys after this run

mint_env_forget() { # NAME: drop NAME's line from .env
  local tmp
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
}

# Section 0f, after identity_resolve and before anything is installed: whether this
# run mints, refusing a pair that cannot work. Writes nothing.
mint_resolve() {
  local LC_ALL=C marker keys map td
  [ "$IDENTITY_DOOR" = main ] || die "internal: mint_resolve ran with the ${IDENTITY_DOOR:-no} door selected"
  marker="$(identity_env_get GATEWAY_IDENTITY_MINTED)"
  keys="$(identity_env_get GATEWAY_CLIENT_KEYS)"
  map="$(identity_env_get GATEWAY_IDENTITY_MAP)"
  case "$marker" in
    ""|1) ;;
    *) die ".env holds a GATEWAY_IDENTITY_MINTED other than 1. Fix or remove that line. Nothing was changed." ;;
  esac
  MINT_ON=0
  if [ "$marker" = 1 ]; then
    if [ -n "${CLIENT_KEYS_FILE:-}" ] && [ -z "${IDENTITY_MAP_FILE:-}" ]; then
      die "this box's client keys were minted by the installer, and the map it wrote binds those keys only. Give IDENTITY_MAP_FILE with CLIENT_KEYS_FILE, a map that binds your keys. Nothing was installed."
    fi
    if [ -z "${CLIENT_KEYS_FILE:-}" ] && [ -n "${IDENTITY_MAP_FILE:-}" ]; then
      die "this box's client keys were minted by the installer, and your map would not bind them. Give CLIENT_KEYS_FILE with IDENTITY_MAP_FILE. Nothing was installed."
    fi
    [ -n "${CLIENT_KEYS_FILE:-}" ] || MINT_ON=1
  elif [ -n "${CLIENT_KEYS_FILE:-}" ] || [ -n "$keys" ]; then
    MINT_ON=0
  elif [ -n "${IDENTITY_MAP_FILE:-}" ]; then
    die "IDENTITY_MAP_FILE needs CLIENT_KEYS_FILE: the gateway requires client keys, and a map's bindings name keys this box does not have. Give both, or neither and the installer mints keys and a map. Nothing was installed."
  elif [ -n "$map" ]; then
    die ".env names an identity map (GATEWAY_IDENTITY_MAP) and holds no client keys, and the gateway now requires them. Give CLIENT_KEYS_FILE with IDENTITY_MAP_FILE, or remove GATEWAY_IDENTITY_MAP from .env and the installer mints keys and a map. Nothing was changed."
  else
    MINT_ON=1
  fi
  [ "$MINT_ON" = 1 ] || return 0
  td="$(identity_env_get RECORD_TRUST_DOMAIN)"
  [ -n "$td" ] || td="${RECORD_TRUST_DOMAIN:-local}"
  [[ "$td" =~ ^[A-Za-z0-9.-]{1,253}$ ]] \
    || die "RECORD_TRUST_DOMAIN must be a name of A-Z a-z 0-9 . and -: the keys this installer mints are bound to agent ids in it. Nothing was installed."
  [ "$td" != mockryx.local ] \
    || die "RECORD_TRUST_DOMAIN is mockryx.local, the domain the fire drills' key is bound to, so an agent of this box could speak as a drill. Give another name. Nothing was installed."
  MINT_DOMAIN="$td"
}

# NAME: a secret in .env under NAME, minted when the line is absent or empty. A value
# already there is kept byte for byte: an agent holding it keeps working.
mint_env_secret() {
  [ -z "$(identity_env_get "$1")" ] || return 0
  identity_env_set "$1" "$(gen 40)"
  note "minted $1 into .env (never printed)"
}

# Section 3, once .env exists: the secrets, the spec and the map, handed to section
# 3e as if they were the operator's files.
mint_prepare() {
  local felyx agents drills broker why seen s
  [ "$MINT_ON" = 1 ] || return 0
  mint_env_secret GENARYX_COPILOT_FUSE_KEY
  mint_env_secret GATEWAY_AGENT_KEY
  mint_env_secret GATEWAY_DRILLS_KEY
  felyx="$(identity_env_get GENARYX_COPILOT_FUSE_KEY)"
  agents="$(identity_env_get GATEWAY_AGENT_KEY)"
  drills="$(identity_env_get GATEWAY_DRILLS_KEY)"
  why="$(identity_entry_why "$felyx:felyx")"
  [ -z "$why" ] || die "GENARYX_COPILOT_FUSE_KEY in .env, Felyx's client key, $why. Empty that line and the installer mints one. Nothing was started."
  why="$(identity_entry_why "$agents:agents")"
  [ -z "$why" ] || die "GATEWAY_AGENT_KEY in .env, the agents' client key, $why. Empty that line and the installer mints one. Nothing was started."
  why="$(identity_entry_why "$drills:drills")"
  [ -z "$why" ] || die "GATEWAY_DRILLS_KEY in .env, the fire drills' key, $why. Empty that line and the installer mints one. Nothing was started."
  # The broker's own key exists only with agent tokens on (agent_tokens_apply mints it).
  broker=""
  if [ "${AGENT_TOKENS_ON:-0}" = 1 ]; then broker="$(identity_env_get GATEWAY_BROKER_KEY)"; fi
  seen=""
  for s in "$felyx" "$agents" "$drills" ${broker:+"$broker"}; do
    case " $seen " in
      *" $s "*) die "two of GENARYX_COPILOT_FUSE_KEY, GATEWAY_AGENT_KEY and GATEWAY_DRILLS_KEY in .env hold the same secret, so one agent could speak as another. Empty one of those lines and the installer mints a new one. Nothing was started." ;;
    esac
    seen="$seen $s"
  done
  MINT_MAP="$(mktemp)" || die "could not make a temporary file for the minted identity map"
  {
    printf '{\n  "units": [\n    {"id": "console", "name": "Felyx, the console copilot"},\n    {"id": "agents", "name": "The operator agents"},\n    {"id": "drills", "name": "The fire drills"}'
    [ -z "$broker" ] || printf ',\n    {"id": "broker", "name": "The MCP broker, relaying tool-call checks"}'
    printf '\n  ],\n  "keys": [\n    {"key_id": "felyx", "unit": "console", "agents": ["agent://%s/genaryx/felyx"]},\n    {"key_id": "agents", "unit": "agents", "agents": ["agent://%s/agents/*"]},\n    {"key_id": "drills", "unit": "drills", "agents": ["agent://mockryx.local/*"]}' "$MINT_DOMAIN" "$MINT_DOMAIN"
    [ -z "$broker" ] || printf ',\n    {"key_id": "broker", "unit": "broker", "agents": ["agent://%s/agents/*"]}' "$MINT_DOMAIN"
    printf '\n  ]\n}\n'
  } >"$MINT_MAP" || die "could not write the minted identity map"
  IDENTITY_KEYS_NEW="$felyx:felyx,$agents:agents,$drills:drills${broker:+,$broker:broker}"
  IDENTITY_KEYS_GIVEN=1
  IDENTITY_MAP_SRC="$MINT_MAP"
}

# Section 3e, after identity_apply wrote the spec and installed the map: the agents'
# key in its own file for the operator, and the marker. On a box the operator took
# over, the marker goes and the file is left where it is.
mint_apply() {
  local f="$STACK_DIR/agent-key" agents
  [ -z "$MINT_MAP" ] || rm -f "$MINT_MAP"
  MINT_MAP=""
  if [ "$MINT_ON" != 1 ]; then
    IDENTITY_MINTED=0
    if [ -n "$(identity_env_get GATEWAY_IDENTITY_MINTED)" ]; then
      mint_env_forget GATEWAY_IDENTITY_MINTED
      note "client keys: yours now, from the files you gave; the minted keys are no longer accepted ($f is left in place)"
    fi
    return 0
  fi
  agents="$(identity_env_get GATEWAY_AGENT_KEY)"
  [ -n "$agents" ] || die "internal: mint_apply found no GATEWAY_AGENT_KEY in .env"
  if [ ! -f "$f" ] || [ "$(cat "$f")" != "$agents" ]; then
    ( umask 077; printf '%s\n' "$agents" >"$f.tmp" ) || die "could not write the agents' key to $f"
    mv -f "$f.tmp" "$f" || die "could not put the agents' key in place at $f"
    note "the agents' client key: in $f (0600), never printed"
  fi
  chmod 0600 "$f" || die "could not set the mode of $f"
  [ "$(identity_env_get GATEWAY_IDENTITY_MINTED)" = 1 ] || identity_env_set GATEWAY_IDENTITY_MINTED 1
  IDENTITY_MINTED=1
}

# What the end of the run says about the minted keys: the file and the ids, never a
# secret. Says nothing on a box running the operator's own keys.
mint_reach_note() {
  [ "${IDENTITY_MINTED:-0}" = 1 ] || return 0
  printf '\n  Client keys are ON, minted by this installer because it was given no keys file.\n'
  printf '  Your agents now need a key: every call to the gateway carries\n\n'
  printf '      x-fuse-key       the secret in %s (it is not printed here)\n' "$STACK_DIR/agent-key"
  printf '      x-fuse-agent-id  an id under agent://%s/agents/, such as agent://%s/agents/support-bot\n' "$MINT_DOMAIN" "$MINT_DOMAIN"
  printf '      x-fuse-run-id    its run, as before\n\n'
  printf '  A call with no key, or one the gateway does not hold, is refused 401, and the key\n'
  printf '  speaking as an id outside agents/ is refused 403 identity_mismatch. To give each\n'
  printf '  agent its own key and unit, bring a keys file and an identity map, both together\n'
  printf '  (README, "Client keys and the identity map").'
}
# identity-mint: end

# ---- 0h. the provider key each door holds (CLAUDE.md invariant 39) ------------------
# @decided 2026-10-17 (paraphrased): the gateway holds the provider key, not the agent.
# A door reads its provider key from a file this installer writes, mode 0400 and owned
# by uid 10001 (the uid the gateway runs as), mounted read only into that door alone:
# ./upstream/anthropic for tokenfuse-gateway and ./upstream/openai for the OpenAI door
# (compose.yaml). The operator gives the key as a FILE, ANTHROPIC_KEY_FILE or
# OPENAI_KEY_FILE, the way the typed plane's key is given (section 0b): the path, never
# the bytes. A refusal never prints what it was given. A box that has
# GENARYX_COPILOT_KEY in .env, the provider key Felyx held before this release, has that
# value written to the file once; the .env line stays, unused, because removing a
# credential is the operator's decision. With no file the gateway forwards the caller's
# own key as before and says so at startup, and the closing report says it is not
# brokered. gate: scripts/no-provider-key-outside-the-gateway.sh.
# upstream-key: begin
UP_ANTHROPIC_SRC=""   # the file ANTHROPIC_KEY_FILE names, checked by upstream_resolve
UP_OPENAI_SRC=""      # the file OPENAI_KEY_FILE names, checked by upstream_resolve

upstream_why() { # FILE: why FILE cannot hold a provider key, nothing when it can. Never prints it.
  local LC_ALL=C f="$1" k
  [ -e "$f" ] || { printf 'does not exist'; return 0; }
  [ -f "$f" ] || { printf 'is not a regular file'; return 0; }
  [ -r "$f" ] || { printf 'is not readable'; return 0; }
  k="$(head -c 4097 "$f" 2>/dev/null)" || { printf 'could not be read'; return 0; }
  [ "${#k}" -le 4096 ] || { printf 'is over 4096 bytes'; return 0; }
  [ -n "$k" ] || { printf 'is empty'; return 0; }
  [[ "$k" != *[![:graph:]]* ]] || { printf 'holds a space or a control character, which a provider key does not'; return 0; }
}

# Section 0h, before anything is installed: refuses a file that cannot hold a key.
upstream_resolve() {
  local why
  if [ -n "${ANTHROPIC_KEY_FILE:-}" ]; then
    why="$(upstream_why "$ANTHROPIC_KEY_FILE")"
    [ -z "$why" ] || die "ANTHROPIC_KEY_FILE $why, so it cannot be the provider key the gateway holds. It names a file that holds the key, not the key itself. Nothing was installed."
    UP_ANTHROPIC_SRC="$ANTHROPIC_KEY_FILE"
  fi
  if [ -n "${OPENAI_KEY_FILE:-}" ]; then
    why="$(upstream_why "$OPENAI_KEY_FILE")"
    [ -z "$why" ] || die "OPENAI_KEY_FILE $why, so it cannot be the OpenAI door's provider key. It names a file that holds the key, not the key itself. Nothing was installed."
    UP_OPENAI_SRC="$OPENAI_KEY_FILE"
  fi
}

upstream_put() { # KEY DIR: DIR/key holds KEY, 0400, owned by uid 10001. Never prints KEY.
  local k="$1" dir="$2" tmp
  tmp="$dir/.key.tmp"
  ( umask 077; printf '%s' "$k" >"$tmp" ) || die "could not write the provider key into $dir"
  if ! { chown 10001:10001 "$tmp" && chmod 0400 "$tmp" && mv -f "$tmp" "$dir/key"; }; then
    die "could not put the provider key in place in $dir (mode 0400, uid 10001)"
  fi
}

# Section 3, once .env exists: the two directories every compose run mounts, the key
# files, and the .env lines that tell each door where its file is. The directories
# exist on every box so compose never creates one as root.
upstream_apply() {
  local k
  mkdir -p "$STACK_DIR/upstream/anthropic" "$STACK_DIR/upstream/openai" \
    || die "could not make the provider key directories under $STACK_DIR/upstream"
  chmod 0755 "$STACK_DIR/upstream" "$STACK_DIR/upstream/anthropic" "$STACK_DIR/upstream/openai" \
    || die "could not set the mode of the provider key directories"
  if [ -n "$UP_ANTHROPIC_SRC" ]; then
    k="$(head -c 4096 "$UP_ANTHROPIC_SRC")" || die "could not read ANTHROPIC_KEY_FILE"
    upstream_put "$k" "$STACK_DIR/upstream/anthropic"
    note "the Anthropic key: in $STACK_DIR/upstream/anthropic/key (0400, uid 10001, never printed)"
  elif [ ! -f "$STACK_DIR/upstream/anthropic/key" ] && [ -n "$(identity_env_get GENARYX_COPILOT_KEY)" ]; then
    k="$(identity_env_get GENARYX_COPILOT_KEY)"
    upstream_put "$k" "$STACK_DIR/upstream/anthropic"
    note "the Anthropic key Felyx held in .env (GENARYX_COPILOT_KEY) is now in $STACK_DIR/upstream/anthropic/key (0400, uid 10001, never printed); the .env line stays, unused, until you remove it"
  fi
  if [ -f "$STACK_DIR/upstream/anthropic/key" ]; then
    identity_env_set GATEWAY_UPSTREAM_KEY_FILE /run/upstream/key
  else
    mint_env_forget GATEWAY_UPSTREAM_KEY_FILE
  fi
  if [ -n "$UP_OPENAI_SRC" ]; then
    k="$(head -c 4096 "$UP_OPENAI_SRC")" || die "could not read OPENAI_KEY_FILE"
    upstream_put "$k" "$STACK_DIR/upstream/openai"
    note "the OpenAI door's key: in $STACK_DIR/upstream/openai/key (0400, uid 10001, never printed)"
  fi
  if [ -f "$STACK_DIR/upstream/openai/key" ]; then
    identity_env_set OPENAI_DOOR_UPSTREAM_KEY_FILE /run/upstream/key
  else
    mint_env_forget OPENAI_DOOR_UPSTREAM_KEY_FILE
  fi
}

# What the closing report says about the provider key. Says whether the gateway holds
# it and where the file is, never the key.
upstream_reach_note() {
  if [ -f "$STACK_DIR/upstream/anthropic/key" ]; then
    printf '\n  The gateway holds the Anthropic key itself, in %s/upstream/anthropic/key (0400,\n' "$STACK_DIR"
    printf '  uid 10001). An agent presents its gateway key and no provider key. A provider key\n'
    printf '  sent by a caller is refused 401 provider_credential_refused (CLAUDE.md invariant 39).'
  else
    printf '\n  The gateway holds no provider key: it forwards the caller'"'"'s own key, as before, and\n'
    printf '  says so at startup. Give ANTHROPIC_KEY_FILE to hold the key on the gateway (CLAUDE.md\n'
    printf '  invariant 39).'
  fi
}
# upstream-key: end

# ---- 3b-agent. agent tokens: vouchryx enrols one agent, the doors verify its token ----
# agent-tokens: begin
# @decided 2026-10-19 (paraphrased, decision D8): agent tokens are the default credential.
# An agent presents a short-lived, sender-constrained token of its own, and the two doors
# that take one (the gateway and the MCP broker) run require: a static client key is refused
# unless its key id is named on an allow-list. WITH_AGENT_TOKENS=0 is the explicit way out:
# the doors run off, static keys are admitted as before, and the closing report calls that
# weaker (CLAUDE.md invariant 47). On, vouchryx starts with the delegation plane (invariant
# 15's profile, but no trusted issuer is invented: the agent's own registry line is the
# trust), enrols ONE agent, the doors verify its token offline for their own audience against
# a revocation list that fails closed, and wardryx verifies the token itself (wardryx 2.3.0)
# rather than taking the door's word for who the agent is. A stopped agent is one vouchryx
# revocation.
#
# What this does NOT do, named here and in the report: vouchryx reads its registry from one
# environment variable, so this installer enrols one agent per box (the operator's,
# `agent://<td>/agents/operator`). The enrolment secret never reaches .env or a log: it lives
# in $STACK_DIR/agent-token.key (0600), and .env holds only its SHA-256 digest.
#
# The broker's own gateway client key (taint relay, tokenfuse invariant 123) is minted only
# on a box the installer gives keys to (MINT_ON): a box with its own keys file must add a
# `broker` line itself, so the installer never edits a file it did not write.
AGENT_TOKENS_ON=0        # 1 when this run turns agent tokens on (the default)
DELEGATION_ON=0          # 1 when vouchryx runs this run: WITH_DELEGATION or agent tokens
AGENT_TOKEN_AGENT=""     # the one agent enrolled: agent://<td>/agents/operator
EXISTING_GATEWAY_IDS=""  # the gateway client key ids this box had before this run
EXISTING_MCP_IDS=""      # the broker's client key ids this box had before this run
STATIC_KEY_IDS_LIST=""   # STATIC_KEY_IDS as validated words, set by agent_tokens_resolve
STATIC_GATEWAY_LIST=""   # what this run wrote to TOKENFUSE_AGENT_TOKENS_STATIC_KEYS
STATIC_MCP_LIST=""       # what this run wrote to TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS

# The key id of each secret:key_id entry in SPEC, one per line. A key id is the text after
# the LAST colon, as tokenfuse splits it. Nothing here echoes a secret.
client_key_ids() {
  local IFS=',' e
  for e in $1; do
    e="${e##*:}"
    [ -z "$e" ] || printf '%s\n' "$e"
  done
}

# Section 0, before anything is installed: refuses a value it does not read, and a pair
# it cannot honour. Writes nothing. Runs after mint_resolve, which decides MINT_ON.
agent_tokens_resolve() {
  local td id
  # The delegation plane runs for its own switch as well as for agent tokens.
  [ -z "${WITH_DELEGATION:-}" ] || DELEGATION_ON=1
  case "${WITH_AGENT_TOKENS:-}" in
    ""|1) ;;
    0) return 0 ;;
    *) die "WITH_AGENT_TOKENS must be unset or 1 (agent tokens on, the default) or 0 (off: static keys only, the weaker way out), not what it was given. Nothing was installed." ;;
  esac
  AGENT_TOKENS_ON=1
  DELEGATION_ON=1
  td="$(identity_env_get RECORD_TRUST_DOMAIN)"
  [ -n "$td" ] || td="${RECORD_TRUST_DOMAIN:-local}"
  if ! { [[ "$td" =~ ^[A-Za-z0-9.-]{1,253}$ ]] && [ "$td" != mockryx.local ]; }; then
    die "RECORD_TRUST_DOMAIN must be a name of A-Z a-z 0-9 . and - other than mockryx.local, because the agent's id is in it. Nothing was installed."
  fi
  AGENT_TOKEN_AGENT="agent://$td/agents/operator"
  # One audience for BOTH doors, an https identifier (tokenfuse 1.17.0 refuses an audience that is not an
  # absolute https URL, and one agent token must verify at the gateway and at the broker). Nothing serves
  # it, and it need not: it is a name the token is minted for.
  AGENT_AUDIENCE="https://stack-single.$td"
  # The key ids this box already has, read before this run writes anything. On a re-run every one of
  # them stays on the static allow-list, so nothing that worked yesterday stops working (invariant 47).
  EXISTING_GATEWAY_IDS="$(client_key_ids "$(identity_env_get GATEWAY_CLIENT_KEYS)" | tr '\n' ' ')"
  EXISTING_MCP_IDS="$(client_key_ids "$(identity_env_get TOKENFUSE_MCP_KEYS)" | tr '\n' ' ')"
  # The operator's own allow-list: STATIC_KEY_IDS, comma-separated key ids for clients that cannot sign
  # a proof. Each word is checked here, and a value that is not one is refused without being echoed.
  if [ -n "${STATIC_KEY_IDS:-}" ]; then
    local IFS=','
    for id in $STATIC_KEY_IDS; do
      [[ "$id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] \
        || die "STATIC_KEY_IDS holds an entry that is not a key id (A-Z a-z 0-9 . _ - , 1 to 128 characters, comma separated). Its value is not printed. Nothing was installed."
      STATIC_KEY_IDS_LIST="$STATIC_KEY_IDS_LIST $id"
    done
    unset IFS
  fi
  [ "$MINT_ON" = 1 ] \
    || die "agent tokens are on (the default) on a box given its own client keys: the MCP broker needs a key of its own, so give it a line 'broker:<secret>' in your keys file, bound in your identity map to agent://$td/agents/*. Or set WITH_AGENT_TOKENS=0 to keep static keys only (the weaker way out), or remove CLIENT_KEYS_FILE and IDENTITY_MAP_FILE and let the installer mint the keys. Nothing was installed."
}

# Section 3, after .env exists and before section 3e reads the keys: the enrolment secret into its
# file, the registry line and the settings the doors read, the settings that make wardryx verify the
# token itself, and the broker's own key into its file. With WITH_AGENT_TOKENS=0 the doors are written
# off and every line that turns the plane on is forgotten; the secrets it minted stay in their files.
agent_tokens_apply() {
  local f="$STACK_DIR/agent-token.key" secret digest broker why v
  # The broker's key directory exists on every box, so compose never creates it as root.
  mkdir -p "$STACK_DIR/broker" || die "could not make $STACK_DIR/broker for the broker's key"
  chmod 0755 "$STACK_DIR/broker" || die "could not set the mode of $STACK_DIR/broker"
  if [ "$AGENT_TOKENS_ON" != 1 ]; then
    if [ "${WITH_AGENT_TOKENS:-}" = 0 ]; then
      identity_env_set TOKENFUSE_AGENT_TOKENS off
      # tokenfuse 1.19.0 refuses a static-key list under any mode but require, so the lists go too.
      for v in VOUCHRYX_AGENTS VOUCHRYX_ALLOWED_AUDIENCES BROKER_TAINT_GATEWAY BROKER_GATEWAY_KEY_FILE \
          MCP_BROKER_DELEGATION_AUDIENCE MCP_BROKER_DELEGATION_URL \
          WARDRYX_AGENT_TOKEN_ISSUER WARDRYX_AGENT_TOKEN_AUDIENCES WARDRYX_AGENT_TOKEN_JWKS_URL \
          WARDRYX_AGENT_TOKEN_REVOCATION_URL WARDRYX_AGENT_TOKEN_DOOR_ORIGINS \
          TOKENFUSE_AGENT_TOKENS_STATIC_KEYS TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS; do
        mint_env_forget "$v"
      done
      note "agent tokens: OFF (WITH_AGENT_TOKENS=0). Static keys only, as before this release, which is the weaker setting; the closing report says so. The enrolment secret and the broker key stay in their files"
    fi
    return 0
  fi
  if [ ! -s "$f" ]; then
    ( umask 077; printf '%s' "$(gen 40)" >"$f.tmp" ) || die "could not write the enrolment secret to $f"
    mv -f "$f.tmp" "$f" || die "could not put the enrolment secret in place at $f"
    note "minted the agent's enrolment secret into $f (0600, never printed)"
  fi
  chmod 0600 "$f" || die "could not set the mode of $f"
  secret="$(cat "$f")"
  digest="$(printf '%s' "$secret" | openssl dgst -sha256 -hex | awk '{print $NF}')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the enrolment digest. Nothing was started."
  identity_env_set VOUCHRYX_AGENTS "$AGENT_TOKEN_AGENT|agents|local|sha256:$digest"
  # vouchryx reads each audience as an absolute URL (RFC 8707 resources), and the two doors name the
  # same https identifier, so one token verifies at both (CLAUDE.md invariant 40).
  identity_env_set VOUCHRYX_ALLOWED_AUDIENCES "$AGENT_AUDIENCE"
  identity_env_set TOKENFUSE_AGENT_TOKENS require
  identity_env_set TOKENFUSE_DELEGATION_ISSUER http://vouchryx:4310
  identity_env_set TOKENFUSE_DELEGATION_AUDIENCE "$AGENT_AUDIENCE"
  identity_env_set TOKENFUSE_DELEGATION_URL "http://$GATEWAY_PROBE:4100"
  identity_env_set TOKENFUSE_DELEGATION_REVOCATIONS http://vouchryx:4310/v1/revocations
  identity_env_set TOKENFUSE_DELEGATION_REVOCATIONS_INTERVAL_MS 12000
  identity_env_set MCP_BROKER_DELEGATION_AUDIENCE "$AGENT_AUDIENCE"
  identity_env_set MCP_BROKER_DELEGATION_URL "http://$GATEWAY_PROBE:4200"
  identity_env_set BROKER_TAINT_GATEWAY http://tokenfuse-gateway:4100
  identity_env_set BROKER_GATEWAY_KEY_FILE /run/broker/key
  # wardryx verifies the agent's token itself (wardryx 2.3.0, CLAUDE.md invariant 47): the same issuer,
  # audience and key set the doors use, vouchryx's revocation list, and the origin each door is
  # addressed by, because a DPoP proof names the URL it was sent to.
  identity_env_set WARDRYX_AGENT_TOKEN_ISSUER http://vouchryx:4310
  identity_env_set WARDRYX_AGENT_TOKEN_AUDIENCES "$AGENT_AUDIENCE"
  identity_env_set WARDRYX_AGENT_TOKEN_JWKS_URL http://vouchryx:4310/.well-known/jwks.json
  identity_env_set WARDRYX_AGENT_TOKEN_REVOCATION_URL http://vouchryx:4310/v1/revocations
  identity_env_set WARDRYX_AGENT_TOKEN_DOOR_ORIGINS "http://tokenfuse-gateway:4100,http://tokenfuse-mcp-broker:4200,http://$GATEWAY_PROBE:4100,http://$GATEWAY_PROBE:4200"
  mint_env_secret GATEWAY_BROKER_KEY
  broker="$(identity_env_get GATEWAY_BROKER_KEY)"
  why="$(identity_entry_why "$broker:broker")"
  [ -z "$why" ] || die "GATEWAY_BROKER_KEY in .env, the broker's client key, $why. Empty that line and the installer mints one. Nothing was started."
  # The broker runs as uid 20012 (CLAUDE.md invariant 41), so the key it reads is its own: owned by that uid,
  # 0400. A key owned by 10001 is unreadable to the broker, which then refuses to start (tokenfuse
  # mcpbroker.rs: "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE is not set") and restarts in a loop.
  upstream_put "$broker" "$STACK_DIR/broker"
  chown 20012:10001 "$STACK_DIR/broker/key" || die "could not give the broker's key to uid 20012 in $STACK_DIR/broker"
  note "the broker's key: in $STACK_DIR/broker/key (0400, uid 20012, never printed)"
}

# Section 3e, after mint_apply, when every client key is in .env: the static allow-lists the two doors
# read under require (CLAUDE.md invariant 47). A key id is a static key only when it is NAMED here: felyx
# and broker, which cannot sign a proof and are in use on every box that has them; the operator's
# STATIC_KEY_IDS; and, on a re-run, every key id this box already had. A listed id must be a key the
# door holds, or the door refuses to start, so STATIC_KEY_IDS naming a key this box does not have is refused.
agent_static_keys_apply() {
  local have id gw="" mcp="" have_mcp
  [ "$AGENT_TOKENS_ON" = 1 ] || return 0
  have=" $(client_key_ids "$(identity_env_get GATEWAY_CLIENT_KEYS)" | tr '\n' ' ')"
  for id in $STATIC_KEY_IDS_LIST; do
    case "$have" in *" $id "*) ;; *) die "STATIC_KEY_IDS names $id, which is not a client key this box holds. Nothing was started." ;; esac
  done
  for id in felyx broker $STATIC_KEY_IDS_LIST $EXISTING_GATEWAY_IDS; do
    case "$have" in *" $id "*) case " $gw " in *" $id "*) ;; *) gw="$gw $id" ;; esac ;; esac
  done
  gw="${gw# }"
  STATIC_GATEWAY_LIST="$(printf '%s' "$gw" | tr ' ' ',')"
  identity_env_set TOKENFUSE_AGENT_TOKENS_STATIC_KEYS "$STATIC_GATEWAY_LIST"
  # The broker's own list: only the key ids this box had before, since a fresh box has none to keep.
  have_mcp=" $(client_key_ids "$(identity_env_get TOKENFUSE_MCP_KEYS)" | tr '\n' ' ')"
  # stack-single is the installer's own key for the broker: its checks (tools/list, an ask, a refused call)
  # present it. It is named here, on purpose, with that reason in the closing report.
  for id in stack-single $EXISTING_MCP_IDS; do
    case "$have_mcp" in *" $id "*) case " $mcp " in *" $id "*) ;; *) mcp="$mcp $id" ;; esac ;; esac
  done
  mcp="${mcp# }"
  STATIC_MCP_LIST="$(printf '%s' "$mcp" | tr ' ' ',')"
  identity_env_set TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS "$STATIC_MCP_LIST"
}

agent_tokens_reach_note() {
  if [ "$AGENT_TOKENS_ON" != 1 ]; then
    [ "${WITH_AGENT_TOKENS:-}" = 0 ] || return 0
    printf '\n  Agent tokens are OFF (WITH_AGENT_TOKENS=0). This is the WEAKER setting: the gateway and\n'
    printf '  the MCP broker admit every static client key, and wardryx verifies no agent token.\n'
    printf '  Unset WITH_AGENT_TOKENS and run this installer again to turn them back on (CLAUDE.md invariant 47).'
    return 0
  fi
  printf '\n  Agent tokens are ON (the default). The agent %s enrols at vouchryx, not published to the\n' "$AGENT_TOKEN_AGENT"
  printf '  host, with the secret in %s/agent-token.key (0600, never printed). It\n' "$STACK_DIR"
  printf '  exchanges that for a five-minute token bound to its DPoP key. It asks for the\n'
  printf '  audience with resource=%s (RFC 8707; audience= works too). A request that\n' "$AGENT_AUDIENCE"
  printf '  names none is refused audience_not_allowed. It then sends\n'
  printf '  Authorization: DPoP <token> with a proof (carrying ath, RFC 9449). Stop the agent with one call:\n'
  printf '  POST http://vouchryx:4310/v1/revoke with ban, using VOUCHRYX_REVOKE_KEYS from .env.\n'
  printf '  Static keys still admitted at the gateway: %s\n' "${STATIC_GATEWAY_LIST:-none}"
  printf '  Static keys still admitted at the MCP broker: %s (stack-single is the installer'"'"'s own check key there; felyx and broker at the gateway are the console and the broker'"'"'s taint relay)\n' "${STATIC_MCP_LIST:-none}"
  printf '  static keys still admitted; move these agents to tokens, or name each one in STATIC_KEY_IDS on purpose.'
}
# agent-tokens: end


# ---- 0g. a second door, on the OpenAI wire (opt-in) ----------------------------
# The gateway speaks the Anthropic wire, POST /v1/messages. An agent whose SDK
# speaks the OpenAI wire (POST /v1/chat/completions: an OpenAI client, an Ollama
# or vLLM one) needs a gateway that serves that door in front of an upstream that
# speaks it, because tokenfuse serves one wire per process and translates nothing
# (tokenfuse docs/26). OPENAI_DOOR=1 runs a second gateway, tokenfuse-gateway-openai:
# the same image with every hardened setting of the first, published on port 4110
# on the same bind as 4100 (CLAUDE.md invariant 32).
#
#   OPENAI_DOOR=1                          the door on; 0 turns it off; unset keeps
#                                          what an earlier run saved in .env
#   OPENAI_DOOR_UPSTREAM=https://...       the full endpoint it forwards to, ending
#                                          in /chat/completions, not a base URL
#   OPENAI_DOOR_CLIENT_KEYS_FILE=/path     the door's own keys file and identity
#   OPENAI_DOOR_IDENTITY_MAP_FILE=/path    map, in section 0f's formats
#
# The door hands each caller's Authorization header to the upstream, so this box
# keeps no provider key for it, and a metered upstream bills whoever's key the
# caller sends. That is why it never opens without keys and a map: with
# OPENAI_DOOR=1 and no upstream, no keys file or no map (given now, or kept in .env
# by an earlier run), this refuses HERE, before a package is installed, and never
# echoes what it was given. Keys and a map of its OWN, not the gateway's: a unit's
# month counter lives in one gateway process, so a unit in both maps would spend
# its cap once on each door, and section 3e refuses two maps that declare the same
# unit. The files themselves are checked by section 0f's block, run for this door
# by name. Off removes the container; its lines stay in .env for a later
# OPENAI_DOOR=1. (gate: scripts/openai-door.sh lifts this block out and runs it.)
# openai-door: begin
DOOR_ON=0             # 1 when this box runs the OpenAI door after this run
DOOR_SET=""           # what this run said: "" nothing, 1 on, 0 off
DOOR_UPSTREAM=""      # the endpoint the door forwards to after this run
DOOR_UPSTREAM_NEW=""  # the endpoint this run named, "" when it named none

door_env_get() { # NAME: what .env holds for NAME, single quotes removed
  local v
  [ -f "$STACK_DIR/.env" ] || return 0
  v="$(sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env")"
  v="${v#\'}"
  v="${v%\'}"
  printf '%s' "$v"
}

door_env_set() { # NAME VALUE: replace or add NAME in .env, single-quoted
  local tmp
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  printf "%s='%s'\n" "$1" "$2" >>"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
}

door_env_forget() { # NAME: drop NAME's line from .env
  local tmp
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  { grep -v "^$1=" "$STACK_DIR/.env" || true; } >"$tmp"
  cat "$tmp" >"$STACK_DIR/.env" || die "could not update $STACK_DIR/.env"
  rm -f "$tmp"
}

# URL: an http or https endpoint with a host, ending in /chat/completions, and
# nothing more: no credentials, no query, no fragment, and no space, quote or
# dollar, so the value is plain text to compose and to the shell that sources .env.
door_url_ok() {
  local LC_ALL=C re='^https?://([A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~+-]+)*/chat/completions$'
  [[ "$1" =~ $re ]]
}

# Decide whether this box runs the door after this run, and refuse, naming what is
# missing, before anything has been touched.
door_resolve() {
  local saved
  DOOR_SET="${OPENAI_DOOR:-}"
  case "$DOOR_SET" in
    ""|0|1) ;;
    *) die "OPENAI_DOOR must be 1 (the OpenAI door on) or 0 (off). Nothing was installed." ;;
  esac
  saved="$(door_env_get OPENAI_DOOR)"
  case "$saved" in
    ""|1) ;;
    *) die ".env holds an OPENAI_DOOR other than 1. Fix or remove that line. Nothing was changed." ;;
  esac
  case "$DOOR_SET" in
    1) DOOR_ON=1 ;;
    0) DOOR_ON=0 ;;
    *) if [ "$saved" = 1 ]; then DOOR_ON=1; else DOOR_ON=0; fi ;;
  esac
  DOOR_UPSTREAM_NEW="${OPENAI_DOOR_UPSTREAM:-}"
  if [ "$DOOR_ON" != 1 ]; then
    [ -z "$DOOR_UPSTREAM_NEW${OPENAI_DOOR_CLIENT_KEYS_FILE:-}${OPENAI_DOOR_IDENTITY_MAP_FILE:-}" ] \
      || die "an OPENAI_DOOR_* setting was given with the OpenAI door off, so it would be ignored. Set OPENAI_DOOR=1 with it. Nothing was installed."
    DOOR_UPSTREAM=""
    return 0
  fi
  DOOR_UPSTREAM="$DOOR_UPSTREAM_NEW"
  [ -n "$DOOR_UPSTREAM" ] || DOOR_UPSTREAM="$(door_env_get OPENAI_DOOR_UPSTREAM)"
  [ -n "$DOOR_UPSTREAM" ] \
    || die "OPENAI_DOOR=1 needs OPENAI_DOOR_UPSTREAM, the full endpoint of an OpenAI-compatible provider, ending in /chat/completions (such as https://api.openai.com/v1/chat/completions). Nothing was installed."
  door_url_ok "$DOOR_UPSTREAM" \
    || die "OPENAI_DOOR_UPSTREAM must be an http or https URL with a host and no credentials, query or fragment, ending in /chat/completions: the full endpoint, not a base URL. Nothing was installed."
  [ -n "${OPENAI_DOOR_CLIENT_KEYS_FILE:-}" ] || [ -n "$(door_env_get OPENAI_DOOR_CLIENT_KEYS)" ] \
    || die "OPENAI_DOOR=1 needs OPENAI_DOOR_CLIENT_KEYS_FILE, a keys file of the door's own (secret:key_id lines): the door hands each caller's provider key to the upstream, so it never opens to callers it cannot name. Nothing was installed."
  [ -n "${OPENAI_DOOR_IDENTITY_MAP_FILE:-}" ] || [ -n "$(door_env_get OPENAI_DOOR_IDENTITY_MAP)" ] \
    || die "OPENAI_DOOR=1 needs OPENAI_DOOR_IDENTITY_MAP_FILE, an identity map of the door's own, with units no other map declares (README, \"A second door on the OpenAI wire\"). Nothing was installed."
}

# Write the decision where compose reads it. Called once .env exists. A run that
# says nothing changes nothing.
door_apply() {
  case "$DOOR_SET" in
    1) door_env_set OPENAI_DOOR 1 ;;
    0)
      door_env_forget OPENAI_DOOR
      note "OpenAI door: off. Its upstream, keys and map stay in .env for a later OPENAI_DOOR=1; remove the OPENAI_DOOR_ lines to forget them"
      ;;
  esac
  [ -z "$DOOR_UPSTREAM_NEW" ] || door_env_set OPENAI_DOOR_UPSTREAM "$DOOR_UPSTREAM_NEW"
  [ "$DOOR_ON" != 1 ] || note "OpenAI door: on, port 4110, forwarding to $DOOR_UPSTREAM"
}

# IMAGE MAP_A MAP_B: prints the ids of the units both maps declare, space-separated,
# nothing when they share none, and fails when the comparison could not run. A shell
# cannot read JSON, so python3 reads both, in a throwaway container of IMAGE (the
# console's image, which has it) with no network. Each map has already been read by
# the gateway image, so each is valid JSON.
door_units_shared() {
  local out
  [ -n "$1" ] || return 1
  out="$(docker run --rm --network none --entrypoint python3 \
      -v "$2:/maps/a.json:ro" -v "$3:/maps/b.json:ro" "$1" -c '
import json
def units(path):
    m = json.load(open(path))
    return {u["id"] for u in (m.get("units") or []) if isinstance(u, dict) and isinstance(u.get("id"), str)}
print(" ".join(sorted(units("/maps/a.json") & units("/maps/b.json"))))
' 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# DOOR_IMAGE CONSOLE_IMAGE: section 3e for the door, once the gateway's own check
# has run and before anything is written. The door's pair is read by the gateway
# image it will run, as section 0f says; then the two maps the run will leave are
# compared, and two that declare one unit are refused. Leaves the gateway selected.
# A refusal removes both doors' staging directories, so nothing is left half done.
door_identity_check() {
  local a="" b="" shared
  [ "$DOOR_ON" = 1 ] || return 0
  identity_door openai
  identity_check "$1"
  [ -z "$IDENTITY_STAGE" ] || b="$IDENTITY_STAGE/identity.json"
  identity_door main
  [ -z "$IDENTITY_STAGE" ] || a="$IDENTITY_STAGE/identity.json"
  [ -n "$a" ] && [ -f "$a" ] && [ -n "$b" ] && [ -f "$b" ] || return 0
  if ! shared="$(door_units_shared "$2" "$a" "$b")"; then
    door_unstage
    die "could not compare the gateway's identity map with the OpenAI door's (python3 in ${2:-the console image}), so a unit in both could not be ruled out. Nothing was changed."
  fi
  if [ -n "$shared" ]; then
    door_unstage
    die "the gateway's identity map and the OpenAI door's both declare unit(s) $shared. A unit's month counter lives in one gateway process, so a unit in both maps would get its cap once on each door. Give each door units of its own. Nothing was changed."
  fi
}

# Both doors' staging directories, removed before a refusal of the pair. Run with the
# gateway selected, so its own is IDENTITY_STAGE and the door's was saved by name.
door_unstage() {
  local s
  for s in "$IDENTITY_STAGE" "${IDENTITY_openai_STAGE:-}"; do
    [ -z "$s" ] || rm -rf -- "$s"
  done
}

# Write what door_identity_check passed, as identity_apply does for the gateway.
door_identity_apply() {
  [ "$DOOR_ON" = 1 ] || return 0
  identity_door openai
  identity_apply
  identity_door main
}
# openai-door: end
door_resolve
identity_door main
identity_resolve
if [ "$DOOR_ON" = 1 ]; then
  identity_door openai
  identity_resolve
  identity_door main
fi
mint_resolve
upstream_resolve
agent_tokens_resolve

say "installing docker and git"
export DEBIAN_FRONTEND=noninteractive
# `--no-remove` on every apt line here, and it is not decoration. On Debian 13
# the distro's `docker-buildx` depends on Debian's `docker-cli`, which
# conflicts with Docker's own `docker-ce-cli`, so on a box running Docker CE
# `apt-get install docker-buildx` resolves to `Remv docker-ce` and `Remv
# docker-ce-cli` (#55, measured 2026-09-17 with `apt-get install -s`): this
# installer would have taken Docker off the box it was about to run Docker's
# workloads on. `--no-remove` makes that resolution an error rather than a
# removal, whichever package is being asked for.
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  # docker.io from the distro, not get.docker.com: one less script piped from
  # the internet on a box that is about to hold an enforcement plane.
  # docker-buildx as well: the distro's docker.io does not include it, and
  # without it every build runs on the deprecated legacy builder.
  apt-get install -y -qq --no-remove docker.io docker-buildx git curl >/dev/null 2>&1 \
    || apt-get install -y -qq --no-remove docker.io git curl >/dev/null
else
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq --no-remove git curl >/dev/null 2>&1 || true
  # buildx here too, not only on the first-install branch: a box that already
  # had docker may not have it, and every build then runs on the deprecated
  # legacy builder while telling you so twice per image. But asked for only
  # when it is missing: a box with Docker CE already has it, as
  # docker-buildx-plugin, and the distro's package is the one that removes
  # Docker CE. And when it is missing on a Docker CE box, asked for from
  # Docker's own repository, which is where that box's packages come from.
  # Either install may fail and the box goes on without it: a build is the
  # BUILD_FROM_SOURCE path, and a pull needs no builder at all.
  if ! docker buildx version >/dev/null 2>&1; then
    if dpkg -s docker-ce 2>/dev/null | grep -q '^Status: install ok installed'; then
      apt-get install -y -qq --no-remove docker-buildx-plugin >/dev/null 2>&1 || true
    else
      apt-get install -y -qq --no-remove docker-buildx >/dev/null 2>&1 || true
    fi
  fi
fi
systemctl enable --now docker >/dev/null 2>&1 || die "docker did not start."
# Compose v2 as a plugin, or the standalone binary, or neither.
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  apt-get install -y -qq --no-remove docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq --no-remove docker-compose >/dev/null 2>&1 || true
  if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
  else die "no docker compose available; install the docker-compose-v2 package."; fi
fi
note "docker $(docker --version | awk '{print $3}' | tr -d ,), compose present"


# ---- 1. this repo, whether cloned or piped ----------------------------------
# C here is `true`, so the fallback is an empty HERE, which the next line handles.
# shellcheck disable=SC2015
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

# ---- 1b. notifications, asked BEFORE anything long ---------------------------
# Asked here for the same reason the cluster installer asks its questions at the
# top: an operator should answer everything they have to answer before a long
# build, not after it. Blank is a real answer and the default one.
#
# On a re-run this asks nothing. `.env` already holds the answer, and invariant
# 2 (works twice, untouched) means a second run must not re-interrogate an
# operator or quietly change what the first run set up.
ALERT_TO="${ALERT_TO:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_FROM="${SMTP_FROM:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_TLS="${SMTP_TLS:-}"
ALERT_CONFIGURED_NOW=0
if grep -q '^ALERT_TO=' .env 2>/dev/null; then
  note "notifications already configured in .env, left as is"
elif [ -n "$ALERT_TO" ]; then
  note "notifications configured from the environment"
  ALERT_CONFIGURED_NOW=1
elif { exec 4<>/dev/tty; } 2>/dev/null; then
  cat >&4 <<'TXT'

   Notifications. This box can write to you when one of your own agents
   crosses a line: a budget gone, a policy denial, a run killed, an agent
   behaving unlike itself. The mail comes from this box, it carries a link
   into this box's console, and it never carries a button that acts.

   Leave the address blank for no notifications. The notifier still runs and
   still watches, it simply has nobody to write to.

TXT
  printf '   address for alerts (blank = none): ' >&4
  IFS= read -r ans <&4 || ans=""
  ALERT_TO="$(printf '%s' "$ans" | tr -d '[:space:]')"
  if [ -n "$ALERT_TO" ]; then
    while [ -z "$SMTP_HOST" ]; do
      printf '   mail server as host:port (e.g. smtp.example.com:587): ' >&4
      IFS= read -r ans <&4 || ans=""
      ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
      case "$ans" in
        "")  printf '   without one, this box has nothing to hand the mail to.\n' >&4 ;;
        *:*) SMTP_HOST="$ans" ;;
        *)   printf '   needs a port too: %s:587 for submission, :465 for implicit TLS.\n' "$ans" >&4 ;;
      esac
    done
    if [ -z "$SMTP_TLS" ]; then
      while :; do
        printf '   TLS: blank for STARTTLS (implicit on port 465), or starttls, implicit, plain (loopback only): ' >&4
        IFS= read -r ans <&4 || ans=""
        ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
        case "$ans" in
          ""|starttls|implicit) SMTP_TLS="$ans"; break ;;
          plain)
            if smtp_tls_loopback "$SMTP_HOST"; then SMTP_TLS=plain; break; fi
            printf '   plain is for a loopback host only, and %s is not one.\n' "$SMTP_HOST" >&4 ;;
          *) printf '   not a TLS mode: starttls, implicit, plain, or blank.\n' >&4 ;;
        esac
      done
    fi
    printf '   sender address [%s]: ' "$ALERT_TO" >&4
    IFS= read -r ans <&4 || ans=""
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    SMTP_FROM="${ans:-$ALERT_TO}"
    printf '   username (blank = server wants no authentication): ' >&4
    IFS= read -r ans <&4 || ans=""
    SMTP_USER="$(printf '%s' "$ans" | tr -d '[:space:]')"
    if [ -n "$SMTP_USER" ]; then
      printf '   password: ' >&4
      IFS= read -rs SMTP_PASS <&4 || SMTP_PASS=""; printf '\n' >&4
    fi
    ALERT_CONFIGURED_NOW=1
  fi
  exec 4>&-
else
  note "no terminal to ask on: no notifications. Set ALERT_TO and SMTP_HOST in the"
  note "environment and re-run, or edit .env afterwards, to add them."
fi

# ---- 1c. typed answers, asked BEFORE anything long -----------------------------
# Asked only when nothing has answered it: no TYPED_MODE or TYPED_* in the
# environment, no WITH_TYPED=1 (that is the stub, unchanged, and is not
# re-asked), and .env holds no TYPED_MODE from an earlier run. Blank is a real
# answer, off, and it is written down so the next run does not ask again
# (invariant 2). With no terminal it asks nothing, and the choice is the
# environment's alone; see README, "Typed answers: choose where your data goes".
if [ "$TYPED_PLANE" = off ] && [ "$TYPED_EXPLICIT" = 0 ] && [ -z "$TYPED_SAVED_MODE" ] \
   && [ -z "${WITH_TYPED:-}" ]; then
  if { exec 4<>/dev/tty; } 2>/dev/null; then
    cat >&4 <<'TXT'

   Typed answers. typryx answers a typed question (a choice, a score, a yes or
   no) with a probability, so an agent can be checked against something other
   than its own say-so. Where should the answers come from?

     jev        a hosted service, TypeSafe's Jev. The fields each question names
                (and its instructions) leave this box for api.typesafe.ai. Metered.
     own-model  a model server you run, Ollama or vLLM. Questions go to that
                server and nowhere else: nothing leaves your own hardware.
     off        typryx is not installed. Nothing leaves. This is the default.

TXT
    tans=""
    while [ -z "$tans" ]; do
      printf '   Typed answers: jev / own-model / off [off]: ' >&4
      IFS= read -r ans <&4 || ans=""
      ans="$(printf '%s' "$ans" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      case "$ans" in
        ""|off) tans=off ;;
        jev|own-model) tans="$ans" ;;
        *) printf '   choose jev, own-model or off (or press enter for off).\n' >&4 ;;
      esac
    done
    if [ "$tans" = jev ]; then
      tpath=""
      while [ -z "$tpath" ]; do
        printf '   path of a file holding your Jev key (blank = off instead): ' >&4
        IFS= read -r ans <&4 || ans=""
        ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
        if [ -z "$ans" ]; then tans=off; break; fi
        if typed_file_ok "$ans"; then tpath="$ans"; else printf '   that is not a readable, non-empty file. It has to be the path of a file, not the key itself.\n' >&4; fi
      done
      [ "$tans" != jev ] || TYPED_JEV_KEY_FILE="$tpath"
    elif [ "$tans" = own-model ]; then
      turl=""
      while [ -z "$turl" ]; do
        printf '   server URL ending in /v1, e.g. http://host.docker.internal:11434/v1 (blank = off instead): ' >&4
        IFS= read -r ans <&4 || ans=""
        ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
        if [ -z "$ans" ]; then tans=off; break; fi
        if typed_url_ok "$ans"; then turl="$ans"; else printf '   needs an http or https URL, no credentials, ending in /v1.\n' >&4; fi
      done
      if [ "$tans" = own-model ]; then
        tname=""
        while [ -z "$tname" ]; do
          printf '   model name, e.g. qwen2.5:7b (blank = off instead): ' >&4
          IFS= read -r ans <&4 || ans=""
          ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
          if [ -z "$ans" ]; then tans=off; break; fi
          tname="$ans"
        done
      fi
      if [ "$tans" = own-model ]; then
        printf '   path of a file holding the server key (blank = the server needs none): ' >&4
        IFS= read -r ans <&4 || ans=""
        ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
        if [ -n "$ans" ]; then
          if typed_file_ok "$ans"; then TYPED_MODEL_KEY_FILE="$ans"; else printf '   not a readable, non-empty file, so no key will be used.\n' >&4; fi
        fi
        TYPED_MODEL_URL="$turl"
        TYPED_MODEL_NAME="$tname"
      fi
    fi
    exec 4>&-
    TYPED_MODE="$tans"
    typed_resolve
  else
    note "no terminal to ask on: typed answers stay off. Set TYPED_MODE=jev or TYPED_MODE=own-model"
    note "in the environment and re-run to choose where they come from (README has the variables)."
  fi
fi

# ---- 2. images ---------------------------------------------------------------
# PULLED, not built. This section used to open with "Built here rather than
# pulled: there is no public registry for these, and a private one is another
# component to secure and another bill." That sentence was true when it was
# written and stopped being true on 2026-09-01, when the estate finished
# publishing every plane to ghcr.io and the CLUSTER launcher stopped building
# on its nodes. This launcher was left behind, so a person installing on their
# own box kept paying a compile for images that already existed, and the
# comment above told them it was necessary.
#
# What is still built here, and why: `caddy` and `wg`. They are the operator's
# door rather than a plane, they live in stack-k8s/images rather than in a
# service repository, and until stack-k8s publishes them there is nothing to
# pull. Both are small next to what used to be here.
#
# BUILD_FROM_SOURCE=1 restores the old path in full, for the two cases a
# registry does not serve: a change that is not released yet, and a box that
# cannot reach ghcr.io. It is the same escape hatch, and the same name, that
# stack-k8s/cloud/*/deploy-*.sh carries.
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-}"

# The image definitions. Needed only by the build path now that every image
# this launcher runs is published, and fetched unconditionally anyway: it is one
# tarball, it is what `build-context-complete.sh` checks against, and a build
# that discovers its Dockerfiles are missing ten minutes in is the failure that
# put this fetch here in the first place.
#
# The whole of stack-k8s, not five URLs. This used to fetch exactly five
# `.Dockerfile` files by raw URL. It worked until `wg.Dockerfile` in that
# repository grew a `COPY images/uapi-proxy`, which is a DIRECTORY in its build
# context, and nothing here fetched it. A clean install then died ten minutes
# in with "failed to compute cache key: /images/uapi-proxy: not found", and
# neither repository's CI could have seen it: the break is in the seam between
# them, and this side had not changed. One tarball cannot drift file by file.
say "fetching the image definitions"
mkdir -p "$SRC_DIR"
rm -rf "$SRC_DIR/stack-k8s"
mkdir -p "$SRC_DIR/stack-k8s"
curl -fsSL "$REPO_TARBALL" | tar -xz -C "$SRC_DIR/stack-k8s" --strip-components=1 \
  || die "could not fetch the image definitions from stack-k8s"
[ -f "$SRC_DIR/stack-k8s/images/wg.Dockerfile" ] \
  || die "the stack-k8s tarball has no images/wg.Dockerfile; the layout changed"
cd "$SRC_DIR"

if [ -n "$BUILD_FROM_SOURCE" ]; then
  note "BUILD_FROM_SOURCE is set: cloning every plane and compiling here"
  repos=(tokenfuse wardryx idryx qryx mockryx heraldyx scopyx verdryx engram)
  [ -z "${WITH_RECORD:-}" ] || repos+=(trailryx)
  for r in "${repos[@]}"; do
    # A && B || C here is deliberate: the refresh is best-effort and C is `true`.
    # shellcheck disable=SC2015
    if [ -d "$r/.git" ]; then (cd "$r" && git pull -q --ff-only 2>/dev/null || true)
    else git clone --depth 1 -q "https://github.com/TAIPANBOX/$r.git" "$r" || die "could not clone $r"; fi
  done
  # The console is Apache-2.0 and public since 2026-07-27, so it clones like
  # everything else and needs no token. CONSOLE_TOKEN still works, for the one
  # case it is now good for: a private fork of your own.
  if [ -d "$SRC_DIR/genaryx-a360/.git" ]; then
    # shellcheck disable=SC2015
    (cd genaryx-a360 && git pull -q --ff-only 2>/dev/null || true)
  elif [ -d "$SRC_DIR/genaryx-a360" ]; then
    note "console source already present and not a checkout, leaving it alone"
  elif [ -n "$CONSOLE_TOKEN" ]; then
    # The token is handed to git by a credential helper that reads it from this command's
    # environment when git asks for it. It is in no URL and on no argument list, so git
    # writes it into neither the clone's .git/config nor its remote URL. The empty
    # credential.helper= first resets the helper list, so a system or global helper (store,
    # osxkeychain) is never handed the token to save after the clone.
    # (gate: scripts/no-secret-on-argv.sh)
    # shellcheck disable=SC2016  # the helper is a string git runs later: its $CONSOLE_TOKEN must not expand here
    CONSOLE_TOKEN="$CONSOLE_TOKEN" git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; printf "password=%s\n" "$CONSOLE_TOKEN"; }; f' \
      clone --depth 1 -q "https://github.com/TAIPANBOX/genaryx.git" genaryx-a360 \
      || die "could not clone the console with the token given; is it valid for your fork?"
  else
    git clone --depth 1 -q "https://github.com/TAIPANBOX/genaryx.git" genaryx-a360 \
      || die "could not clone the console"
  fi

  say "building images (first run is slow: Rust)"
  # The tags built here are the ones the *_IMAGE overrides in compose.yaml
  # accept, so this path needs no second copy of the compose file. An operator
  # taking this route sets them in .env; install.sh writes them below.
  for pair in wardryx:wardryx idryx:idryx heraldyx:heraldyx scopyx:scopyx; do
    name="${pair%%:*}"; repo="${pair##*:}"
    note "building $name"
    docker build -q -f stack-k8s/images/go-service.Dockerfile \
      --build-arg SERVICE="$name" --build-arg SRC="./$repo" -t "stack/$name:dev" . >/dev/null \
      || die "image build failed: $name"
  done
  if [ -n "${WITH_BROWSER:-}" ]; then
    [ -f "$SRC_DIR/stack-k8s/images/scopyx-browser.Dockerfile" ] \
      || die "WITH_BROWSER is set but the stack-k8s tarball has no images/scopyx-browser.Dockerfile"
    note "building scopyx-browser (about 1GB, and slow: it installs chromium)"
    docker build -q -f stack-k8s/images/scopyx-browser.Dockerfile \
      --build-arg SRC=./scopyx -t stack/scopyx-browser:dev . >/dev/null \
      || die "image build failed: scopyx-browser"
  fi
  if [ -n "${WITH_RECORD:-}" ]; then
    [ -f "$SRC_DIR/stack-k8s/images/trailryx.Dockerfile" ] \
      || die "WITH_RECORD is set but the stack-k8s tarball has no images/trailryx.Dockerfile"
    note "building trailryx (the record plane, and slow: Rust)"
    # The CONTEXT is ./trailryx, not `.` with a SRC build-arg. This file does
    # `COPY . .` into /src and takes no SRC, exactly like tokenfuse.Dockerfile,
    # and unlike go-service.Dockerfile, which is where the SRC form came from.
    # Built with the wrong context it dies at `cargo build` with "could not
    # find Cargo.toml in /src", ten minutes in.
    docker build -q -f stack-k8s/images/trailryx.Dockerfile \
      -t stack/trailryx:dev ./trailryx >/dev/null \
      || die "image build failed: trailryx"
  fi
  note "building tokenfuse (gateway + cloud)"
  docker build -q -f stack-k8s/images/tokenfuse.Dockerfile -t stack/tokenfuse:dev ./tokenfuse >/dev/null \
    || die "image build failed: tokenfuse"
  if [ -d genaryx-a360 ]; then
    note "building the console (four languages, it hosts the tools it runs)"
    docker build -q -f stack-k8s/images/console.Dockerfile -t stack/genaryx-console:dev . >/dev/null \
      || die "image build failed: console"
  fi
fi

# The operator's door is published too, since stack-k8s#49, so it is pulled with
# everything else in 3c and built here only when the operator asked to build.
if [ -n "$BUILD_FROM_SOURCE" ]; then
  note "building caddy (TLS for the console)"
  docker build -q -f stack-k8s/images/caddy.Dockerfile -t stack/caddy:dev stack-k8s >/dev/null \
    || die "image build failed: caddy"
  note "building wg (the operator's tunnel)"
  docker build -q -f stack-k8s/images/wg.Dockerfile -t stack/wg:dev stack-k8s >/dev/null \
    || die "image build failed: wg"
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
# twice over, because tr reads a stream that never ends and only a closed pipe
# stops it. Under `set -o pipefail` the SIGPIPE that stops it fails the
# pipeline (141) and `set -e` ends the script here, silently, with no .env
# written. With SIGPIPE ignored, which is how git runs a hook, nothing stops
# it: macOS's tr never exits, and GNU tr prints "write error: Broken pipe" on
# every call. So the read is bounded and nothing closes a pipe early: 4096
# random bytes hold about 990 of the 62 characters on average, the longest
# secret asked for here is 64, tr reads to the end of its input, and the cut
# to N is bash's own. The length check is what refuses a short value.
# (gate: scripts/gen-is-bounded.sh runs this under ignored SIGPIPE for every N
# install.sh asks for; scripts/delegation-key-reused-on-rerun.sh lifts it.)
# gen: begin
gen() {
  local n="${1:-40}" v
  v="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')" || v=""
  v="${v:0:$n}"
  [ "${#v}" = "$n" ] || die "could not generate a $n-character secret (got ${#v}); /dev/urandom is not readable."
  printf '%s' "$v"
}
# gen: end
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
# policy and needs admin. The gateway only asks for decisions (/v1/decide and
# /v1/filter-tools), so it gets a PEP key, the enforcement point's role: an
# enforcement point that can rewrite the policy it enforces is not one. wardryx
# 2.0.0 refuses a viewer key on those two routes, so a viewer here would refuse
# every governed call.
WARDRYX_KEYS=$WARDRYX_ADMIN_SECRET:default:admin,$WARDRYX_GATEWAY_SECRET:default:pep
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

# wardryx-role: begin
# wardryx 2.0.0 refuses a viewer key on POST /v1/decide and POST /v1/filter-tools,
# the two calls the gateway, the MCP broker and scopyx make on every governed call
# with this one key. A .env minted before that release still says viewer, and a
# re-run leaves .env as is, so this one entry is rewritten here, before the stack
# comes up: its role and nothing else. The secret, the org, any agent list, every
# other entry and every other line stay as they were, and the file keeps its mode.
wardryx_gateway_role() {
  [ -s .env ] || return 0
  local gw keys new tmp
  gw="$(sed -n 's/^WARDRYX_GATEWAY=//p' .env | head -n 1 | tr -d "'\"")"
  keys="$(sed -n 's/^WARDRYX_KEYS=//p' .env | head -n 1 | tr -d "'\"")"
  [ -n "$gw" ] && [ -n "$keys" ] || return 0
  new="$(printf '%s' "$keys" | awk -v gw="$gw" -F, '
    {
      out = ""
      for (i = 1; i <= NF; i++) {
        e = $i
        if (index(e, gw ":") == 1) {
          rest = substr(e, length(gw) + 2)
          c = index(rest, ":")
          if (c > 0) {
            org = substr(rest, 1, c - 1)
            tail = substr(rest, c + 1)
            role = tail
            sub(/:.*/, "", role)
            if (role == "viewer") e = gw ":" org ":pep" substr(tail, 7)
          }
        }
        out = (i == 1 ? e : out "," e)
      }
      printf "%s", out
    }')"
  [ "$new" != "$keys" ] || return 0
  tmp="$(mktemp)" || die "could not make a temporary file to update .env"
  awk -v v="$new" '/^WARDRYX_KEYS=/ && !done { print "WARDRYX_KEYS=" v; done = 1; next } { print }' .env >"$tmp" \
    || die "could not read .env to update WARDRYX_KEYS"
  cat "$tmp" >.env || die "could not update .env"
  rm -f "$tmp"
  note "WARDRYX_KEYS: the gateway's entry moves from viewer to pep (its secret is unchanged)"
}
# wardryx-role: end
wardryx_gateway_role

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

# The gateway's admin key. It is the bare key the console presents on the
# gateway's five observability and kill routes (/v1/runs, /v1/runs/{id}/kill,
# /v1/keys, /v1/policy-plane, /v1/agent-ids). tokenfuse v0.4.4 enforces it on
# all five: no key or the wrong one is refused. There is no bridge variable
# left to fall back to.
add_env_default GATEWAY_ADMIN "$(gen 40)"

# The gateway's declassify key. `POST /v1/fuse/declassify` lifts a run's taint
# label (tokenfuse docs/07 B.4, the release valve) and is NOT behind the admin
# key above: it has a credential of its own, `TOKENFUSE_DECLASSIFY_KEY`, which
# the gateway reads from `x-fuse-declassify-key`. When that variable is unset
# the endpoint is open to anything that reaches the port, and a clearance is
# recorded only as `authenticated: false`. Nothing in this stack calls the
# endpoint, so minting a key that only the operator holds closes it by
# default and breaks nothing. Generated like every other key here, once, into
# .env (0600), read back from there and never printed; clearing a run needs it.
add_env_default GATEWAY_DECLASSIFY_KEY "$(gen 40)"

# Notifications, from the answers given before the build.
#
# Single-quoted, and this is not fussiness. `.env` has TWO readers: compose
# interpolates it, and line "` . ./.env`" below sources it into THIS shell as
# root. Every other value in this file is a generated alphanumeric or an IP, so
# neither reader has ever met a character it minds. A mail password is the
# first value here an operator types, and it can hold a space, a dollar, a
# quote or a backtick. Unquoted, `SMTP_PASS=a b` makes the shell try to run
# `b`, and a backtick would make it run whatever is between them, as root, on
# the operator's own machine. Single quotes are the one form both readers treat
# literally: compose does not interpolate inside them, and the shell does not
# either. An embedded quote is closed, escaped and reopened, the standard way.
#
# An EMPTY ALERT_TO is written on purpose. It records that the question was
# asked and answered, so the next run does not ask again (invariant 2: a second
# run changes nothing).
sq_() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }
add_env_default ALERT_TO   "$(sq_ "$ALERT_TO")"
add_env_default SMTP_HOST  "$(sq_ "$SMTP_HOST")"
add_env_default SMTP_FROM  "$(sq_ "$SMTP_FROM")"
add_env_default SMTP_USER  "$(sq_ "$SMTP_USER")"
add_env_default SMTP_PASS  "$(sq_ "$SMTP_PASS")"
add_env_default SMTP_TLS   "$(sq_ "$SMTP_TLS")"
add_env_default ALERT_MIN_SEVERITY high
# Where an alert's one link points, when the console domain is not how you
# reach this box. Empty means "use CONSOLE_DOMAIN", which is the tunnel. Set it
# to http://localhost:17420 if you reach the console over `ssh -L` instead, and
# the links in your mail will open. Mail itself needs neither: the notifier
# dials outward, and the tunnel is how you get IN.
add_env_default ALERT_CONSOLE_URL "$(sq_ "")"
# The egress enforcement point, new in this release.
#
# The credential carries the agent identity, and that is not decoration: the
# only authenticated fact scopyx has is which credential was presented, so it is
# the only thing an agent identity may be derived from. A header naming the
# agent would be the caller telling us who it is, and a policy carrying
# `deny_if_unattested` would then be satisfied by a string the caller wrote for
# itself.
#
# `agent://local.invalid/...` on purpose. `.invalid` is reserved by RFC 2606 and
# resolves nowhere, so a trust domain nobody configured cannot collide with a
# real one an operator later uses, and cannot be mistaken for one in a trail.
# Change it to your own domain when you have one.
add_env_default SCOPYX_KEYS "$(gen 40)=agent://local.invalid/default-agent"
# Its own pep key for the policy plane (the gateway's key, the same secret), for the reason the gateway has one:
# an enforcement point that can rewrite the policy it enforces is not an
# enforcement point.
#
# Read back from .env when it is not in this shell's memory, which is the case
# on EVERY re-run: WARDRYX_GATEWAY_SECRET is generated inside the block that
# writes .env for the first time, and that block is skipped once .env exists.
# Without this line an upgraded box would get SCOPYX_WARDRYX_KEY= empty, scopyx
# would fail every decision as unauthenticated, and it would fail CLOSED, so the
# symptom would be "nothing can fetch" with a reason pointing at the policy
# plane. Invariant 2 of this repo, works twice untouched, is exactly this.
WARDRYX_GATEWAY_SECRET="${WARDRYX_GATEWAY_SECRET:-$(sed -n 's/^WARDRYX_GATEWAY=//p' .env 2>/dev/null | head -1)}"
[ -n "$WARDRYX_GATEWAY_SECRET" ] || die "could not find WARDRYX_GATEWAY in .env, so scopyx would be given an empty credential for the policy plane"
add_env_default SCOPYX_WARDRYX_KEY "$(sq_ "$WARDRYX_GATEWAY_SECRET")"
# Finite, and lower than scopyx's own default of 500. This is a real box
# governing whatever fleet the operator points at it: an agent loop that
# discovers it can fetch will do so as fast as it is allowed, and the first
# anybody hears of it is a bill or a rate-limit from the site being fetched.
add_env_default SCOPYX_MAX_FETCHES_PER_HOUR 200
# The typed-answer plane's own door, handled exactly like scopyx's above:
# same generation, same file, empty refuses to start. `.invalid` for the same
# reason: a trust domain nobody configured cannot collide with a real one an
# operator later uses.
#
# @claude 2026-09-26: this identity is NOT derived from RECORD_TRUST_DOMAIN,
# matching SCOPYX_KEYS right above it rather than the record plane's own
# trust domain. It would not change what record-seal does with typryx's
# events either way. Trailryx 1.0 refused the four as unknown_schema; trailryx 1.4.0 reads
# that schema, and whether the record plane seals them is not measured here (the record
# plane is opt-in). So a matching trust domain would only keep the identity honest, and
# staying consistent with every other generated identity here is worth more than that.
add_env_default TYPRYX_KEYS "$(gen 40)=agent://local.invalid/default-agent"

# tokenfuse's MCP broker, fronting typryx (profile typed, same as above).
# @decided 2026-09-26: tokenfuse's own code is not touched for this; typryx
# joins it entirely by configuration, so everything below is a key spec and
# two variables, never a code change in either repository.
#
# The broker's OWN client-side door: whoever calls it for the typed plane
# presents this key. Generated once, like every other key here.
add_env_default TOKENFUSE_MCP_KEYS "$(gen 40):stack-single"
# The vault entry the broker resolves {{secret:typryx_key}} against, reusing
# TYPRYX_KEYS's own bare key rather than minting a second credential that
# could drift from the one typryx itself checks.
#
# Read back from .env rather than kept in this shell's memory, for
# WARDRYX_GATEWAY_SECRET's own reason above: TYPRYX_KEYS is generated inside
# the block that writes .env for the first time, which a re-run skips.
TYPRYX_KEY_BARE="${TYPRYX_KEY_BARE:-$(sed -n 's/^TYPRYX_KEYS=\([^=]*\)=.*/\1/p' .env 2>/dev/null | head -1)}"
[ -n "$TYPRYX_KEY_BARE" ] || die "could not find TYPRYX_KEYS in .env, so the broker would be given an empty secret for the typed plane"
add_env_default TOKENFUSE_MCP_SECRETS "typryx_key=$TYPRYX_KEY_BARE"
# Quoted: `|` is a pipe to the shell that sources .env below, so unquoted this
# line ran `ask_freeform` and `list_questions` as commands and stopped every
# install at `. ./.env` (v1.1.9 to v1.1.12, measured 2026-09-27 on Debian 13).
add_env_default TOKENFUSE_MCP_SECRET_SCOPES "$(sq_ 'typryx_key=tools:ask|ask_freeform|list_questions')"
# Where typed answers come from (section 0b): jev, own-model or off, written
# into .env only when this run chose or changed it, and the key file, if any,
# copied into ./typed. Refusals were made before anything was touched.
typed_apply
# The ceiling on a run budget (section 0c): written only when this run set it.
ceiling_apply
# The agent firewall's mode (section 0d): written only when this run set it.
firewall_apply
# The PII switch (section 0e): written only when this run set it.
pii_apply
# The OpenAI door (section 0g): written only when this run said something about it.
door_apply
# The gateway's client keys when this box was given none (section 0f, invariant 35):
# Felyx's and the agents' secrets minted into .env if absent, and the spec and map
# built from them for section 3e to check and install.
agent_tokens_apply
mint_prepare
# The provider keys the gateway and the OpenAI door hold (section 0h, invariant 39): the
# directories compose mounts, the files written from what the operator gave, and the
# .env lines naming them.
upstream_apply

# The delegation plane's own door (profile delegation), handled like every
# other opt-in plane's key above: generated whether or not WITH_DELEGATION is
# set this run, because vouchryx itself sits behind a profile no install
# enables on its own, so an unused credential here is as harmless as
# TYPRYX_KEYS is on a box that never sets WITH_TYPED.
#
# `POST /v1/revoke`'s own bearer key. Vouchryx's own convention, not this
# repo's spec-then-bare-key shape the other planes use: a plain bearer
# credential, no `:org` half to omit by mistake.
add_env_default VOUCHRYX_REVOKE_KEYS "$(gen 40)"
# VOUCHRYX_TRUSTED_ISSUERS is deliberately NOT given an empty default here,
# unlike every key above: it is written to .env only once a real value
# exists, either the operator's own or WITH_DELEGATION_DEMO_ISSUER's minted
# one, in the WITH_DELEGATION block below (after .env is read back). A box
# that never asks for delegation simply never gets this line at all, and
# compose's own `${VOUCHRYX_TRUSTED_ISSUERS:-}` treats its absence exactly
# like an empty value.

# When the operator asked to build, compose has to be pointed at what was
# built. Without these nine lines a BUILD_FROM_SOURCE install compiles every
# plane and then runs the PUBLISHED ones anyway, which is the worst of both:
# the wait is paid and the change being tested is not what runs.
#
# `add_env_default`, so a box that already carries an override keeps it.
#
# One asymmetry worth the line: the published gateway and control plane are two
# images, and the local build is one carrying both binaries. The `command:`
# entries need no switch because stack-k8s/images/tokenfuse.Dockerfile installs
# the gateway under BOTH names, `tokenfuse` and `tokenfuse-gateway`, so the one
# compose names resolves either way.
if [ -n "$BUILD_FROM_SOURCE" ]; then
  add_env_default WARDRYX_IMAGE          stack/wardryx:dev
  add_env_default IDRYX_IMAGE            stack/idryx:dev
  add_env_default HERALDYX_IMAGE         stack/heraldyx:dev
  add_env_default SCOPYX_IMAGE           stack/scopyx:dev
  add_env_default SCOPYX_BROWSER_IMAGE   stack/scopyx-browser:dev
  add_env_default TOKENFUSE_IMAGE        stack/tokenfuse:dev
  add_env_default TOKENFUSE_CLOUD_IMAGE  stack/tokenfuse:dev
  add_env_default CONSOLE_IMAGE          stack/genaryx-console:dev
  add_env_default TRAILRYX_IMAGE         stack/trailryx:dev
  add_env_default CADDY_IMAGE            stack/caddy:dev
  add_env_default WG_IMAGE               stack/wg:dev
fi

# Out of this shell's memory now that it is on disk at 0600.
SMTP_PASS=""

# Read back what is actually on this box rather than what this run's defaults
# would have written. On a re-run the block above left .env exactly as it was,
# so an existing deployment keeps its own binding and its own credentials, and
# every section below then reports and verifies the real values instead of
# announcing a boundary this run merely intended.
# A .env written by v1.1.9 to v1.1.12 carries one unquoted value with `|` in
# it, and add_env_default never rewrites a line that exists, so without this a
# box that installed one of those releases could not re-run any later one.
# Quotes, in place, every unquoted value holding a character the shell would
# act on; a value that is already quoted, or plain, is left byte for byte.
# (gate: scripts/env-sources-cleanly.sh runs this function on such a file.)
repair_env_quoting() {
  local f="$1" tmp
  tmp="$(mktemp)" || return 1
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      i = index($0, "="); name = substr($0, 1, i - 1); val = substr($0, i + 1)
      first = substr(val, 1, 1)
      if (first != "\047" && first != "\"" && val ~ /[|&;<>()`$ \t\\]/) {
        gsub(/\047/, "\047\\\047\047", val)
        print name "=\047" val "\047"; fixed++; next
      }
    }
    { print }
    END { if (fixed) printf "%d\n", fixed > "/dev/stderr" }
  ' "$f" >"$tmp" 2>"$tmp.n" || { rm -f "$tmp" "$tmp.n"; return 1; }
  if [ -s "$tmp.n" ]; then
    cat "$tmp" >"$f"
    note "quoted $(cat "$tmp.n") value(s) in .env that the shell would have run as commands"
  fi
  rm -f "$tmp" "$tmp.n"
}
repair_env_quoting .env || die "could not check .env's quoting"
# shellcheck disable=SC1091  # generated at install time, not in this repo
. ./.env
# The bind is now the one this box has, which may not be the one this run was
# given (see gateway_probe_resolve at the top).
gateway_probe_resolve

# ---- 3f. key custody and the witness (CLAUDE.md invariants 41 to 43) -------
# Two root keys, one per role, each 32 random bytes (64 hex characters), written ONCE: a root key
# that is replaced orphans every key wrapped under it, so this never rewrites
# or deletes one (the installer never deletes a key). Each is mode 0400 and
# owned by the uid of the one process that reads it (custody 20101, witness
# 20100). Neither reaches .env. The policy file and the consumers' socket
# directories are rebuilt from fixed text on every run; they hold no secret.
keyryx_root_key() { # FILE UID: create FILE with 32 random bytes when absent
  local f="$1" uid="$2" tmp
  if [ -e "$f" ]; then
    if ! { [ -f "$f" ] && [ -s "$f" ]; }; then die "$f exists but is not a non-empty file; refusing to replace a keyryx root key"; fi
    if ! { chown "$uid:$uid" "$f" && chmod 0400 "$f"; }; then die "could not set the owner or mode of $f"; fi
    return 0
  fi
  tmp="$f.tmp.$$"
  # Keyryx reads exactly 64 hex characters (its KEYRYX_ROOT_KEY_FILE check), so
  # 32 random bytes are written as hex, with no newline.
  ( umask 077; head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n' >"$tmp" ) || die "could not read 32 random bytes for $f"
  [ "$(wc -c <"$tmp" | tr -d ' ')" = 64 ] || { rm -f "$tmp"; die "the root key for $f came out short"; }
  if ! { chown "$uid:$uid" "$tmp" && chmod 0400 "$tmp" && mv -f "$tmp" "$f"; }; then die "could not put the root key in place at $f"; fi
  note "keyryx root key written at $f (32 bytes, 0400, uid $uid; its contents are never shown)"
}

keyryx_prepare() {
  local kdir="$STACK_DIR/keyryx"
  mkdir -p "$kdir/sock" || die "could not create $kdir/sock"
  chmod 0700 "$kdir" || die "could not set the mode of $kdir"
  keyryx_root_key "$kdir/root.key" 20101
  keyryx_root_key "$kdir/witness-root.key" 20100
  # The policy: which keys exist, which consumer may use which, and how each
  # consumer is recognised (its socket). Fixed text, rewritten each run, 0444:
  # it holds no secret, and custody reads it as its own uid.
  ( umask 022; cat >"$kdir/policy.json.tmp" <<'POLICY' ) || die "could not write $kdir/policy.json"
{
  "version": 1,
  "keys": [
    {"name": "wardryx-approval", "alg": "ES256"},
    {"name": "trailryx-root", "alg": "ES384"},
    {"name": "vouchryx", "alg": "ES256", "mode": "delegated",
     "max_lifetime": "72h", "overlap": "10m"}
  ],
  "consumers": [
    {"name": "wardryx", "auth": {"socket": "wardryx"},
     "grants": {"wardryx-approval": ["sign"]}},
    {"name": "vouchryx", "auth": {"socket": "vouchryx"},
     "grants": {"vouchryx": ["delegate"]}},
    {"name": "record-seal", "auth": {"socket": "record-seal"},
     "grants": {"trailryx-root": ["sign"]}}
  ]
}
POLICY
  mv -f "$kdir/policy.json.tmp" "$kdir/policy.json" || die "could not put $kdir/policy.json in place"
  chmod 0444 "$kdir/policy.json" || die "could not set the mode of $kdir/policy.json"
  # One directory per consumer socket. Keyryx refuses a directory open to
  # other users, so each is owned by custody and entered only through a group
  # that is the consumer's own: the wardryx and vouchryx containers join theirs
  # with group_add, and record-seal's joins when its signer is wired. The bus
  # group (10001) is never given one of these, or any bus reader could speak as
  # a consumer over its socket (CLAUDE.md invariant 42).
  local name gid
  for name in wardryx:20001 vouchryx:20002 record-seal:30001; do
    gid="${name#*:}"; name="${name%:*}"
    mkdir -p "$kdir/sock/$name" || die "could not create $kdir/sock/$name"
    if ! { chown "20101:$gid" "$kdir/sock/$name" && chmod 0750 "$kdir/sock/$name"; }; then
      die "could not set the owner or mode of $kdir/sock/$name"
    fi
  done
  # The bus's own stream for the custody's alerts is pre-created by init-volumes;
  # nothing here touches the bus.
}

keyryx_prepare

# ---- 3b. delegation: vouchryx, opt-in -----------------------------------------
# @decided 2026-09-27: the launchers offer vouchryx as an opt-in delegation
# plane, off by default, so a gateway can verify a proved delegation chain
# instead of trusting a claimed one. Off, exactly as before this release, the
# gateway's own chainproof stays unset and `x-fuse-on-behalf-of` is whatever
# the caller typed; see README's "Delegation" section for the rest.
#
# WHY THIS REFUSES BEFORE ANYTHING ELSE STARTS (invariant 6, fail before doing
# half the job, and CLAUDE.md invariant 15). vouchryx itself refuses to start
# with zero trusted issuers (an empty VOUCHRYX_TRUSTED_ISSUERS parses to zero
# entries), so a stack that pulled every image and wrote every other
# credential and only THEN discovered vouchryx would not come up would leave
# every other plane running while the one thing the operator actually asked
# for, a verified chain, silently never happened. So this is checked here,
# before section 3c pulls a single image.
# demo-issuer: begin
# The demo IdP's line in .env. vouchryx 0.5.0 refuses a subject token with no cnf.jkt unless its issuer line
# ends in |unbound, and the demo IdP sends unbound tokens (vouchryx-demo keygen says so). add_env_default writes
# the line once, so a box installed before that release keeps the old one, and nothing rewrites a line that
# exists. Only that exact line is migrated: an operator's own line can never equal it.
DEMO_ISSUER_OLD="https://idp.stack-single.local|stack-single|/etc/vouchryx/idp.jwks.json"
DEMO_ISSUER_NEW="$DEMO_ISSUER_OLD|unbound"
demo_issuer_migrate() { # ENV_FILE: rewrite the old demo line in ENV_FILE to the new one, and nothing else
  local env_file="$1" tmp
  [ -f "$env_file" ] || return 0
  grep -qxF "VOUCHRYX_TRUSTED_ISSUERS='$DEMO_ISSUER_OLD'" "$env_file" || return 0
  tmp="$(mktemp)" || die "could not make a temporary file to update $env_file"
  awk -v old="VOUCHRYX_TRUSTED_ISSUERS='$DEMO_ISSUER_OLD'" -v new="VOUCHRYX_TRUSTED_ISSUERS='$DEMO_ISSUER_NEW'" \
    '$0 == old { print new; next } { print }' "$env_file" >"$tmp" || { rm -f "$tmp"; die "could not rewrite $env_file"; }
  cat "$tmp" >"$env_file" || { rm -f "$tmp"; die "could not update $env_file"; }
  rm -f "$tmp"
  note "vouchryx: the demo issuer's line in .env now ends in |unbound (vouchryx 0.5.0 and later need it)"
}
# demo-issuer: end

if [ "${DELEGATION_ON:-0}" = 1 ]; then
  say "delegation"
  # The value on this box now, whichever run put it there: an operator's own
  # VOUCHRYX_TRUSTED_ISSUERS in the environment this run, or .env already
  # carrying one from an earlier run (just sourced above).
  VOUCHRYX_TRUSTED_ISSUERS="${VOUCHRYX_TRUSTED_ISSUERS:-}"
  if [ -n "${WITH_DELEGATION:-}" ] && [ -z "$VOUCHRYX_TRUSTED_ISSUERS" ] && [ -z "${WITH_DELEGATION_DEMO_ISSUER:-}" ]; then
    die "WITH_DELEGATION=1 needs a trusted upstream issuer to verify the subject and actor \
tokens it exchanges against, and none is configured. Set VOUCHRYX_TRUSTED_ISSUERS='iss|aud|jwks-path' \
(the jwks-path readable inside $STACK_DIR/delegation once this run finishes), naming the identity \
provider your agents actually get their tokens from. There is no safe value to invent here, so \
nothing started. To try this out instead of wiring a real issuer, set WITH_DELEGATION_DEMO_ISSUER=1 \
for a clearly-labelled, self-signed issuer this installer mints for you; it is never a production \
posture and README says so."
  fi

  # vouchryx's own directory: its signing key, and the demo issuer's JWKS
  # when one is minted. Owned by the uid vouchryx runs as (20002 since invariant 41, distroless
  # nonroot) and closed to everyone else, the gateway included: a bind mount
  # keeps the host's ownership and mode, so a root-owned 0700 directory is one
  # the container cannot even enter (measured 2026-09-27 on Debian 13; Docker
  # Desktop on macOS ignores bind-mount ownership and hides this).
  mkdir -p delegation
  chown 20002:20002 delegation
  chmod 700 delegation

  # The signing key vouchryx issues delegation tokens with. Minted by
  # vouchryx's own reference client rather than by openssl here, because a
  # keygen tool built for a raw PEM would be this launcher holding an opinion
  # about vouchryx's own key format; reused on every later run, exactly like
  # every credential .env holds. `--user 0:0`: the image's own default user is
  # a distroless nonroot uid, which cannot create a file in a directory this
  # script just made 0700 for root, so the container runs as root to write it
  # and this script then hands the file to the uid vouchryx itself runs as,
  # the same shape init-volumes already uses for every volume in this file a
  # non-root plane has to write.
  #
  # Deliberately no `-kid`: vouchryx signs with the key's own RFC 7638
  # thumbprint, never a label a keygen run was given, so naming one here would
  # only mislabel a file nothing reads by that name.
  if [ ! -f delegation/signing.pem ]; then
    note "vouchryx: minting a signing key"
    docker run --rm --user 0:0 -v "$STACK_DIR/delegation:/out" \
        --entrypoint vouchryx-demo "${VOUCHRYX_IMAGE:-ghcr.io/taipanbox/vouchryx:v0.6.0@sha256:4a2b6b31be44b5391974785bdfca597a88bcc5ddd834d50830bd6b9537e9ab3d}" \
        keygen -out /out/signing >/dev/null \
      || die "could not mint vouchryx's signing key"
    chown 20002:20002 delegation/signing.pem delegation/signing.jwks.json
    chmod 600 delegation/signing.pem
  else
    note "vouchryx: signing key already present, reused"
  fi

  # The clearly-labelled demo issuer: a self-signed stand-in for the upstream
  # IdP a real deployment would point at instead, minted the same way the
  # signing key above is. Never a production posture, and never chosen unless
  # the operator names it explicitly (CLAUDE.md invariant 15).
  if [ -z "$VOUCHRYX_TRUSTED_ISSUERS" ] && [ -n "${WITH_DELEGATION_DEMO_ISSUER:-}" ]; then
    if [ ! -f delegation/idp.pem ]; then
      note "vouchryx: minting a demo issuer (WITH_DELEGATION_DEMO_ISSUER=1, never for production)"
      docker run --rm --user 0:0 -v "$STACK_DIR/delegation:/out" \
          --entrypoint vouchryx-demo "${VOUCHRYX_IMAGE:-ghcr.io/taipanbox/vouchryx:v0.6.0@sha256:4a2b6b31be44b5391974785bdfca597a88bcc5ddd834d50830bd6b9537e9ab3d}" \
          keygen -out /out/idp -kid stack-single-demo-idp >/dev/null \
        || die "could not mint the demo issuer key"
      chown 20002:20002 delegation/idp.pem delegation/idp.jwks.json
      chmod 600 delegation/idp.pem
    else
      note "vouchryx: demo issuer already present, reused"
    fi
    VOUCHRYX_TRUSTED_ISSUERS="$DEMO_ISSUER_NEW"
  fi
  demo_issuer_migrate .env
  if [ "$VOUCHRYX_TRUSTED_ISSUERS" = "$DEMO_ISSUER_OLD" ]; then VOUCHRYX_TRUSTED_ISSUERS="$DEMO_ISSUER_NEW"; fi
  add_env_default VOUCHRYX_TRUSTED_ISSUERS "$(sq_ "$VOUCHRYX_TRUSTED_ISSUERS")"

  add_env_default TOKENFUSE_DELEGATION_ISSUER http://vouchryx:4310
  # Empty accepts any audience, which tokenfuse's own docs call out as a real
  # choice, not a lesser one, for a single-tenant deployment - and a box this
  # launcher installs is exactly that: one operator's own fleet, not a
  # multi-tenant door serving several distinct audiences at once.
  add_env_default TOKENFUSE_DELEGATION_AUDIENCE ""
  add_env_default TOKENFUSE_DELEGATION_URL "http://$GATEWAY_PROBE:4100"
  add_env_default TOKENFUSE_DELEGATION_REVOCATIONS http://vouchryx:4310/v1/revocations
  add_env_default TOKENFUSE_DELEGATION_REVOCATIONS_INTERVAL_MS 12000
  # TOKENFUSE_DELEGATION_JWKS is deliberately NOT written here: its value has
  # to name a file this run actually produced, fetched from vouchryx's own
  # live /.well-known/jwks.json once it is running (section 5), never from
  # this keygen step's own output. Compose.yaml's comment on the gateway's own
  # environment block names the trap that guards against: vouchryx signs with
  # the key's thumbprint as `kid`, not whatever label a keygen run gave it.
fi

# image-verify: begin
# CLAUDE.md invariant 44. The images this project publishes are signed keyless by
# the release workflows of the TAIPANBOX repositories, by digest, with the job's
# GitHub OIDC identity, and carry a provenance attestation. Before this installer
# pulls one of them it checks that signature, and a signature that does not check
# stops the install before anything is started. Third-party images (busybox,
# postgres) are pinned by digest and are not signature-checked.
COSIGN_VERSION="v3.1.3"
# The SHA-256 of each cosign release binary, copied from that release's own
# cosign_checksums.txt. That file is signed by the sigstore release identity
# (keyless@projectsigstore.iam.gserviceaccount.com, issuer accounts.google.com),
# and the signature was checked before these values were copied.
# shellcheck disable=SC2034 # both are read by name, as ${!want}, in cosign_install below
COSIGN_SHA256_amd64="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"
# shellcheck disable=SC2034 # read by name, as ${!want}, in cosign_install below
COSIGN_SHA256_arm64="c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"
# A signature is accepted only from the release workflow of a TAIPANBOX repository
# (release.yml), or from the two image workflows of stack-k8s (console-image.yml and
# tunnel-images.yml), run on a version tag and signed through GitHub's own OIDC
# issuer. That is the identity stack-k8s's own admission policy names. Nothing
# wider: not another workflow file, not a branch, not another organisation.
TAIPANBOX_SIGNER='^https://github\.com/TAIPANBOX/(?:[A-Za-z0-9._-]+/\.github/workflows/release\.yml|stack-k8s/\.github/workflows/(?:console-image|tunnel-images)\.yml)@refs/tags/v[0-9][A-Za-z0-9._+-]*$'
TAIPANBOX_ISSUER='https://token.actions.githubusercontent.com'

cosign_install() {
  local arch want dest url
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "no pinned cosign for $(uname -m): image signatures are checked on amd64 and arm64 only" ;;
  esac
  want="COSIGN_SHA256_$arch"
  want="${!want}"
  dest="$STACK_DIR/bin/cosign"
  # A binary already in place with the pinned bytes is kept, so a re-run downloads nothing.
  if [ -f "$dest" ] && printf '%s  %s\n' "$want" "$dest" | sha256sum -c --status; then
    return 0
  fi
  url="https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-$arch"
  mkdir -p "$STACK_DIR/bin"
  note "fetching cosign $COSIGN_VERSION for $arch"
  # curl names the host that failed in its own message. The file is served by github.com,
  # which redirects it to release-assets.githubusercontent.com, so either can be the one.
  if ! fetch_err="$(curl -fsSL -o "$dest.download" "$url" 2>&1)"; then
    rm -f "$dest.download"
    die "could not download cosign $COSIGN_VERSION (needs outbound HTTPS to github.com and release-assets.githubusercontent.com; see README, \"What the install needs from the network\"). curl said: ${fetch_err%%$'\n'*}"
  fi
  # The bytes are checked before anything can run them. A download that does not match
  # the SHA-256 pinned above is removed and never installed.
  if ! printf '%s  %s\n' "$want" "$dest.download" | sha256sum -c --status; then
    rm -f "$dest.download"
    die "the cosign binary from $url does not match its pinned SHA-256, so it was not installed"
  fi
  chmod 0755 "$dest.download"
  mv -f "$dest.download" "$dest"
}

image_verify() {
  local ref="$1" out why name
  name="${ref%%@*}"
  # cosign's stderr is kept, so a refusal can say whether the image has no signature or
  # cosign could not reach the services that check one.
  if ! out="$("$STACK_DIR/bin/cosign" verify --certificate-identity-regexp "$TAIPANBOX_SIGNER" --certificate-oidc-issuer "$TAIPANBOX_ISSUER" "$ref" 2>&1 >/dev/null)"; then
    why="$(grep -i -m1 'error' <<<"$out" || printf '%s' "${out%%$'\n'*}")"
    if grep -qiE 'no matching signatures|no signatures found' <<<"$out"; then
      die "$name has no signature from a TAIPANBOX release workflow for its digest, so it was not pulled and the stack was not started"
    elif grep -qiE 'tuf|trusted root|trusted_root' <<<"$out"; then
      die "could not reach the Sigstore trust root at tuf-repo-cdn.sigstore.dev, so $name was not checked and was not pulled. This install needs outbound HTTPS to tuf-repo-cdn.sigstore.dev (see README, \"What the install needs from the network\"). cosign said: $why"
    elif grep -qi 'ghcr.io' <<<"$out"; then
      die "could not reach the registry ghcr.io to check $name, so it was not pulled. This install needs outbound HTTPS to ghcr.io. cosign said: $why"
    else
      die "could not check the signature of $name, so it was not pulled. cosign said: $why"
    fi
  fi
  note "signature verified: $name"
}
# image-verify: end

# ---- 3c. the images, pulled ---------------------------------------------------
# Here rather than in section 2, and the reason is mechanical: the list comes
# from `docker compose config`, which interpolates .env, and .env does not
# exist until section 3 has written it. Asked any earlier, compose refuses the
# whole file over the `:?` variables it is right to demand.
#
# Nothing is pulled when the operator asked to build instead: section 2 already
# produced the `stack/*:dev` tags, and pulling published images on top of them
# would download what this box was told not to use.
if [ -z "$BUILD_FROM_SOURCE" ]; then
  say "pulling published images"
  # Invariant 44: the cosign binary that checks our images is fetched and checked first.
  cosign_install
  # The list is READ from compose.yaml rather than repeated here. A tag bumped
  # in one place and forgotten in the other would pull one version and run
  # another, and the symptom is a container that works until it restarts.
  # `config` resolves the ${VAR:-default} forms and the profile switches, so
  # this is the same set docker will actually run.
  profiles=()
  [ -z "${WITH_BROWSER:-}" ] || profiles+=(--profile egress-browser)
  [ -z "${WITH_RECORD:-}" ]  || profiles+=(--profile record)
  [ -z "${WITH_EGRESS:-}" ]  || profiles+=(--profile egress)
  [ "$TYPED_PLANE" = off ]   || profiles+=(--profile typed)
  # The risk-signal proxy's image is the typryx image already pulled for the
  # typed profile, so this adds nothing to pull; it is named so that
  # `config --images` resolves the same set docker will run.
  if [ "$TYPED_PLANE" != off ] && [ "$TYPED_RISK_ON" = 1 ]; then profiles+=(--profile typed-risk-signal); fi
  if [ "${DELEGATION_ON:-0}" = 1 ]; then profiles+=(--profile delegation); fi
  # The OpenAI door runs the gateway's own image, so this adds nothing to pull;
  # named so that `config --images` resolves the same set docker will run.
  [ "$DOOR_ON" != 1 ] || profiles+=(--profile openai-door)
  pulled=0
  # The client keys are written in section 3e, after this pull, and compose refuses
  # to render a file whose gateway has none. So a first install gives this READ of
  # the configuration a stand-in that is never written anywhere or started with;
  # the image list does not depend on it. compose_image below does the same.
  while read -r img; do
    case "$img" in
      ghcr.io/*)
        # Every ghcr.io image here is one of ours, and each is checked before it is pulled.
        image_verify "$img"
        note "pulling $img"
        docker pull -q "$img" >/dev/null || die "could not pull $img"
        pulled=$((pulled + 1))
        ;;
    esac
  done < <(GATEWAY_CLIENT_KEYS="${GATEWAY_CLIENT_KEYS:-not-written-before-section-3e:none}" "${COMPOSE[@]}" "${profiles[@]}" config --images 2>/dev/null | sort -u)
  # A pull loop that pulled nothing is the failure this catches, and it is not
  # hypothetical: `config --images` printing an empty list, or every line
  # missing the `ghcr.io/` prefix after a rename, both leave every plane absent
  # while every line above still reads as success.
  [ "$pulled" -gt 0 ] || die "no ghcr.io image was pulled; compose named none. Is compose.yaml the one this installer shipped?"
  note "pulled $pulled published image(s); nothing was compiled"
fi

# ---- 3d. closing a retained reservation, opt-in ------------------------------
# A retained reservation is a call the provider may have billed that the
# gateway could not settle (tokenfuse invariant 50). A person closes one with
# evidence: the console mints a short-lived token after a passkey assertion,
# and the gateway verifies it. Both are keyed by ONE shared secret.
# WITH_CLOSURE=1 mints that secret once into .env as CLOSURE_SECRET, and writes
# the same bytes to ./closure/secret, readable by uid 10001 alone, for
# the console, with no trailing newline: the console trims whitespace from the
# file and the gateway reads its variable as given, so a newline on one side
# would make every token fail. Off by default: with no CLOSURE_SECRET in .env,
# compose hands both sides an empty value, which each reads as off. A re-run
# keeps the secret; turning closing off is removing CLOSURE_SECRET and
# CLOSURE_SECRET_FILE from .env. Invariant 26.
mkdir -p closure || die "could not create ./closure"
if [ "${WITH_CLOSURE:-}" = "1" ]; then
  add_env_default CLOSURE_SECRET "$(gen 48)"
  add_env_default CLOSURE_SECRET_FILE /run/closure/secret
  closure_secret="$(sed -n 's/^CLOSURE_SECRET=//p' .env | tail -n 1)"
  [ "${#closure_secret}" -ge 32 ] \
    || die "CLOSURE_SECRET in .env is shorter than 32 characters; remove that line and re-run with WITH_CLOSURE=1"
  ( umask 077; printf '%s' "$closure_secret" >closure/secret.tmp ) \
    || die "could not write the closure secret for the console"
  chown 10001:10001 closure/secret.tmp || die "could not hand the closure secret to the uid the console runs as"
  chmod 0400 closure/secret.tmp || die "could not set the mode of the closure secret"
  mv -f closure/secret.tmp closure/secret || die "could not move the closure secret into place"
  note "closing retained reservations is on: one secret, in .env and in ./closure/secret"
fi

# ---- 3e. client keys and the identity map, read by the gateway itself ---------
# Section 0f checked what a shell can check without a JSON parser. Here, with the
# gateway image on the box and nothing restarted yet, that image reads the pair
# this run will leave (section 0f says how and what is refused), and only then are
# the keys written to .env and the map moved into ./identity. The image is the one
# compose resolves for tokenfuse-gateway, so a BUILD_FROM_SOURCE box checks with
# the gateway it built. awk reads to the end rather than exiting early: an early
# exit is a SIGPIPE for compose under pipefail.
#
# With the OpenAI door on (section 0g), its own pair is read the same way by the
# image compose resolves for tokenfuse-gateway-openai, and the two maps are compared
# in the console's image, which has python3; only when every check has passed is
# anything written, for either door.
compose_image() { # SERVICE [compose options]: the image compose resolves for SERVICE
  local svc="$1"
  shift
  { GATEWAY_CLIENT_KEYS="${GATEWAY_CLIENT_KEYS:-not-written-before-section-3e:none}" "${COMPOSE[@]}" "$@" config 2>/dev/null || true; } \
    | awk -v want="  $svc:" '/^  [^ ]/{s=($0==want)} s&&/^    image: /&&!d{print $2; d=1}'
}
IDENTITY_IMAGE="$(compose_image tokenfuse-gateway)"
DOOR_IMAGE=""
DOOR_CHECK_IMAGE=""
if [ "$DOOR_ON" = 1 ]; then
  DOOR_IMAGE="$(compose_image tokenfuse-gateway-openai --profile openai-door)"
  DOOR_CHECK_IMAGE="$(compose_image console)"
fi
identity_door main
identity_check "$IDENTITY_IMAGE"
door_identity_check "$DOOR_IMAGE" "$DOOR_CHECK_IMAGE"
identity_apply
door_identity_apply
mint_apply
agent_static_keys_apply

# ---- 4. the files the services read -----------------------------------------
if [ ! -f policy.yaml ]; then
  cat > policy.yaml <<'EOF'
# Seeded scoped to fire-drill identities only, so a fresh box denies something
# real without touching a live fleet. Replace with your own.
#
# agent://mockryx.local/*, not agent://drill.local/*: this file and
# stack-k8s's equivalent had drifted onto "drill.local" while stack-up and
# taipan both seed "mockryx.local" for the identical rehearsal identity.
# Aligned here on mockryx.local because it names the actual tool that
# generates this traffic (mockryx), matching the convention every other
# agent://<component>.local/* identity in this stack already follows.
- name: starter-require-human-approval
  target: agent://mockryx.local/*
  require_human_above_usd: 1
# The allow-list rehearsal identity: under Wardryx v1.3.0's allow_tool, the one
# tool this identity may call is lookup_order_status; every other tool is denied.
- name: mockryx-allow-list
  target: "agent://mockryx.local/allow-list-rehearsal"
  allow_tool:
    - lookup_order_status
- name: starter-deny-shell-exec
  target: agent://mockryx.local/*
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
# Unconditionally, like environments/ above, whether or not WITH_DELEGATION is
# set: the gateway's own compose block always bind-mounts this directory (so
# TOKENFUSE_DELEGATION_JWKS names a path that exists once delegation is
# turned on without a second `docker compose up` to create the mount point),
# and a box that never asks for delegation gets an empty directory here, the
# same as an install with no console gets an unused environments/.
mkdir -p delegation delegation-public
chown 20002:20002 delegation
chmod 700 delegation
# The gateway's side: only the JWKS vouchryx SERVES, public by definition,
# readable by the gateway's own uid (10001) and never next to a private key.
chmod 755 delegation-public

# ---- 4b. a bind on one address, made to survive a reboot ---------------------
# A gateway published on ONE address depends on the host holding that address
# at the moment Docker starts, and after a reboot it may not. Measured
# 2026-09-17 on a box whose GATEWAY_BIND was its tailscale address:
# docker.service became active two seconds after tailscaled, before tailscale0
# carried the address, the port bind failed, the gateway ended `Exited (128)`
# with "driver failed programming external connectivity", and `unless-stopped`
# never retries a container whose START failed. A later `up -d` printed
# `Started` for a container with no port mapping at all, until
# `--force-recreate`. The agent in flight got 44 refused connections in 2.5
# minutes (#56).
#
# Two things put it right, proven by a second reboot (published, healthz 200,
# within 40 s). `ip_nonlocal_bind` lets Docker's proxy bind an address the
# host does not hold yet, so the mapping exists from the first start and
# traffic flows the moment the address arrives. And when tailscaled is what
# provides addresses on this box, docker.service is ordered after it (Wants=
# as well as After=, so a docker start pulls tailscaled up with it). Written
# on every run, the same bytes each time, and only for a bind that is one
# address: loopback and 0.0.0.0 are always there. A write that fails is a
# refusal with the reason, not a box that looks installed until it reboots.
case "$GATEWAY_BIND" in
  127.0.0.1|localhost|::1|0.0.0.0) ;;
  *)
    say "bind on $GATEWAY_BIND, made to survive a reboot"
    mkdir -p /etc/sysctl.d || die "could not create /etc/sysctl.d"
    printf 'net.ipv4.ip_nonlocal_bind = 1\n' > /etc/sysctl.d/90-agent-stack-bind.conf \
      || die "could not write /etc/sysctl.d/90-agent-stack-bind.conf: a gateway bound to $GATEWAY_BIND would not come back after a reboot"
    sysctl -q -p /etc/sysctl.d/90-agent-stack-bind.conf \
      || die "could not apply net.ipv4.ip_nonlocal_bind=1: a gateway bound to $GATEWAY_BIND would not come back after a reboot"
    note "net.ipv4.ip_nonlocal_bind = 1, from /etc/sysctl.d/90-agent-stack-bind.conf"
    if systemctl cat tailscaled.service >/dev/null 2>&1; then
      mkdir -p /etc/systemd/system/docker.service.d \
        || die "could not create /etc/systemd/system/docker.service.d"
      printf '[Unit]\nAfter=tailscaled.service\nWants=tailscaled.service\n' \
        > /etc/systemd/system/docker.service.d/10-after-tailscaled.conf \
        || die "could not write the docker.service drop-in: docker would start before tailscaled holds $GATEWAY_BIND"
      systemctl daemon-reload \
        || die "systemctl daemon-reload failed after writing the docker.service drop-in"
      note "docker.service starts after tailscaled.service (drop-in 10-after-tailscaled.conf)"
    fi
    ;;
esac

# ---- egress: the routes out that a box's own choices need ------------------
# egress-override: begin
# compose.yaml puts every service on a network that matches its job, and only
# the services that need a provider sit on edge, the one network with a route
# out. The typryx service and its typed risk signal proxy need edge only when
# TYPED_MODE names a provider (jev, own-model). Compose cannot make a membership
# conditional, so that choice is written here as compose.override.yaml, which
# compose v2 reads beside compose.yaml on every command, and removed when the
# choice is not made (CLAUDE.md invariant 38). The first line says the file is
# ours, so only this installer ever removes it. A file somebody else wrote is
# refused, before `up`, when this box needs one; it is left alone otherwise.
egress_override() { # $1: the stack directory. Reads TYPED_MODE.
  local dir="$1" f="$1/compose.override.yaml" marker='# written by install.sh'
  local typed=0
  case "${TYPED_MODE:-}" in jev | own-model) typed=1 ;; esac
  if [ "$typed" = 0 ]; then
    if [ -f "$f" ]; then
      case "$(head -n1 "$f")" in "$marker"*) rm -f "$f" ;; esac
    fi
    return 0
  fi
  if [ -f "$f" ]; then
    case "$(head -n1 "$f")" in "$marker"*) ;; *)
      die "$dir/compose.override.yaml is not ours (no '$marker' first line), and this box needs a route out for typryx. Move it aside or set TYPED_MODE=stub. Nothing was started."
      ;;
    esac
  fi
  {
    echo "$marker from .env on every run (CLAUDE.md invariant 38). Rewritten or removed each run; do not edit."
    echo "# It adds the network edge, the one route out, to the services named below and to no other."
    echo "services:"
    if [ "$typed" = 1 ]; then
      echo "  typryx:"
      echo "    networks: [edge]"
      echo "  typryx-wardryx-proxy:"
      echo "    networks: [edge]"
    fi
  } >"$f.tmp" && mv "$f.tmp" "$f"
}
# egress-override: end

# ---- 5. up ------------------------------------------------------------------
say "starting the stack"
UP_PROFILES=()
# The typed plane is the one profile this launcher brings up automatically
# when asked, rather than leaving it for a second manual command the way
# `egress` and `record` do. Section 8 below verifies the broker answers and
# refuses a caller with no key, and a check that verifies a service nothing
# started would be verifying nothing.
[ "$TYPED_PLANE" = off ]      || UP_PROFILES+=(--profile typed)
# The typed risk signal (TYPED_RISK_SIGNAL=1) starts the proxy beside the broker
# it serves, and only with typed answers on: a flag with no typryx was refused
# in section 0b, and a saved flag is inert while typed answers are off.
if [ "$TYPED_PLANE" != off ] && [ "$TYPED_RISK_ON" = 1 ]; then UP_PROFILES+=(--profile typed-risk-signal); fi
if [ "${DELEGATION_ON:-0}" = 1 ]; then UP_PROFILES+=(--profile delegation); fi
# The OpenAI door (OPENAI_DOOR=1, section 0g) is started like the typed plane, so
# section 8 can ask it the questions it asks the gateway.
[ "$DOOR_ON" != 1 ] || UP_PROFILES+=(--profile openai-door)

# Delegation needs a head start, the same reason `stack-up` starts vouchryx
# before its own gateway (README, "Delegation: a proved chain"): the gateway
# reads TOKENFUSE_DELEGATION_JWKS once, at startup, and that file has to hold
# vouchryx's OWN live keys, fetched from its running `/.well-known/jwks.json`,
# never vouchryx-demo's own keygen output (the `kid` trap named on the
# gateway's own compose block). So vouchryx comes up alone first, this run
# fetches its JWKS onto disk, and only then does the gateway start for the
# first time with that file already in place.
if [ "${DELEGATION_ON:-0}" = 1 ]; then
  say "vouchryx"
  "${COMPOSE[@]}" --profile delegation up -d vouchryx
  # Not published to the host (compose.yaml's own comment on the vouchryx
  # service says why), so this is fetched from inside the compose network,
  # the same throwaway-busybox shape section 8 uses for every other
  # container-side probe here. `agent-stack_core`: the fixed network name
  # `name: agent-stack` in compose.yaml produces, the same literal section 8
  # uses as `$NET`.
  fetched=0
  left=15
  while [ "$left" -gt 0 ]; do
    if docker run --rm --network agent-stack_core busybox:1.36 wget -q -T5 -O - \
         http://vouchryx:4310/.well-known/jwks.json >delegation-public/vouchryx.jwks.json.tmp 2>/dev/null \
       && [ -s delegation-public/vouchryx.jwks.json.tmp ]; then
      fetched=1
      break
    fi
    sleep 1; left=$((left - 1))
  done
  if [ "$fetched" -ne 1 ]; then
    rm -f delegation-public/vouchryx.jwks.json.tmp
    die "vouchryx did not answer /.well-known/jwks.json within 15s. WITH_DELEGATION=1 asked for a \
verified chain and nothing came up to verify it against. Check: ${COMPOSE[*]} logs vouchryx"
  fi
  mv delegation-public/vouchryx.jwks.json.tmp delegation-public/vouchryx.jwks.json
  chmod 644 delegation-public/vouchryx.jwks.json
  # A file path INSIDE the gateway's own container, not the host path above:
  # compose.yaml bind-mounts ./delegation-public there read only. Written here,
  # after the fetch succeeded, rather than earlier alongside this run's other
  # TOKENFUSE_DELEGATION_* defaults, because a value naming a file that does
  # not exist yet would be worse than the variable staying unset (the
  # gateway's own chainproof::base_config_from_env aborts rather than starting
  # with a JWKS it cannot read).
  add_env_default TOKENFUSE_DELEGATION_JWKS /etc/tokenfuse/delegation/vouchryx.jwks.json
  # shellcheck disable=SC1091  # generated at install time, not in this repo
  . ./.env
  gateway_probe_resolve
fi

# The routes out this box's own choices need (invariant 38), written before `up`
# reads the files. A refusal here is before any container starts.
egress_override .
"${COMPOSE[@]}" "${UP_PROFILES[@]}" up -d --remove-orphans
# `up --remove-orphans` does not remove a container whose profile this run does
# not name (measured 2026-10-04 on Docker Desktop's compose v2: a proxy started
# under typed-risk-signal kept running through an `up` without it). So turning
# the signal off, or typed answers off, has to remove the proxy by name, or "off"
# would leave it running beside a broker that no longer points at it. A box that
# never had one has nothing to remove, which is why the failure is ignored.
if [ "$TYPED_PLANE" = off ] || [ "$TYPED_RISK_ON" != 1 ]; then "${COMPOSE[@]}" --profile typed-risk-signal rm -sf typryx-wardryx-proxy >/dev/null 2>&1 || true; fi
# The same for the OpenAI door: off, or never asked for, it is removed by name, or
# "off" would leave it answering on 4110. A box that never had one has nothing to
# remove, which is why the failure is ignored.
if [ "$DOOR_ON" != 1 ]; then "${COMPOSE[@]}" --profile openai-door rm -sf tokenfuse-gateway-openai >/dev/null 2>&1 || true; fi
# The gateway reads its identity map once, at start, and a new map behind the same
# GATEWAY_IDENTITY_MAP line changes nothing compose compares, so `up` above left
# the old map in force. A map this run installed is read only after a restart.
if [ "$IDENTITY_MAP_CHANGED" = 1 ]; then
  "${COMPOSE[@]}" restart tokenfuse-gateway >/dev/null \
    || die "could not restart the gateway to read the new identity map"
  note "gateway restarted to read the new identity map"
fi
# And the OpenAI door's own map, for the same reason.
if [ "$DOOR_ON" = 1 ] && [ "${IDENTITY_openai_MAP_CHANGED:-0}" = 1 ]; then
  "${COMPOSE[@]}" --profile openai-door restart tokenfuse-gateway-openai >/dev/null \
    || die "could not restart the OpenAI door to read its new identity map"
  note "OpenAI door restarted to read its new identity map"
fi
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
[ "$DOOR_ON" != 1 ] || note "and 4110 (the OpenAI door), on the gateway's own bind ($GATEWAY_BIND) and no wider"
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
if compose_has console; then
  say "console account"
  if "${COMPOSE[@]}" exec -T console test -s /var/lib/stack/.taipan/genaryx-web/operator.json >/dev/null 2>&1; then
    note "an operator already exists, left as is"
  else
    CONSOLE_PASSWORD="$(gen 28)"
    if printf '%s\n' "$CONSOLE_PASSWORD" | "${COMPOSE[@]}" exec -T console \
         /usr/local/bin/genaryx-web set-password --username "$CONSOLE_USER" >/dev/null 2>&1; then
      note "created operator '$CONSOLE_USER'"
      # A console older than v1.1.36 reads whether it has an operator once, at
      # startup (stack-k8s GOTCHAS 50), and it is already running here, so
      # until it restarts it refuses the password printed below with 503. The
      # pinned console (v1.1.36 or later, genaryx#106) picks the operator up at the next
      # sign-in on its own; the restart stays for a CONSOLE_IMAGE set to an
      # older one, and costs a few seconds otherwise.
      "${COMPOSE[@]}" restart console >/dev/null \
        || die "could not restart the console after creating its operator"
    else
      CONSOLE_PASSWORD=""
      note "could not set the password automatically; the command is printed below"
    fi
  fi
fi

# ---- 8. does it actually work -------------------------------------------------
say "verify"
fail=0
stack_checks                                 # the checks, below: section 8 runs them here

# ---- 8b. your first device ---------------------------------------------------
# With GENARYX_WEB_REQUIRE_PASSKEY=1 (compose.yaml), the five sensitive console
# commands refuse on a session cookie alone until a passkey is enrolled, and
# enrolment can only happen at https://$CONSOLE_DOMAIN over the tunnel:
# GENARYX_WEB_ORIGIN is that exact name, and WebAuthn refuses to enrol against
# any other origin, including an SSH port-forward to localhost. So the FIRST
# device cannot come from the browser (it needs a passkey, and none exists
# yet) and cannot come from enrolling one either (wrong origin over SSH).
# Somebody has to hand out the first device from outside the browser, and the
# only channel that exists before a tunnel does is this installer itself.
# stack-k8s's tunnel/up.sh solves the identical problem the identical way.
#
# Only when the tunnel and the console's UAPI access already checked out
# above: issuing a device this box cannot dial anywhere is not a step worth
# taking. Skipped with FIRST_DEVICE=0 on a re-run, or when the config already
# exists: a second run should not mint a peer nobody asked for, and existing
# devices are never touched either way.
if compose_has console; then
  CONF_OUT="$STACK_DIR/${CONSOLE_DOMAIN}.conf"
  if [ -s "$CONF_OUT" ]; then
    note "first device already issued: $CONF_OUT, left as is"
  elif [ "${FIRST_DEVICE:-1}" = "0" ]; then
    note "FIRST_DEVICE=0: skipping first-device issuance"
  else
    say "your first device"
    # stdout is the config and stderr is the QR plus the notes, so the redirect
    # saves the file and the QR still reaches the terminal.
    #
    # umask in a subshell, not chmod afterwards. This file carries the device's
    # private key from the moment the first byte lands, and a chmod after the
    # redirect leaves it world-readable for however long the write takes.
    if ( umask 077
         "${COMPOSE[@]}" exec -T console /usr/local/bin/genaryx-web issue-device --no-color \
           >"$CONF_OUT.tmp" 2>"/tmp/issue-device.$$" ); then
      mv "$CONF_OUT.tmp" "$CONF_OUT"
      cat "/tmp/issue-device.$$" >&2
      rm -f "/tmp/issue-device.$$"
      note "saved to $CONF_OUT (mode 0600)"
    else
      rm -f "$CONF_OUT.tmp"
      sed 's/^/   /' "/tmp/issue-device.$$" >&2
      rm -f "/tmp/issue-device.$$"
      # Not `die`: the rest of the install is sound, and an operator can run
      # this by hand once they want the first device. Printing the exact
      # command is the point, not just the fact that it failed.
      note "could not issue the first device automatically. The rest of the box"
      note "is fine. Run it yourself when you are ready:"
      note "  cd $STACK_DIR && ${COMPOSE[*]} exec console genaryx-web issue-device"
    fi
  fi
fi

# The notes below are the install's own output. The checks above are shared with status.
if compose_has tokenfuse-mcp-broker; then
  say "the typed plane, through tokenfuse's MCP broker"
  note "an agent reaches typryx at http://<this box>:4200/mcp ($GATEWAY_BIND unless you widen it)"
  note "  with the header X-Fuse-Mcp-Upstream: typryx, its own client key in x-fuse-key, and its"
  note "  agent id in x-fuse-agent-id: the broker asks wardryx about every tools/call (policy.yaml"
  note "  judges tool calls too), refuses one it cannot attribute, and refuses when wardryx cannot answer"
  note "  a tools/call carries the typed-plane credential as"
  note "  \"_meta\":{\"typryx/key\":\"{{secret:typryx_key}}\"}, never a real key value: a raw secret"
  note "  in tool arguments is refused, and so is a tool listing the broker's scanner flags"
  if [ "$TYPED_RISK_ON" = 1 ]; then
    note "the typed risk signal is ON: the broker asks wardryx through typryx's proxy, which adds the"
    note "  call's risk class. Nothing holds a call for a person until you add a hold_if_signal rule"
    note "  to policy.yaml (README)."
  fi
  case "$TYPED_PLANE" in
    stub)      note "answers come from the stub backend: nothing leaves this box" ;;
    jev)       note "answers come from Jev: the fields each question names leave this box for api.typesafe.ai" ;;
    own-model) note "answers come from your own model at $TYPED_URL: nothing else leaves this box" ;;
  esac
  if grep -q '^TYPRYX_TRAINING_DIR=' "$STACK_DIR/.env" 2>/dev/null; then
    note "the local training log is on, on this box only: post a human truth for an answer to /v1/outcome,"
    note "  then run typryx export --training in the typryx container (README: Your own model, on your own data)"
  fi
fi

if compose_has vouchryx; then
  say "delegation"
  note "vouchryx issues delegation tokens and answers revocations on the compose"
  note "  network only, never published to the host (see the service's own comment"
  note "  in compose.yaml). The gateway polls its revocations at"
  note "  http://vouchryx:4310/v1/revocations and verifies a chain against the JWKS"
  note "  this run fetched from it, at $STACK_DIR/delegation-public/vouchryx.jwks.json."
  note "  POST /v1/revoke needs VOUCHRYX_REVOKE_KEYS from .env as a bearer key, and"
  note "  reaches vouchryx only from inside this compose network, the same way an"
  note "  operator revokes a policy plane key today: from a container on it, not the host."
fi

# The test message, but only on the run that CONFIGURED mail. A re-run must not
# post a message every time somebody upgrades the box, and a re-run is also the
# one case where the settings were already proven once.
#
# Sent from inside the container, which is the point: it proves that container's
# own network path and those credentials, not this shell's. A wrong setting
# caught here costs a minute. Caught the way it is otherwise caught, through an
# alert that never arrived, it costs whatever the alert was about.
if [ "$ALERT_CONFIGURED_NOW" = 1 ]; then
  say "notifications"
  if "${COMPOSE[@]}" exec -T heraldyx /usr/local/bin/service --test-mail 2>&1 | sed 's/^/  /'; then
    note "if that message does not arrive, the address or the server is wrong."
    note "Nothing else on this box depends on it."
  else
    note "the test message did NOT go out. The stack is fine and unaffected."
    note "Check ALERT_TO, SMTP_HOST and the credentials in $STACK_DIR/.env, then:"
    note "  cd $STACK_DIR && ${COMPOSE[*]} logs heraldyx"
    note "  cd $STACK_DIR && ${COMPOSE[*]} exec heraldyx /usr/local/bin/service --test-mail"
  fi
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

# Which headers an agent sends, once client keys or an identity map are on. The
# secrets are named by where they live, never printed.
IDENTITY_REACH=""
if [ "$IDENTITY_MINTED" = 1 ]; then
  IDENTITY_REACH="$(mint_reach_note)"
elif [ "$IDENTITY_KEYS_COUNT" -gt 0 ]; then
  IDENTITY_REACH="
  Client keys are ON ($IDENTITY_KEYS_COUNT): every call carries its agent's own key in the
  x-fuse-key header (the secret on its line of the keys file you gave; it is in
  $STACK_DIR/.env as GATEWAY_CLIENT_KEYS and is not printed here), and
  x-fuse-run-id. A call without a key, or with one the gateway does not hold, is
  refused 401."
  if [ "$IDENTITY_MAP_ON" = 1 ]; then
    IDENTITY_REACH="$IDENTITY_REACH
  The identity map is ON: each call also names its agent in x-fuse-agent-id, an id
  the map binds to that key, or it is refused 403 identity_mismatch. Its spend
  lands in the unit the map binds the key to."
  fi
fi
# The gateway always holds client keys now (compose requires them), so the branch
# for a map with no keys, which used to follow, is gone with it.
IDENTITY_REACH="$IDENTITY_REACH$(felyx_gateway_note)$(upstream_reach_note)$(agent_tokens_reach_note)"

# The OpenAI door, when this box runs it: where an agent points, what it sends,
# who pays, and what this box does not see of it. Its keys are named by where they
# live, never printed.
DOOR_REACH=""
if [ "$DOOR_ON" = 1 ]; then
  DOOR_REACH="

  The OpenAI door is ON (port 4110, on the gateway's bind). An agent whose SDK
  speaks the OpenAI wire sets its base URL to http://<this box>:4110/v1, and the
  door forwards each call to $DOOR_UPSTREAM.
  The agent sends its OWN provider key as Authorization, and the door passes it on:
  a metered upstream bills whoever's key that is. Every call also carries
  x-fuse-key (a secret from the door's own keys file, kept in .env as
  OPENAI_DOOR_CLIENT_KEYS and not printed here), x-fuse-agent-id (an id the door's
  map binds to that key) and x-fuse-run-id. Its units are counted by the door
  alone; its traces are not in the FOCUS export, and the console shows the
  gateway's runs, not the door's (README, \"A second door on the OpenAI wire\")."
fi

# The report below uses A && echo X || echo Y inside a substitution. C is `echo`,
# which does not fail, so it is a plain ternary rather than the trap SC2015 warns
# about. It cannot be silenced inside the heredoc: text in there is printed, not
# parsed as comments.
# shellcheck disable=SC2015
cat <<EOF

$(printf '\033[1m')$([ "$fail" -eq 0 ] && echo "Up, and every check passed." || echo "Up, with $fail failed check(s) above.")$(printf '\033[0m')

$REACH$IDENTITY_REACH$DOOR_REACH

${CONSOLE_PASSWORD:+  Console sign-in, shown once and stored nowhere:

      user      $CONSOLE_USER
      password  $CONSOLE_PASSWORD

}  The console is on loopback by design, so it is reached over a tunnel. This
  box runs the WireGuard side and issues your device its own peer config:
  sign in, open Remote, and take the QR. The config is shown once.

      console  https://$CONSOLE_DOMAIN   (once your tunnel is up)
      tunnel   $WG_ENDPOINT_HOST:${WG_LISTEN_PORT:-51820}/udp
$CONSOLE_ACCESS_NOTE

  Clearing a run's taint label (POST /v1/fuse/declassify on the gateway) needs
  its own key, GATEWAY_DECLASSIFY_KEY in $STACK_DIR/.env, sent as the
  x-fuse-declassify-key header. It is not the console or admin key, and it is
  not printed here.

  The gateway clamps the budget a caller declares for one run (the
  x-fuse-budget-usd header, or a policy's default) to ${RUN_BUDGET_CEILING_USD:-5.00} USD,
  so an agent cannot give its own run a bigger one. A budget set in the Cloud
  is yours and is never clamped. To move it, set RUN_BUDGET_CEILING_USD in
  $STACK_DIR/.env (a positive number of dollars, at most six decimals) and run
  ${COMPOSE[*]} up -d. It bounds one run, not an agent: a new run id starts a new one.

  The gateway's agent firewall runs in enforce: when a run has read untrusted
  input and the model then asks for an exec, write or network-egress action, the
  answer is withheld (HTTP 403, taint_blocked). To run it in shadow (record only)
  or off instead, set TOKENFUSE_FIREWALL to shadow or off in $STACK_DIR/.env and
  run ${COMPOSE[*]} up -d tokenfuse-gateway. Running ./install.sh with the same
  variable checks the value before it writes it.

  A chain verifier (agent-conform) re-checks the hash chain of every event
  stream on this box every five minutes. A break becomes a high alert on the
  same bus your notifier already reads. It can write one file, its own, and
  nothing else on the bus.

  Killing a run, setting a budget, deciding an approval, and issuing or
  revoking a device all need a passkey: a road into the control plane is not
  something a stolen session should be able to mint quietly. That passkey can
  only be enrolled at https://$CONSOLE_DOMAIN over the tunnel, so the sequence
  for your first session is:

      1. import $STACK_DIR/$CONSOLE_DOMAIN.conf (or scan the QR this run
         printed above) into your WireGuard client, and connect
      2. open https://$CONSOLE_DOMAIN, trusting this box's own CA first if
         no CLOUDFLARE_API_TOKEN was set (see above)
      3. sign in with the password above
      4. enrol a passkey under Session > Passkeys

  Only after step 4 do kill, budget, approval and device commands work. A
  passkey cannot be enrolled over the SSH forward below: WebAuthn checks the
  origin, and that forward is http://localhost, never $CONSOLE_DOMAIN.

  SSH stays as the way to read the console before the tunnel exists, not to
  act on it:

      ssh -L 17420:127.0.0.1:7420 root@$PUBLIC_IP
      open http://localhost:17420

  Manage it:

      cd $STACK_DIR && ${COMPOSE[*]} ps
      cd $STACK_DIR && ${COMPOSE[*]} logs -f tokenfuse-gateway
      cd $STACK_DIR && ${COMPOSE[*]} down     # stop, keeping every volume

  Nothing on this box runs the governance routines (FinOps export, crypto
  trend, quality drift, identity sweep) on a schedule. Run one by hand with
  ${COMPOSE[*]} exec, or see the README for how stack-up and stack-k8s do it.

EOF
# The banner above already said what failed, so the trap must not narrate a
# non-zero exit here as if the script had crashed: it ran to the end.
EXPLAINED=1
# C here is `echo`, which does not fail, so the branch is a plain ternary.
# shellcheck disable=SC2015
exit "$([ "$fail" -eq 0 ] && echo 0 || echo 1)"
