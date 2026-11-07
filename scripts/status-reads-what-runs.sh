#!/usr/bin/env bash
# Enforces that the drift check in `./install.sh status` says what Docker really runs,
# and never turns "could not read it" into a green line.
#
# WHY
#
# A wrong answer here is silent: a green line on a container that left its pin wakes
# nobody. The drift check has four ways of being green for no reason, and each is a
# line of shell that looks right. `.Config.Image` is only the name the container was
# created with, so it matches whatever the bytes are. `.Image` alone never matches on
# the classic image store, so an operator learns to ignore the red. A skipped service
# counted as a match turns an empty box into a pass. An override in `.env` becomes the
# thing the box is compared with, so it agrees with itself.
#
# HOW
#
# Nothing is installed and no Docker is touched for the verdicts. The gate lifts the
# `# running-images:` and `# profile-table:` blocks out of install.sh and runs them on
# a PATH whose `docker` is a stub answering from a fixture: a compose render, a list of
# containers, their image records and the project's networks. The stub fills Go
# templates field by field, `.Config.Image` included, so a mutant that reads the wrong
# field gets the wrong answer and not an error. It logs every call. Each case asserts
# the line, the counters and, for every run, four things that hold whatever the box
# looks like: the run says in one line what it cannot tell; it prints neither of the
# two words this check has no right to; it called only the reads in the list below;
# and no network tool ran.
#
# Then two things a fixture cannot stand in for. The repository's own compose.yaml is
# rendered by the real `docker compose`, so the parser is held to real output, on
# whichever Compose this runs under. And `status_main` is lifted and run, so the three
# exit codes are measured where they are decided.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No block, a block with no function, a check list that does not call it, no compose
# file, no Docker to render with, a stub nothing called, or no case run: each is
# reported as measuring nothing, not as a pass.
#
# (teeth cases: scripts/gates-have-teeth.sh, "status-reads-what-runs: ...";
#  scenarios: features/status-reads-what-runs.feature)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ ! -f install.sh ] || [ ! -f compose.yaml ]; then
	echo "FAIL: install.sh or compose.yaml is not there, so the drift check measured NOTHING."
	exit 1
fi
BLOCK="$(sed -n '/^# running-images: begin$/,/^# running-images: end$/p' install.sh)"
if ! grep -q '^running_images() {$' <<<"$BLOCK"; then
	echo "FAIL: install.sh has no '# running-images:' block with running_images, so the drift check measured NOTHING."
	exit 1
fi
TABLE="$(sed -n '/^# profile-table: begin$/,/^# profile-table: end$/p' install.sh)"
if ! grep -q '^PROFILES_OPERATOR=' <<<"$TABLE"; then
	echo "FAIL: install.sh has no '# profile-table:' block, so the drift check cannot tell a stopped operator profile and this measured NOTHING."
	exit 1
fi
MAIN="$(awk '/^status_main\(\) \{$/,/^\}$/' install.sh)"
if [ -z "$MAIN" ]; then
	echo "FAIL: install.sh has no status_main, so the exit codes measured NOTHING."
	exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
	echo "FAIL: there is no Docker Compose here to render compose.yaml, so the real file measured NOTHING."
	exit 1
fi
REAL_DOCKER="$(command -v docker)"

problems=0
report() {
	printf 'FAIL: %s\n' "$1"
	problems=$((problems + 1))
}

# The drift check runs at the end of the check list, so both callers get it: section 8
# of an install and `status`. Called anywhere else, or twice, one of them is a copy.
# The list holds helpers of its own with a closing brace in column one, so its end is the
# next section of the file, not the first `}`.
CHECKS="$(sed -n '/^stack_checks() {$/,/^# ---- status: /p' install.sh)"
calls="$(grep -c '^running_images$' <<<"$CHECKS" || true)"
if [ "$calls" -ne 1 ]; then
	report "stack_checks calls running_images $calls time(s), not once, so the install and status do not both run the drift check"
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/status-drift.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
export LOG="$SANDBOX/calls.log"
export FIX="$SANDBOX/fixture"
BOX="$SANDBOX/box"
OUT="$SANDBOX/out"
printf '%s\n%s\n' "$TABLE" "$BLOCK" >"$SANDBOX/lifted.sh"

# Every call this check may make. A reader of a fixture cannot notice a write, so what
# may be called is a list and everything else is a finding.
READS='^docker (ps -a -q --no-trunc --filter label=com\.docker\.compose\.project=agent-stack|inspect --format .*|image inspect --format .*|network ls -q --filter label=com\.docker\.compose\.project=agent-stack|network inspect --format .*|compose --profile \* config|compose -f compose\.yaml --profile \* config)$'

cat >"$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Answers from the fixture in $FIX, the way this box's Docker would.
printf 'docker %s\n' "$*" >>"$LOG"
if [ -f "$FIX/down" ]; then
  printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock\n' >&2
  exit 1
