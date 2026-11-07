#!/usr/bin/env bash
# Enforces that `./install.sh status` checks an installed stack and changes nothing.
#
# WHY
#
# `status` runs the same verification list section 8 runs, against a stack that is
# already up. An operator who runs it on a production box has to be able to trust
# that it is only a read: no package, no image pull, no container started, stopped or
# removed, no file written on the bus, no request that the stack records (a metered
# call refused at the gate, a typed question sent to a backend). The list is shared
# with the install, so a check that is wrongly moved onto the status path changes the
# box silently, and nothing in the install's own output would show it.
#
# HOW
#
# Nothing is installed here. The gate runs `install.sh status` against a sandbox
# STACK_DIR with a .env that holds two client keys, on a PATH whose docker, curl,
# apt-get and systemctl are STUBS that log every call and answer as a healthy stack
# would. The stub docker reads its service list from compose.yaml, so the set of
# services is the repository's, not a copy. Then it reads the log:
#
#   1. on a stack that is there the run ends 0 (every check passed) or 1 (some failed)
#      and prints one line per check it ran, and it reaches the drift check's reads;
#   2. no call that changes the stack: no compose up, down, pull, build, start, stop,
#      restart, rm, kill, create, cp or commit; no exec of the first-device command;
#      no apt-get, systemctl, ufw or cosign; no docker verb outside the list of reads;
#      no `docker run` that writes (a `>` or `>>` in its argument list) and no POST
#      body except the read-only tools/list;
#   3. a status run on a directory with no .env ends 2 (could not measure), names the
#      fact, and makes no docker call at all;
#   4. a Docker that does not answer, and a stack whose network is gone, each end 2,
#      name the fact and run no check: "could not read it" is not "it failed", and it
#      must never come out as 0.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# A run that printed no check line, or a stub that was never called, is reported as
# measuring nothing, not as a pass.
#
# (teeth cases: scripts/gates-have-teeth.sh, "status-is-read-only: ...")
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ ! -f install.sh ] || [ ! -f compose.yaml ]; then
	echo "FAIL: install.sh or compose.yaml is not there, so status measured NOTHING."
	exit 1
fi
if ! grep -q 'if \[ "\${1:-}" = status \]; then status_main; fi' install.sh; then
	echo "FAIL: install.sh has no status entry point, so there is nothing to check."
	exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/status-gate.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/stack" "$SANDBOX/empty"
LOG="$SANDBOX/calls.log"
: >"$LOG"
export LOG

# The services the stub reports are the ones compose.yaml declares.
grep -E '^  [a-z0-9-]+:$' compose.yaml | sed -E 's/^  //; s/:$//' | sort -u >"$SANDBOX/services"
export SERVICES_FILE="$SANDBOX/services"
# Touched by the cases below: a Docker that does not answer, a stack with no network.
export DOWN_FILE="$SANDBOX/docker-is-down"
export NO_NETWORK_FILE="$SANDBOX/no-network"

# The log lines every log check looks for. A healthy gateway, console and verifier.
cat >"$SANDBOX/logs" <<'EOF'
tokenfuse: NDJSON export enabled
tokenfuse: run budget ceiling: a caller-declared or default budget is clamped to it
tokenfuse: client auth: ON (2 key(s))
tokenfuse: identity map: ON (2 binding(s))
tokenfuse gateway listening
tokenfuse: serving one door on /v1/chat/completions
genaryx-web: bus LIVE
PASS wardryx.ndjson
EOF
export LOGS_FILE="$SANDBOX/logs"

cat >"$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$LOG"
# A request the installer writes to a container's stdin (docker run -i, the request
# helper in install.sh) is logged as one line: its method, path and body.
case " $* " in
  *" -i "*) printf 'docker-request %s\n' "$(cat | tr '\r\n' '  ')" >>"$LOG" ;;
