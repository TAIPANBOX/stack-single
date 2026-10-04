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
# What this box does NOT run, so you can compare before installing rather
# than after: none of stack-up's five governance routines (a FinOps export, a
# crypto-inventory trend, a quality-drift check, an identity-anomaly sweep,
# and an opt-in fire drill) run here on any schedule; stack-k8s runs three of
# the four safe ones as CronJobs, stack-up runs all five as OS timers, and
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
#   TYPED_RISK_SIGNAL=1 (with any typed answers above, never with them off) also
#     starts typryx's wardryx-proxy and points ONLY the MCP broker's policy
#     client at it, so a tool call carries typryx's risk class to wardryx; it
#     is off unless you ask, 0 turns it off. See section 0b and the README.
#   RUN_BUDGET_CEILING_USD=2.50 ./install.sh   # the most a caller can make one
#     run's budget (tokenfuse 1.5.0), 5.00 unless you say otherwise
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
# stub backend, which makes no outbound call. With a terminal and nothing set,
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
# IPv6 literal bracketed, as a URL needs. Computed once, here, because both
# section 8's own health check and the delegation plane's
# TOKENFUSE_DELEGATION_URL (the origin a hand-off proof's DPoP `htu` is
# checked against) need the identical answer; two copies of this case
# statement disagreeing would be the same trap CLAUDE.md's WARDRYX_DB story
# already names, one variable over.
case "$GATEWAY_BIND" in
  0.0.0.0) GATEWAY_PROBE=127.0.0.1 ;;
  *:*)     GATEWAY_PROBE="[$GATEWAY_BIND]" ;;
  *)       GATEWAY_PROBE="$GATEWAY_BIND" ;;