fi
fill() { # TOKEN VALUE: replaces TOKEN in $o
  o=${o//"$1"/$2}
}
case "${1:-}" in
  compose)
    case " $* " in
      *" config "*)
        [ -f "$FIX/config" ] || { printf 'required variable X is missing a value\n' >&2; exit 1; }
        case " $* " in
          *" -f compose.yaml "*) cat "$FIX/config-file" 2>/dev/null || cat "$FIX/config" ;;
          *" --profile * "*) cat "$FIX/config" ;;
          *) cat "$FIX/config-core" ;;
        esac
        exit 0 ;;
    esac
    exit 0 ;;
  ps)
    cat "$FIX/ps" 2>/dev/null
    exit 0 ;;
  inspect)
    shift
    f=""
    if [ "${1:-}" = --format ]; then f="$2"; shift 2; fi
    rc=0
    for id in "$@"; do
      if [ ! -f "$FIX/c/$id" ]; then printf 'Error: No such object: %s\n' "$id" >&2; rc=1; continue; fi
      # shellcheck disable=SC1090
      . "$FIX/c/$id"
      o="$f"
      fill '{{.Id}}' "$id"
      fill '{{.Name}}' "$C_NAME"
      fill '{{.Image}}' "$C_IMAGE"
      fill '{{.Config.Image}}' "$C_CONFIG_IMAGE"
      fill '{{.State.Status}}' "$C_STATUS"
      fill '{{.State.ExitCode}}' "$C_EXIT"
      fill '{{.RestartCount}}' "$C_RESTARTS"
      fill '{{.HostConfig.ReadonlyRootfs}}' "${C_READONLY:-true}"
      fill '{{.HostConfig.PidsLimit}}' "${C_PIDS:-512}"
      fill '{{.HostConfig.CapDrop}}' "${C_CAPDROP:-[ALL]}"
      fill '{{.HostConfig.SecurityOpt}}' "${C_SECOPT:-[no-new-privileges:true]}"
      fill '{{index .Config.Labels "com.docker.compose.service"}}' "$C_SERVICE"
      fill '{{index .Config.Labels "com.docker.compose.oneoff"}}' "$C_ONEOFF"
      case "$o" in *'{{'*) printf 'stub: a field this fixture does not know: %s\n' "$o" >&2; exit 3 ;; esac
      printf '%s\n' "$o"
    done
    exit "$rc" ;;
  image)
    # image inspect --format FORMAT ID
    id="$5"
    if [ -f "$FIX/i/$id.unreadable" ]; then printf 'Error response from daemon: context deadline exceeded\n' >&2; exit 1; fi
    if [ ! -f "$FIX/i/$id" ]; then printf 'Error response from daemon: No such image: %s\n' "$id" >&2; exit 1; fi
    o="$4"
    digests=""
    while read -r d; do [ -z "$d" ] || digests="$digests$d "; done <"$FIX/i/$id"
    fill '{{range .RepoDigests}}{{.}} {{end}}' "$digests"
    case "$o" in *'{{'*) printf 'stub: a field this fixture does not know: %s\n' "$o" >&2; exit 3 ;; esac
    printf '%s\n' "$o"
    exit 0 ;;
  network)
    case "${2:-}" in
      ls) ls "$FIX/n" 2>/dev/null; exit 0 ;;
      inspect)
        # network inspect --format FORMAT ID
        [ -f "$FIX/n/$5" ] || { printf 'Error: No such network: %s\n' "$5" >&2; exit 1; }
        name=""; members=""
        while read -r l; do
          if [ -z "$name" ]; then name="$l"; else members="$members$l "; fi
        done <"$FIX/n/$5"
        o="$4"
        fill '{{.Name}}' "$name"
        fill '{{range $id, $c := .Containers}}{{$id}}={{$c.Name}} {{end}}' "$members"
        case "$o" in *'{{'*) printf 'stub: a field this fixture does not know: %s\n' "$o" >&2; exit 3 ;; esac
        printf '%s\n' "$o"
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
for tool in curl wget nc cosign; do
	cat >"$SANDBOX/bin/$tool" <<STUB