esac
case "${1:-}" in
  compose)
    shift
    case "${1:-}" in
      version) exit 0 ;;
      --profile)
        # The drift check's one read of the pins: a render of the services this stub reports.
        [ ! -f "$DOWN_FILE" ] || exit 1
        printf 'name: agent-stack\nservices:\n'
        sed -E 's/^(.*)$/  \1:\n    image: ghcr.io\/taipanbox\/\1:v1@sha256:aaaa\n    restart: unless-stopped/' "$SERVICES_FILE"
        printf 'networks:\n  core:\n    name: agent-stack_core\n'
        exit 0 ;;
      ps)
        case " $* " in
          *" --services "*) cat "$SERVICES_FILE" ;;
          *) printf 'abc123\n' ;;
        esac
        exit 0 ;;
      logs) cat "$LOGS_FILE"; exit 0 ;;
      port) printf '127.0.0.1:4100\n'; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  version) [ ! -f "$DOWN_FILE" ] || exit 1; exit 0 ;;
  network)
    [ ! -f "$NO_NETWORK_FILE" ] || exit 1
    case "${2:-}" in
      ls) printf 'n1\n' ;;
      inspect) case " $* " in *" --format "*) printf 'agent-stack_core|\n' ;; esac ;;
    esac
    exit 0 ;;
  ps) printf 'c1\n'; exit 0 ;;
  inspect) printf 'c1|wardryx|False|/agent-stack-wardryx-1|sha256:cc|running|0|0|true|512|[ALL]|[no-new-privileges:true]\n'; exit 0 ;;
  image) printf 'ghcr.io/taipanbox/wardryx@sha256:aaaa \n'; exit 0 ;;
  port) printf '127.0.0.1:4100\n'; exit 0 ;;
  run) printf 'HTTP/1.0 200 OK\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat >"$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$LOG"
printf '{"configured":true}\n'
exit 0
STUB
for tool in apt-get systemctl ufw sysctl cosign; do
	cat >"$SANDBOX/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"\$LOG"