esac

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
# typryx on its stub backend, which makes no outbound call.
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
# is unreadable by uid 65532.
typed_install_key() {
  local dir="$STACK_DIR/typed"
  mkdir -p "$dir" || die "could not create $dir"
  chmod 0755 "$dir" || die "could not set the mode of $dir"
  ( umask 077; cat "$1" >"$dir/$2.tmp" ) || die "could not copy the key file into $dir"
  chown 65532:65532 "$dir/$2.tmp" || die "could not hand the key file to the uid typryx runs as"
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
    ""|jev|own-model|off) ;;
    *) die ".env holds an unknown TYPED_MODE; it must be jev, own-model or off. Nothing was changed." ;;
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
  # run saved, then WITH_TYPED=1 (the stub), then off. A saved `off` is the
  # weakest of these on purpose: an explicit WITH_TYPED=1 is a newer, louder
  # answer than "not asked for yet".
  if [ -n "$want" ]; then
    mode="$want"
  elif [ "$TYPED_SAVED_MODE" = jev ] || [ "$TYPED_SAVED_MODE" = own-model ]; then
    mode="$TYPED_SAVED_MODE"
  elif [ -n "${WITH_TYPED:-}" ]; then
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
      note "typed answers: WITH_TYPED=1 with no TYPED_MODE, so typryx runs on its stub backend (no outbound call), as before TYPED_MODE existed"
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
      # wrote in .env, which is what WITH_TYPED=1 has always done.
      [ -z "$TYPED_SAVED_MODE" ] || typed_forget_env "${TYPED_OWNED[@]}"
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
    git clone --depth 1 -q "https://x-access-token:${CONSOLE_TOKEN}@github.com/TAIPANBOX/genaryx.git" genaryx-a360 \
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
# Its own viewer key for the policy plane, for the reason the gateway has one:
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
# events either way: that plane refuses all four (agent-event v1.0 is a
# schema trailryx 1.0 does not read, and its mapper refuses the four types by
# name on purpose, trailryx#81), so a matching trust domain would not make
# them seal, only keep the identity honest if that ever changes. Staying consistent with
# every other generated identity here is worth more than that, until then.
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
if [ -n "${WITH_DELEGATION:-}" ]; then
  say "delegation"
  # The value on this box now, whichever run put it there: an operator's own
  # VOUCHRYX_TRUSTED_ISSUERS in the environment this run, or .env already
  # carrying one from an earlier run (just sourced above).
  VOUCHRYX_TRUSTED_ISSUERS="${VOUCHRYX_TRUSTED_ISSUERS:-}"
  if [ -z "$VOUCHRYX_TRUSTED_ISSUERS" ] && [ -z "${WITH_DELEGATION_DEMO_ISSUER:-}" ]; then
    die "WITH_DELEGATION=1 needs a trusted upstream issuer to verify the subject and actor \
tokens it exchanges against, and none is configured. Set VOUCHRYX_TRUSTED_ISSUERS='iss|aud|jwks-path' \
(the jwks-path readable inside $STACK_DIR/delegation once this run finishes), naming the identity \
provider your agents actually get their tokens from. There is no safe value to invent here, so \
nothing started. To try this out instead of wiring a real issuer, set WITH_DELEGATION_DEMO_ISSUER=1 \
for a clearly-labelled, self-signed issuer this installer mints for you; it is never a production \
posture and README says so."
  fi

  # vouchryx's own directory: its signing key, and the demo issuer's JWKS
  # when one is minted. Owned by the uid vouchryx runs as (65532, distroless
  # nonroot) and closed to everyone else, the gateway included: a bind mount
  # keeps the host's ownership and mode, so a root-owned 0700 directory is one
  # the container cannot even enter (measured 2026-09-27 on Debian 13; Docker
  # Desktop on macOS ignores bind-mount ownership and hides this).
  mkdir -p delegation
  chown 65532:65532 delegation
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
        --entrypoint vouchryx-demo "${VOUCHRYX_IMAGE:-ghcr.io/taipanbox/vouchryx:v0.2.0}" \
        keygen -out /out/signing >/dev/null \
      || die "could not mint vouchryx's signing key"
    chown 65532:65532 delegation/signing.pem delegation/signing.jwks.json
    chmod 600 delegation/signing.pem
  else
    note "vouchryx: signing key already present, reused"
  fi

  # The clearly-labelled demo issuer: a self-signed stand-in for the upstream
  # IdP a real deployment would point at instead, minted the same way the
  # signing key above is. Never a production posture, and never chosen unless
  # the operator names it explicitly (CLAUDE.md invariant 15).
  if [ -z "$VOUCHRYX_TRUSTED_ISSUERS" ]; then
    if [ ! -f delegation/idp.pem ]; then
      note "vouchryx: minting a demo issuer (WITH_DELEGATION_DEMO_ISSUER=1, never for production)"
      docker run --rm --user 0:0 -v "$STACK_DIR/delegation:/out" \
          --entrypoint vouchryx-demo "${VOUCHRYX_IMAGE:-ghcr.io/taipanbox/vouchryx:v0.2.0}" \
          keygen -out /out/idp -kid stack-single-demo-idp >/dev/null \
        || die "could not mint the demo issuer key"
      chown 65532:65532 delegation/idp.pem delegation/idp.jwks.json
      chmod 600 delegation/idp.pem
    else
      note "vouchryx: demo issuer already present, reused"
    fi
    VOUCHRYX_TRUSTED_ISSUERS="https://idp.stack-single.local|stack-single|/etc/vouchryx/idp.jwks.json"
  fi
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
  [ -z "${WITH_DELEGATION:-}" ] || profiles+=(--profile delegation)
  pulled=0
  while read -r img; do
    case "$img" in
      ghcr.io/*)
        note "pulling $img"
        docker pull -q "$img" >/dev/null || die "could not pull $img"
        pulled=$((pulled + 1))
        ;;
    esac
  done < <("${COMPOSE[@]}" "${profiles[@]}" config --images 2>/dev/null | sort -u)
  # A pull loop that pulled nothing is the failure this catches, and it is not
  # hypothetical: `config --images` printing an empty list, or every line
  # missing the `ghcr.io/` prefix after a rename, both leave every plane absent
  # while every line above still reads as success.
  [ "$pulled" -gt 0 ] || die "no ghcr.io image was pulled; compose named none. Is compose.yaml the one this installer shipped?"
  note "pulled $pulled published image(s); nothing was compiled"
fi

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
chown 65532:65532 delegation
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
[ -z "${WITH_DELEGATION:-}" ] || UP_PROFILES+=(--profile delegation)

# Delegation needs a head start, the same reason `stack-up` starts vouchryx
# before its own gateway (README, "Delegation: a proved chain"): the gateway
# reads TOKENFUSE_DELEGATION_JWKS once, at startup, and that file has to hold
# vouchryx's OWN live keys, fetched from its running `/.well-known/jwks.json`,
# never vouchryx-demo's own keygen output (the `kid` trap named on the
# gateway's own compose block). So vouchryx comes up alone first, this run
# fetches its JWKS onto disk, and only then does the gateway start for the
# first time with that file already in place.
if [ -n "${WITH_DELEGATION:-}" ]; then
  say "vouchryx"
  "${COMPOSE[@]}" --profile delegation up -d vouchryx
  # Not published to the host (compose.yaml's own comment on the vouchryx
  # service says why), so this is fetched from inside the compose network,
  # the same throwaway-busybox shape section 8 uses for every other
  # container-side probe here. `agent-stack_default`: the fixed network name
  # `name: agent-stack` in compose.yaml produces, the same literal section 8
  # uses as `$NET`.
  fetched=0
  left=15
  while [ "$left" -gt 0 ]; do
    if docker run --rm --network agent-stack_default busybox:1.36 wget -q -T5 -O - \
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
fi

"${COMPOSE[@]}" "${UP_PROFILES[@]}" up -d --remove-orphans
# `up --remove-orphans` does not remove a container whose profile this run does
# not name (measured 2026-10-04 on Docker Desktop's compose v2: a proxy started
# under typed-risk-signal kept running through an `up` without it). So turning
# the signal off, or typed answers off, has to remove the proxy by name, or "off"
# would leave it running beside a broker that no longer points at it. A box that
# never had one has nothing to remove, which is why the failure is ignored.
if [ "$TYPED_PLANE" = off ] || [ "$TYPED_RISK_ON" != 1 ]; then "${COMPOSE[@]}" --profile typed-risk-signal rm -sf typryx-wardryx-proxy >/dev/null 2>&1 || true; fi
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
    if eval "$2" >/dev/null 2>&1; then printf '   ok    %s\n' "$1"; return 0; fi
    sleep 1; left=$((left - 1))
  done
  printf '   FAIL  %s\n' "$1"; fail=$((fail+1))
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
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
probe() { docker run --rm --network "$NET" busybox:1.36 wget -q -T5 -O /dev/null "$1"; }
# Prints the HTTP status only, so a check can assert 401 and 403 as PASSES.
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
code() { docker run --rm --network "$NET" busybox:1.36 \
           wget -S -q -T5 -O /dev/null --header="Authorization: Bearer $2" "$1" 2>&1 \
         | awk '/^  HTTP\//{c=$2} END{print c+0}'; }
# Same as code(), minus the header entirely: an empty bearer token is still a
# credential, and the point of this one is that none was presented at all.
# shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
codenokey() { docker run --rm --network "$NET" busybox:1.36 \
           wget -S -q -T5 -O /dev/null "$1" 2>&1 \
         | awk '/^  HTTP\//{c=$2} END{print c+0}'; }

# Where the gateway is probed: the address the operator chose, not loopback.
# With GATEWAY_BIND set to ONE address (a tailnet address is the shape an
# appliance wants: reachable from the customer's clouds over a private mesh,
# not from the LAN) Docker publishes on that address only, so loopback
# refuses, and this line read FAIL twice on a healthy box while the same probe
# against that address answered 200 and "published on $GATEWAY_BIND only"
# below passed (#54, measured 2026-09-17). GATEWAY_PROBE itself is computed
# once, at the top of this file, alongside GATEWAY_BIND.
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
check "policy plane accepts its admin key"   "[ \"\$(code http://wardryx:8090/v1/policies '$WARDRYX_ADMIN')\" = 200 ]"
check "policy plane rejects an unknown key"  "[ \"\$(code http://wardryx:8090/v1/policies nonsense-not-a-key)\" = 401 ]"
check "gateway's key cannot write policy"    "[ \"\$(code http://wardryx:8090/v1/policies '$WARDRYX_GATEWAY')\" = 403 ]"

# The gateway's own admin key, the same shape of check for the same reason:
# this one MUST fail to pass, exactly like the "not reachable from the host"
# checks below. A gateway that answers /v1/runs to nobody in particular has
# reopened the routes TOKENFUSE_ALLOW_OPEN_OBS used to hold open on purpose.
check "gateway refuses /v1/runs without the admin key" \
      "c=\$(codenokey http://tokenfuse-gateway:4100/v1/runs); case \"\$c\" in 401|403) true ;; *) false ;; esac"
check "gateway serves /v1/runs with the admin key" \
      "[ \"\$(code http://tokenfuse-gateway:4100/v1/runs '$GATEWAY_ADMIN')\" = 200 ]"

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
check "chain verifier can write its own stream" \
      "docker run --rm --user 10002:10002 -v agent-stack_events:/e busybox:1.36 sh -c ': >> /e/agent-conform.ndjson'"
check "chain verifier cannot write another plane's stream" \
      "! docker run --rm --user 10002:10002 -v agent-stack_events:/e busybox:1.36 sh -c ': >> /e/wardryx.ndjson'"
check "chain verifier cannot create a file on the bus" \
      "! docker run --rm --user 10002:10002 -v agent-stack_events:/e busybox:1.36 sh -c ': > /e/not-its-own.ndjson'"

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
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx console; then
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
  # Resolving the planes is still not the bus. The console keeps its history
  # in a store it has to CREATE at startup; with TAIPAN_HOME pointed at a
  # root-owned config directory it could not, logged one line and served on
  # with an empty Bus Explorer, on every install from 2026-08-31 to
  # 2026-09-14, and the two checks above were green throughout (genaryx#71,
  # #49). The console's own startup line is the only place this shows.
  check_log "console's bus is live" \
        "$DC logs console 2>&1 | grep -q 'bus LIVE' && ! $DC logs console 2>&1 | grep -q 'bus startup failed'"
fi

# The typed plane's own door, only when WITH_TYPED actually brought it up
# (section 5): a check that asked a service nothing started would prove
# nothing, the same reasoning every other opt-in check here follows.
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx tokenfuse-mcp-broker; then
  # Not `docker compose exec ... curl`: the same reason as the money and
  # policy planes above, this image has neither curl nor a shell. The MCP
  # wire is JSON-RPC over HTTP, so this is one wget POST with the right
  # headers, from the same throwaway busybox that probes everything else
  # here.
  # shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
  mcp_status() { # url, key (may be empty), method
    local url="$1" key="${2:-}" method="$3"
    local hdrs=(--header="Content-Type: application/json" --header="X-Fuse-Mcp-Upstream: typryx")
    [ -n "$key" ] && hdrs+=(--header="x-fuse-key: $key")
    docker run --rm --network "$NET" busybox:1.36 wget -S -q -T5 -O /dev/null \
        "${hdrs[@]}" --post-data="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\"}" "$url" 2>&1 \
      | awk '/^  HTTP\//{c=$2} END{print c+0}'
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
    local hdrs=(--header="Content-Type: application/json" --header="X-Fuse-Mcp-Upstream: typryx" --header="x-fuse-key: $2")
    # With the typed risk signal on, the broker is a policy enforcement point
    # and judges only a call it can attribute: without x-fuse-agent-id it
    # refuses, which is the right answer for an unattributed call and the wrong
    # one for this check. Off, the request is byte for byte what it always was.
    if [ "$TYPED_RISK_ON" = 1 ]; then hdrs+=(--header="x-fuse-agent-id: agent://local.invalid/install-check"); fi
    docker run --rm --network "$NET" busybox:1.36 wget -q -T5 -O - \
        "${hdrs[@]}" \
        --post-data='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"template":"eval.outcome_met","state":{"task":"2+2","final_answer":"4"}},"_meta":{"typryx/key":"{{secret:typryx_key}}"}}}' \
        "$1" 2>/dev/null | grep -q '"isError":false'
  }
  if [ "$TYPED_PLANE" = jev ]; then
    # Not asked on purpose: this ask would go to TypeSafe's API, on every run
    # of this installer, spending on the operator's account and sending them a
    # question they did not write. typryx refuses to start on a missing or
    # empty key file (exit 2), so "typryx is running" below is what a wrong
    # key PATH looks like; a wrong key VALUE shows on the first real ask.
    note "jev: the ask check is skipped, it would send a question to TypeSafe and spend on every run"
  else
    check "typed plane: an ask through the broker is answered" \
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
  # It does NOT answer from the default network and is not on the host: both
  # must fail to pass, because the proxy runs without a credential and who can
  # reach it is its only protection. And only the broker's policy client was
  # pointed at it: the LLM gateway keeps asking wardryx directly.
  if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx typryx-wardryx-proxy; then
    # shellcheck disable=SC2329,SC2317  # invoked indirectly: passed as a string to `check`
    risk_probe() { docker run --rm --network agent-stack_risk-signal busybox:1.36 wget -q -T5 -O /dev/null "$1"; }
    check "typed risk signal: the proxy answers on its own network" \
          "risk_probe http://typryx-wardryx-proxy:4330/healthz"
    check "typed risk signal: the proxy is NOT reachable from the default network" \
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
      check_log "typed risk signal: a tool call's decision carries typryx's signal" \
            "docker run --rm -v agent-stack_events:/e:ro busybox:1.36 grep -q action.risk_class /e/wardryx.ndjson"
    else
      note "$TYPED_PLANE: whether a signal arrives is not checked, it depends on the backend answering inside the proxy's deadline"
    fi
  fi
  # Must fail to pass, like the admin-key checks above: a call this broker
  # would forward with nobody's key on it is the same open door those checks
  # exist to catch on a different plane.
  check "typed plane: a tools/call with no broker key is refused" \
        "c=\$(mcp_status http://tokenfuse-mcp-broker:4200/mcp '' tools/call); case \"\$c\" in 401|403) true ;; *) false ;; esac"
  say "the typed plane, through tokenfuse's MCP broker"
  note "an agent reaches typryx at http://<this box>:4200/mcp ($GATEWAY_BIND unless you widen it)"
  note "  with the header X-Fuse-Mcp-Upstream: typryx and its own client key in x-fuse-key"
  note "  a tools/call then carries the typed-plane credential as"
  note "  \"_meta\":{\"typryx/key\":\"{{secret:typryx_key}}\"}, never a real key value"
  if [ "$TYPED_RISK_ON" = 1 ]; then
    note "the typed risk signal is ON: each tools/call also needs the header x-fuse-agent-id, because the"
    note "  broker now asks wardryx about it (through typryx's proxy) and refuses a call it cannot attribute."
    note "  Nothing holds a call for a person until you add a hold_if_signal rule to policy.yaml (README)."
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

# The delegation plane's own checks, only when WITH_DELEGATION actually
# brought vouchryx up: the same reasoning as the typed plane above, a check
# that asked a service nothing started would prove nothing.
if "${COMPOSE[@]}" ps --services 2>/dev/null | grep -qx vouchryx; then
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

# The report below uses A && echo X || echo Y inside a substitution. C is `echo`,
# which does not fail, so it is a plain ternary rather than the trap SC2015 warns
# about. It cannot be silenced inside the heredoc: text in there is printed, not
# parsed as comments.
# shellcheck disable=SC2015
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