#!/usr/bin/env bash
printf 'network %s %s\n' "$tool" "\$*" >>"\$LOG"
exit 1
STUB
done
# The second read of a stranger waits a moment on a real box. Here the fixture is already
# what it will be, and a gate that sleeps is paid for once per teeth case.
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/bin/sleep"
chmod +x "$SANDBOX"/bin/*

cat >"$SANDBOX/run.sh" <<'HARNESS'
#!/usr/bin/env bash
# The lifted blocks, run the way stack_checks runs them.
set -euo pipefail
# shellcheck disable=SC1090,SC1091
. "$SANDBOX/lifted.sh"
COMPOSE=(docker compose)
STATUS="$DRIFT_STATUS"
fail=0
unmeasured=0
cd "$1"
running_images
printf 'counters fail=%s unmeasured=%s\n' "$fail" "$unmeasured"
HARNESS
export SANDBOX

# ---- a fixture ------------------------------------------------------------------
dig() { # one hex character, as a whole digest
	local s=""
	while [ "${#s}" -lt 64 ]; do s="$s$1"; done
	printf 'sha256:%s' "$s"
}
short() { printf '%s' "${1:0:19}"; }

REPO=ghcr.io/taipanbox/wardryx
PIN="$(dig a)"    # what compose.yaml pins for wardryx
OLD="$(dig b)"    # an older manifest of the same repository
CFG="$(dig c)"    # the config digest of the pinned image: what .Image is on the classic store
CFG2="$(dig d)"   # the config digest of another image
BUSY_PIN="$(dig e)"
BUSY_CFG="$(dig f)"
PIN_LINE="$REPO:v9.9.9@$PIN"
BUSY_LINE="busybox:1.36@$BUSY_PIN"

service() { # NAME VAR DEFAULT RESOLVED PROFILES RESTART
	printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >>"$FIX/services"
}
container() { # ID SERVICE STATUS EXIT RESTARTS IMAGE_ID CONFIG_IMAGE [ONEOFF [NAME]]
	local name="${9:-/agent-stack-$2-1}"
	printf '%s\n' "$1" >>"$FIX/ps"
	stranger "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-False}" "$name"
	# Docker lists a network's running containers only.
	if [ "$3" = running ]; then printf '%s=%s\n' "$1" "${name#/}" >>"$FIX/n/n1"; fi
}
no_containers() {
	: >"$FIX/ps"
	printf 'agent-stack_core\n' >"$FIX/n/n1"
}
stranger() { # ID SERVICE STATUS EXIT RESTARTS IMAGE_ID CONFIG_IMAGE ONEOFF NAME: known to Docker, not to `ps` of the project
	cat >"$FIX/c/$1" <<EOF
C_SERVICE='$2'
C_STATUS='$3'
C_EXIT='$4'
C_RESTARTS='$5'
C_IMAGE='$6'
C_CONFIG_IMAGE='$7'
C_ONEOFF='$8'
C_NAME='$9'
EOF
}
image() { # ID REPO_DIGEST...
	local id="$1"
	shift
	: >"$FIX/i/$id"
	for d in "$@"; do printf '%s\n' "$d" >>"$FIX/i/$id"; done
}
render() { # writes compose.yaml as a person wrote it, and the two renders compose gives of it
	local name var def resolved profiles restart p
	{
		printf 'name: agent-stack\nservices:\n'
		while IFS='|' read -r name var def resolved profiles restart; do
			printf '  %s:\n' "$name"
			if [ -n "$var" ]; then printf '    image: ${%s:-%s}\n' "$var" "$def"; else printf '    image: %s\n' "$def"; fi
		done <"$FIX/services"
	} >"$BOX/compose.yaml"
	for out in config config-core; do
		{
			printf 'name: agent-stack\nservices:\n'
			while IFS='|' read -r name var def resolved profiles restart; do
				if [ "$out" = config-core ] && [ -n "$profiles" ]; then continue; fi
				printf '  %s:\n    cap_drop:\n      - ALL\n    command:\n      - -serve\n' "$name"
				printf '    depends_on:\n      init-volumes:\n        condition: service_completed_successfully\n        required: true\n'
				printf '    image: %s\n' "$resolved"
				if [ -n "$profiles" ]; then
					printf '    profiles:\n'
					for p in $profiles; do printf '      - %s\n' "$p"; done
				fi
				printf '    read_only: true\n    pids_limit: 512\n    security_opt:\n      - no-new-privileges:true\n'
				printf '    restart: %s\n    user: "20001:10001"\n' "$restart"
			done <"$FIX/services"
			printf 'networks:\n  core:\n    name: agent-stack_core\n    internal: true\nvolumes:\n  events:\n    name: agent-stack_events\n'
			printf 'x-restart: unless-stopped\n'
		} >"$FIX/$out"
	done
}
# The box everything starts from: the classic image store, wardryx on its pin, init-volumes
# finished, and scopyx in a profile that is off.
fresh() {
	rm -rf "$FIX" "$BOX"
	mkdir -p "$FIX/c" "$FIX/i" "$FIX/n" "$BOX"
	: >"$FIX/services"
	: >"$BOX/.env"
	service wardryx WARDRYX_IMAGE "$PIN_LINE" "$PIN_LINE" "" unless-stopped
	service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" '"no"'
	service scopyx SCOPYX_IMAGE "$REPO-scopyx:v1@$OLD" "$REPO-scopyx:v1@$OLD" egress unless-stopped
	no_containers
	container w1 wardryx running 0 0 "$CFG" "$PIN_LINE"
	image "$CFG" "$REPO@$PIN"
	container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
	image "$BUSY_CFG" "busybox@$BUSY_PIN"
	render
}

cases=0
go() { # NAME [STATUS]: runs the block over the fixture and checks what holds on every run
	cases=$((cases + 1))
	case_name="$1"
	: >"$LOG"
	set +e
	PATH="$SANDBOX/bin:$PATH" DRIFT_STATUS="${2:-1}" bash "$SANDBOX/run.sh" "$BOX" >"$OUT" 2>&1
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		report "$case_name: the drift check itself stopped with exit $rc"
		sed 's/^/        /' "$OUT" | head -8
	fi
	if ! grep -q '^   this is a drift check: .*root on this box can change either side' "$OUT"; then
		report "$case_name: the run does not say in one line what this cannot tell"
	fi
	if grep -qiE '\b(verified|attested|attestation)\b' "$OUT"; then
		report "$case_name: the output claims more than a drift check can say"
	fi
	local bad
	bad="$(grep -E '^docker ' "$LOG" | grep -vE "$READS" || true)"
	if [ -n "$bad" ]; then
		report "$case_name: the drift check made a call that is not one of its reads:"
		printf '%s\n' "$bad" | sed 's/^/        /' | head -5
	fi
	if grep -q '^network ' "$LOG"; then
		report "$case_name: the drift check reached for the network:"
		grep '^network ' "$LOG" | sed 's/^/        /' | head -5
	fi
}
sees() { # REGEX WHY
	if ! grep -qE -- "$1" "$OUT"; then
		report "$case_name: $2"
		sed 's/^/        /' "$OUT" | head -12
	fi
}
never() { # REGEX WHY
	if grep -qE -- "$1" "$OUT"; then
		report "$case_name: $2"
		sed 's/^/        /' "$OUT" | head -12
	fi
}
counts() { # FAIL UNMEASURED WHY
	if ! grep -qx "counters fail=$1 unmeasured=$2" "$OUT"; then
		report "$case_name: $3 (expected fail=$1 unmeasured=$2, got $(grep '^counters ' "$OUT" || echo nothing))"
	fi
}

# ---- what runs, against what was pinned -----------------------------------------
fresh
go "the classic store"
sees "^   ok    wardryx +running +$(short "$PIN")[0-9a-f]* +pin $(short "$PIN")[0-9a-f]* +compose" "a container on its pin is not named with the digest it runs, the pin and where the pin came from"
sees "^   ok    init-volumes +exited 0 +$(short "$BUSY_PIN")[0-9a-f]* +pin $(short "$BUSY_PIN")" "a finished one-shot on its pin is not ok"
sees "against the pins in .*/compose.yaml" "the run does not name the file its pins come from"
sees "as the Docker on this box reports it" "the run does not say whose word this is"
counts 0 0 "a box on its pins failed"