exit 0
STUB
done
chmod +x "$SANDBOX"/bin/*

cat >"$SANDBOX/stack/.env" <<'EOF'
GATEWAY_BIND='127.0.0.1'
GATEWAY_ADMIN='admin-secret-for-the-gate'
WARDRYX_ADMIN='wardryx-admin-for-the-gate'
WARDRYX_GATEWAY='wardryx-gateway-for-the-gate'
GATEWAY_CLIENT_KEYS='secret-one:key-one,secret-two:key-two'
GATEWAY_IDENTITY_MAP=/etc/tokenfuse/identity/identity.json
CONSOLE_DOMAIN='console.example.internal'
EOF

# A journal: status reads it, prints one line from it, and leaves it byte for byte.
printf '2026-11-09T06:18:44Z good version=1.7.0 index=1 commit=abc1234\n' >"$SANDBOX/stack/.install-history"
journal_before="$(cksum <"$SANDBOX/stack/.install-history")"

fail=0
report() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# 1. A run on a stack that is there: the checks run, the verdict is 0 or 1, and
#    nothing that changes the stack is called.
out="$SANDBOX/out"
set +e
(cd "$ROOT" && PATH="$SANDBOX/bin:$PATH" STACK_DIR="$SANDBOX/stack" bash ./install.sh status >"$out" 2>&1)
rc=$?
set -e
lines=$(grep -cE '^   (ok|FAIL|skip) ' "$out" || true)
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
	report "status exited $rc on a stack that is there, not 0 (every check passed) or 1 (a check failed)"
	sed 's/^/        /' "$out" | head -20
elif [ "$lines" -lt 20 ]; then
	report "status printed $lines check line(s); the list has about 40, so the run did not reach its checks"
	sed 's/^/        /' "$out" | head -20
elif ! grep -qE '^(every check passed|[0-9]+ check\(s\) failed)$' "$out"; then
	report "status printed no verdict line"
fi
# The stub stack never passes every check, so the success line is only ever read here as
# text: a reworded success verdict would go unseen by the run above.
if ! grep -qF "\\nevery check passed\\n'; exit 0" install.sh; then
	report "install.sh does not print the success verdict, so a passing run would say nothing"
fi
if ! grep -q 'docker compose ps --services' "$LOG"; then
	report "status never read the service list, so the stub was never reached and this measured nothing"
fi
# The drift check's reads are in the log, or this gate did not see them being reads.
for read in 'docker compose --profile \* config' 'docker ps -a' 'docker inspect --format' 'docker image inspect' 'docker network ls' 'docker network inspect --format'; do
	if ! grep -q "^$read" "$LOG"; then
		report "status never made the read '$read', so the drift check was not measured here"
	fi
done

# The calls that change a stack, or that a stack records.
changes() {
	grep -E '^docker compose (up|down|pull|build|start|stop|restart|rm|kill|create|cp|commit|push)( |$)' "$LOG" || true
	grep -E 'issue-device|--test-mail' "$LOG" || true
	grep -E '^(apt-get|systemctl|ufw|sysctl|cosign) ' "$LOG" || true
	# Everything else docker can do is a list of what status may ask, not a list of what it may not.
	grep -E '^docker ' "$LOG" | grep -vE '^docker (compose|run|port|version|ps|inspect|network (inspect|ls)|image inspect)( |$)' || true
	grep -E '^docker run .*(>>|[^-]> )' "$LOG" || true
	# A POST is refused, except the broker's read-only tools/list (the typed plane's one probe).
	grep -E '^docker run .*--post-data' "$LOG" | grep -v '"method":"tools/list"' || true
	grep -E '^docker-request POST ' "$LOG" | grep -v '"method":"tools/list"' || true
	grep -E '^curl .*api\.ipify\.org' "$LOG" || true
}
bad="$(changes)"
if [ -n "$bad" ]; then
	report "status changed the stack or asked it for something it records:"
	printf '%s\n' "$bad" | sed 's/^/        /' | head -20
fi
if ! grep -q '^   install journal: last good install 2026-11-09T06:18:44Z' "$out"; then
	report "status printed no line from the install journal"
fi
if [ "$(cksum <"$SANDBOX/stack/.install-history")" != "$journal_before" ]; then
	report "status changed the stack: the install journal is not what it was"
fi
# Install-only checks are named as skipped, so they cannot pass silently.
if ! grep -q '   skip  client keys: a call with no key is refused' "$out"; then
	report "status did not mark the install-only request checks as skipped"
fi

# 2. A directory with no .env: nothing to measure, named, and no docker call at all.
: >"$LOG"
set +e
(cd "$ROOT" && PATH="$SANDBOX/bin:$PATH" STACK_DIR="$SANDBOX/empty" bash ./install.sh status >"$out.empty" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
	report "status on an empty directory exited $rc, not 2"
fi
if ! grep -q 'nothing is installed' "$out.empty"; then
	report "status on an empty directory did not say that nothing is installed"
fi
if [ -s "$LOG" ]; then
	report "status on an empty directory called docker or another tool:"
	sed 's/^/        /' "$LOG" | head -5
fi

# 3. A Docker that does not answer, then a stack whose network is gone: nothing was read,
#    so the run ends 2, says why, and no check prints a line about a box it cannot see.
could_not_measure() { # NAME FILE: what the run must do with FILE touched
	: >"$LOG"
	: >"$2"
	set +e
	(cd "$ROOT" && PATH="$SANDBOX/bin:$PATH" STACK_DIR="$SANDBOX/stack" bash ./install.sh status >"$out.down" 2>&1)
	rc=$?
	set -e
	rm -f "$2"
	if [ "$rc" -ne 2 ]; then
		report "status with $1 exited $rc, not 2"
		sed 's/^/        /' "$out.down" | head -6
	fi
	if ! grep -q 'could not measure' "$out.down"; then
		report "status with $1 did not say it could not measure"
	fi
	if grep -qE '^   (ok|FAIL) ' "$out.down"; then
		report "status with $1 printed a check line about a box it could not read"
	fi
	bad="$(changes)"
	if [ -n "$bad" ]; then
		report "status with $1 changed the stack:"
		printf '%s\n' "$bad" | sed 's/^/        /' | head -5
	fi
}
could_not_measure "a Docker that does not answer" "$DOWN_FILE"
could_not_measure "the stack's network gone" "$NO_NETWORK_FILE"

if [ "$fail" -gt 0 ]; then
	printf '%d problem(s) with status: it is not the read-only check the install is.\n' "$fail"
	exit 1
fi
echo "OK: status ran $lines check line(s) on a stack that is there, made no call that changes it, ended 2 on an empty directory, a Docker that does not answer and a missing network."