fresh
no_containers
rm -f "$FIX/i/$CFG"
container w2 wardryx running 0 0 "$PIN" "$PIN_LINE"
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
image "$PIN" "$REPO@$PIN"
go "the containerd store"
sees "^   ok    wardryx +running +$(short "$PIN")" "the containerd store, where .Image is the pin, does not read as a match"
counts 0 0 "the same bytes get a different verdict on the containerd store"

fresh
no_containers
container w2 wardryx running 0 0 "$PIN" "$PIN_LINE"
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
image "$PIN"
go "the containerd store with no digest list"
sees "^   ok    wardryx +running" "a container whose .Image is the pin is judged by RepoDigests alone"
counts 0 0 "a container whose .Image is the pin did not match"

fresh
no_containers
container w1 wardryx running 0 0 "$CFG2" "$PIN_LINE"
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
image "$CFG2" "$REPO@$OLD"
go "a container older than its pin"
sees "^   FAIL  wardryx +running +$(short "$OLD")[0-9a-f]* +pin $(short "$PIN")" "a container off its pin does not fail with both digests named"
counts 1 0 "a container off its pin did not fail status"

fresh
image "$CFG" "ghcr.io/somebody-else/wardryx@$PIN"
go "the pin's digest in another repository"
sees "^   FAIL  wardryx" "a digest known only under another repository reads as the pin"
counts 1 0 "a digest under another repository did not fail"

fresh
image "$CFG" "$REPO@$OLD" "$REPO@$PIN"
go "the pin is the second digest the image is known by"
sees "^   ok    wardryx" "only the first RepoDigest was compared"
counts 0 0 "an image known by the pin as its second digest failed"

fresh
rm -f "$FIX/i/$CFG"
go "the image record is gone"
sees "^   FAIL  wardryx .*image record gone" "a container whose image record is gone is not named so"
counts 1 0 "a container whose image record is gone did not fail"

fresh
rm -f "$FIX/i/$CFG"
: >"$FIX/i/$CFG.unreadable"
go "the image record cannot be read"
sees "could not measure" "a Docker that would not answer about an image is not named so"
counts 0 1 "an image Docker would not answer about is not a could-not-measure"

# ---- where the pin came from ----------------------------------------------------
fresh
ENV_LINE="$REPO:v9.9.8@$OLD"
: >"$FIX/services"
service wardryx WARDRYX_IMAGE "$PIN_LINE" "$ENV_LINE" "" unless-stopped
service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" '"no"'
render
printf 'WARDRYX_IMAGE=%s\n' "$ENV_LINE" >"$BOX/.env"
image "$CFG" "$REPO@$OLD"
go "an image set in .env"
sees "^   note  wardryx +running +$(short "$OLD")[0-9a-f]* +pin $(short "$OLD")[0-9a-f]* +\.env override" "an image set in .env is not shown as an override"
sees "compose\.yaml pins $(short "$PIN")" "an override does not name what compose.yaml pins"
never "^   ok    wardryx" "an image set in .env reads as a plain ok"
counts 0 0 "an override the box really runs is a note, not a failure"

fresh
LATEST="$REPO:latest"
: >"$FIX/services"
service wardryx WARDRYX_IMAGE "$PIN_LINE" "$LATEST" "" unless-stopped
service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" '"no"'
render
printf 'WARDRYX_IMAGE=%s\n' "$LATEST" >"$BOX/.env"
image "$CFG" "$REPO@$OLD"
go ":latest in an override"
sees "^   FAIL  wardryx .*no digest pinned" "an override with no digest, pulled from a registry, is not refused"
counts 1 0 "an override with no digest did not fail"

fresh
LOCAL=stack/wardryx:dev
: >"$FIX/services"
service wardryx WARDRYX_IMAGE "$PIN_LINE" "$LOCAL" "" unless-stopped
service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" '"no"'
render
printf 'WARDRYX_IMAGE=%s\n' "$LOCAL" >"$BOX/.env"
image "$CFG"
go "an image built on the box"
sees "^   note  wardryx +running +stack/wardryx:dev +built on this box, nothing to compare" "an image built here is not named as built here"
sees "^   ok    init-volumes" "the images that can be compared were not"
counts 0 0 "an image built here is not a failure"

fresh
image "$CFG"
go "a pin with a digest over an image with none"
sees "^   FAIL  wardryx" "an image with no registry digest under a digest pin reads as built here and passes"
counts 1 0 "a pinned service running a local image did not fail"

fresh
: >"$FIX/services"
: >"$BOX/compose.override.yaml"
service wardryx WARDRYX_IMAGE "$PIN_LINE" "$REPO:v9.9.8@$OLD" "" unless-stopped
service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" '"no"'
render
image "$CFG" "$REPO@$OLD"
go "an image set in compose.override.yaml"
sees "^   note  compose\.override\.yaml" "the override file is not mentioned"
sees "^   note  wardryx .*compose\.override\.yaml" "an image set in the override file is not shown as coming from it"

# ---- states ---------------------------------------------------------------------
fresh
no_containers
container w1 wardryx running 0 0 "$CFG" "$PIN_LINE"
container i1 init-volumes exited 1 0 "$BUSY_CFG" "$BUSY_LINE"
go "a one-shot that ended 1"
sees "^   FAIL  init-volumes +exited 1" "a one-shot that ended 1 does not fail"
counts 1 0 "a one-shot that ended 1 did not fail status"

# Compose 2.x renders the word in double quotes and Compose 5.x in single ones.
fresh
no_containers
: >"$FIX/services"
service wardryx WARDRYX_IMAGE "$PIN_LINE" "$PIN_LINE" "" unless-stopped
service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" "'no'"
render
container w1 wardryx running 0 0 "$CFG" "$PIN_LINE"
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
go "a one-shot as Compose 5 renders it"
sees "^   ok    init-volumes +exited 0" "a one-shot under single quotes is not read as a one-shot"
counts 0 0 "a one-shot under single quotes failed"

fresh
no_containers
container w1 wardryx restarting 1 7 "$CFG" "$PIN_LINE"
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
go "a container that keeps restarting"
sees "^   FAIL  wardryx +restarting +$(short "$PIN")[0-9a-f]* +pin $(short "$PIN")" "a restarting container does not name its state and its digest"
sees "7 restart" "a restarting container does not say how many times"
counts 1 0 "a restarting container did not fail"

fresh
go "a profile that is off"
sees "^   skip  scopyx +not started, profile egress is off" "a service whose profile is off is not skipped and said so"
counts 0 0 "a profile that is off failed"

fresh
no_containers
container w1 wardryx running 0 0 "$CFG" "$PIN_LINE"
go "a one-shot whose record was pruned"
sees "^   skip  init-volumes +no container" "a pruned one-shot is not skipped and said so"
counts 0 0 "a pruned one-shot failed the run"

fresh
no_containers
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
go "a service of no profile has no container"
sees "^   FAIL  wardryx" "a core service with no container is not a failure"
counts 1 0 "a core service with no container did not fail"

fresh
no_containers
container w1 wardryx exited 137 0 "$CFG" "$PIN_LINE"
container i1 init-volumes exited 0 0 "$BUSY_CFG" "$BUSY_LINE"
go "a core service that stopped"
sees "^   FAIL  wardryx +exited 137" "a service compose keeps running reads as fine after it stopped"
counts 1 0 "a stopped core service did not fail"

fresh
container s1 scopyx exited 137 0 "$CFG" "$REPO-scopyx:v1@$OLD"
go "a stopped operator profile"
sees "^   skip  scopyx +exited 137" "a stopped service of an operator-started profile is not named as stopped"
counts 0 0 "an operator's stopped profile failed"

fresh
: >"$FIX/services"
service wardryx WARDRYX_IMAGE "$PIN_LINE" "$PIN_LINE" "" unless-stopped
service init-volumes "" "$BUSY_LINE" "$BUSY_LINE" "" '"no"'
service record-seal TRAILRYX_IMAGE "$REPO-seal:v1@$OLD" "$REPO-seal:v1@$OLD" record unless-stopped
render
container r1 record-seal exited 2 0 "$CFG" "$REPO-seal:v1@$OLD"
go "a stopped installer-managed profile"
sees "^   FAIL  record-seal +exited 2" "a stopped service of an installer-managed profile reads like an operator's"
counts 1 0 "a stopped installer-managed service did not fail"

fresh
container w0 wardryx exited 137 0 "$CFG2" "$PIN_LINE" False /abc123_agent-stack-wardryx-1
image "$CFG2" "$REPO@$OLD"
go "an old stopped copy"
sees "^   note  wardryx +exited 137 +$(short "$CFG2")[0-9a-f]* +a stopped copy" "an old stopped copy is not shown as one"
counts 0 0 "an old stopped copy beside the running one failed"

fresh
container o1 wardryx running 0 0 "$CFG2" "$PIN_LINE" True /agent-stack-wardryx-run-1
go "a one-off run"
sees "^   note  wardryx +running +a one-off run" "a one-off run is not mentioned"
counts 0 0 "a one-off run was compared"

# ---- what compose does not know --------------------------------------------------
fresh
printf 'z9=wardryx-old\n' >>"$FIX/n/n1"
stranger z9 "" running 0 0 "$CFG2" "$PIN_LINE" "" /wardryx-old
go "a stranger on the stack's network"
sees "^   FAIL  wardryx-old +running +unknown container on agent-stack_core" "a container on the stack's network with no project label is not found"
counts 1 0 "a stranger on the stack's network did not fail status"

fresh
printf 'z9=busybox-probe\n' >>"$FIX/n/n1"
go "a throwaway that left by the second read"
never "busybox-probe" "a container gone by the second read is reported"
counts 0 0 "a throwaway that left failed the run"

fresh
container q1 wardryx-old running 0 0 "$CFG2" "$PIN_LINE"
go "a labelled container compose does not declare"
sees "^   FAIL  agent-stack-wardryx-old-1 +running +unknown container" "a container of this project that compose.yaml does not declare is not found"
counts 1 0 "a labelled stranger did not fail"

# ---- what the file gives a container, against what it runs with --------------------
hand_made() { # the field, as Docker reports it, for the running wardryx
	printf '%s\n' "$1" >>"$FIX/c/w1"
}
fresh
hand_made "C_READONLY=false"
go "a container with a writable root"
sees "^   FAIL  wardryx +running +compose\.yaml gives it read_only, and the container does not have it" "a running container that lost read_only passes"
counts 1 0 "a running container that lost read_only did not fail"

fresh
hand_made "C_PIDS=0"
go "a container with no process limit"
sees "gives it pids_limit" "a running container with no process limit passes"
counts 1 0 "a running container with no process limit did not fail"

fresh
hand_made "C_CAPDROP='[]'"
go "a container that kept its capabilities"
sees "gives it cap_drop" "a running container that kept its capabilities passes"

fresh
hand_made "C_SECOPT='[]'"
go "a container that can gain privileges"
sees "gives it no-new-privileges" "a running container that can gain privileges passes"

# An override that turns one off agrees with itself, so the file is read without it.
fresh
: >"$BOX/compose.override.yaml"
cp "$FIX/config" "$FIX/config-file"
sed -i.bak 's/^    read_only: true$/    read_only: false/' "$FIX/config"
hand_made "C_READONLY=false"
go "an override that turns the baseline off"
sees "gives it read_only" "an override that turns read_only off reads as what the file says"
counts 1 0 "an override that turns read_only off passed"

# ---- could not measure -----------------------------------------------------------
fresh
: >"$FIX/down"
go "Docker does not answer"
sees "could not measure" "a Docker that does not answer is not named"
never "^   ok " "something reads ok with Docker down"
counts 0 1 "a Docker that does not answer is not a could-not-measure"

fresh
no_containers
rm -f "$FIX/n/n1"
go "no container at all"
sees "could not measure" "zero containers is not named as nothing measured"
counts 0 1 "zero containers is not a could-not-measure"

fresh
rm -f "$FIX/config"
go "the pins cannot be read"
sees "could not measure" "a compose that would not render is not named"
counts 0 1 "no pins is not a could-not-measure"

fresh
no_containers
: >"$FIX/services"
service scopyx SCOPYX_IMAGE "$REPO-scopyx:v1@$OLD" "$REPO-scopyx:v1@$OLD" egress unless-stopped
render
container s1 scopyx exited 137 0 "$CFG" "$REPO-scopyx:v1@$OLD"
go "nothing was compared"
sees "could not measure" "a run that compared nothing reads as a pass"
counts 0 1 "a run that compared nothing is not a could-not-measure"

fresh
: >"$FIX/down"
go "could not measure at the end of an install" 0
counts 1 0 "an install that could not measure counts it as a failed check"

# ---- the real file, as this machine's Compose renders it -------------------------
real_services="$(awk '/^services:/{on=1;next} /^[^ #]/{on=0} on&&/^  [a-z0-9-]+:[ ]*$/{print $1}' compose.yaml | tr -d ':' | sort)"
real_count="$(grep -c . <<<"$real_services" || true)"
if [ "$real_count" -lt 10 ]; then
	report "compose.yaml names $real_count service(s), so the real file measured NOTHING"
fi
rm -rf "$BOX" "$FIX"
mkdir -p "$BOX" "$FIX/c" "$FIX/i" "$FIX/n"
no_containers
cp compose.yaml "$BOX/compose.yaml"
grep -oE '\$\{[A-Za-z0-9_]+:\?' compose.yaml | sed -E 's/^\$\{//; s/:\?$//' | sort -u | sed 's/$/=x/' >"$BOX/.env"
if ! (cd "$BOX" && "$REAL_DOCKER" compose --profile '*' config >"$FIX/config" 2>"$SANDBOX/render.err"); then
	report "docker compose could not render the repository's compose.yaml: $(head -2 "$SANDBOX/render.err")"
fi
cp "$FIX/config" "$FIX/config-core"
# Which services are one-shots, and which sit in a profile, as the file says it.
one_shots="$(awk '/^services:/{on=1;next} /^[^ #]/{on=0} on&&/^  [a-z0-9-]+:[ ]*$/{s=$1} on&&/^    restart: "no"/{print s}' compose.yaml | tr -d ':')"
profiled="$(awk '/^services:/{on=1;next} /^[^ #]/{on=0} on&&/^  [a-z0-9-]+:[ ]*$/{s=$1} on&&/^    profiles:/{print s}' compose.yaml | tr -d ':')"
real_box() { # WITH_PROFILES: a container on its pin for every service, or only for those in no profile
	local n=0 svc line cfgid repo
	no_containers
	while read -r svc; do
		n=$((n + 1))
		if [ "$1" = 0 ] && grep -qx -- "$svc" <<<"$profiled"; then continue; fi
		line="$(awk -v want="  $svc:" '/^services:/{on=1;next} /^[^ ]/{on=0} on&&/^  [^ ]/{s=($0==want)} on&&s&&/^    image: /{print $2}' "$FIX/config")"
		cfgid="$(dig 1 | sed "s/1/$((n % 10))/g")$n"
		if grep -qx -- "$svc" <<<"$one_shots"; then
			container "r$n" "$svc" exited 0 0 "$cfgid" "$line"
		else
			container "r$n" "$svc" running 0 0 "$cfgid" "$line"
		fi
		# The limit the render gives it, so a good container is one that has it.
		awk -v want="  $svc:" '/^services:/{on=1;next} /^[^ ]/{on=0} on&&/^  [^ ]/{s=($0==want)} on&&s&&/^    pids_limit: /{print "C_PIDS=" $2}' "$FIX/config" >>"$FIX/c/r$n"
		repo="${line%%@*}"
		case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
		image "$cfgid" "$repo@${line##*@}"
	done <<<"$real_services"
}
real_box 1
go "the repository's own compose.yaml"
real_ok="$(grep -cE '^   ok    [a-z0-9-]+ +(running|exited 0) +sha256:[0-9a-f]+ +pin sha256:[0-9a-f]+ +compose' "$OUT" || true)"
if [ "$real_ok" -ne "$real_count" ]; then
	report "the repository's own compose.yaml: $real_ok of $real_count services read ok, so the parser and the real render disagree"
	sed 's/^/        /' "$OUT" | head -12
fi
counts 0 0 "the repository's own compose.yaml, every service on its pin, failed"
real_box 0
go "the repository's own compose.yaml, with every profile off"
real_skips="$(grep -cE '^   skip  [a-z0-9-]+ +not started, profiles? ' "$OUT" || true)"
profiled_count="$(grep -c . <<<"$profiled" || true)"
if [ "$profiled_count" -eq 0 ] || [ "$real_skips" -ne "$profiled_count" ]; then
	report "the repository's own compose.yaml: $real_skips of $profiled_count services with a profile were skipped, so the parser does not read the real render's profiles"
	sed 's/^/        /' "$OUT" | head -12
fi
counts 0 0 "the repository's own compose.yaml with every profile off failed"

# ---- the three exit codes, where they are decided ---------------------------------
cat >"$SANDBOX/main.sh" <<'HARNESS'
#!/usr/bin/env bash
# status_main, lifted, with the check list replaced by what this case needs it to report.
set -euo pipefail
die() { EXPLAINED=1; printf '%s\n' "$*" >&2; exit 1; }
gateway_probe_resolve() { :; }
status_facts() { :; }
stack_checks() { fail="$CASE_FAIL"; unmeasured="$CASE_UNMEASURED"; }
journal_status() { :; }
# shellcheck disable=SC1090,SC1091
. "$SANDBOX/lifted.sh"
# shellcheck disable=SC1090,SC1091
. "$SANDBOX/main-lifted.sh"
status_main
HARNESS
printf '%s\n' "$MAIN" >"$SANDBOX/main-lifted.sh"
rm -rf "$FIX" "$BOX"
mkdir -p "$FIX" "$BOX"
printf "GATEWAY_CLIENT_KEYS='secret:key'\n" >"$BOX/.env"
main_code() { # FAIL UNMEASURED: the code status ends with
	set +e
	CASE_FAIL="$1" CASE_UNMEASURED="$2" STACK_DIR="$BOX" PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/main.sh" >"$OUT" 2>&1
	code=$?
	set -e
	printf '%s' "$code"
}
cases=$((cases + 1))
case_name="the exit codes"
got="$(main_code 0 0)"
[ "$got" = 0 ] || report "every check passed and status ended $got, not 0"
got="$(main_code 3 0)"
[ "$got" = 1 ] || report "a failed check and status ended $got, not 1"
got="$(main_code 0 1)"
[ "$got" = 2 ] || report "nothing failed, one check could not measure, and status ended $got, not 2"
sees '^1 check\(s\) could not measure$' "a run that could not measure does not end by saying so"
got="$(main_code 2 1)"
[ "$got" = 1 ] || report "a failed check beside a could-not-measure ended $got, not 1: what was found outranks what was not"

# Docker that does not answer, and a .env this user cannot read: stopped before any check.
cases=$((cases + 1))
: >"$FIX/down"
got="$(main_code 0 0)"
[ "$got" = 2 ] || report "with Docker down status ended $got, not 2"
sees 'could not measure' "with Docker down status does not say it could not measure"
rm -f "$FIX/down"
if [ "$(id -u)" != 0 ]; then
	cases=$((cases + 1))
	chmod 000 "$BOX/.env"
	got="$(main_code 0 0)"
	chmod 600 "$BOX/.env"
	[ "$got" = 2 ] || report "a .env this user cannot read ended status $got, not 2"
	sees 'could not measure' "a .env this user cannot read is not named"
fi

# ---- the words this check has no right to -----------------------------------------
# The section of the README that talks about status, and the scenarios that describe it.
SECTION="$(sed -n '/^## Checking an installed box again/,/^## /p' README.md)"
if ! grep -q 'drift check' <<<"$SECTION"; then
	report "the README's status section does not name the drift check"
fi
if grep -qiE '\b(verified|attested|attestation)\b' <<<"$SECTION"; then
	report "the README's status section claims more than a drift check can say"
fi
if [ -f features/status-reads-what-runs.feature ] && grep -qiE '\b(verified|attested|attestation)\b' features/status-reads-what-runs.feature; then
	report "the scenarios claim more than a drift check can say"
fi

# ---- it measured something ---------------------------------------------------------
if [ "$cases" -lt 30 ]; then
	report "only $cases case(s) ran, so this measured almost NOTHING"
fi
if [ "$problems" -gt 0 ]; then
	printf '%d problem(s) with the drift check.\n' "$problems"
	exit 1
fi
printf 'OK: the drift check held on %d cases, %d real services among them, on %s.\n' "$cases" "$real_count" "$("$REAL_DOCKER" compose version --short 2>/dev/null || echo 'this Compose')"
