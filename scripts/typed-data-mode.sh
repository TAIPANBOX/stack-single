#!/usr/bin/env bash
#
# Enforces invariant 18 of CLAUDE.md: the operator chooses where typed answers
# come from, and that choice is made before anything is touched, never by
# default, and never by carrying a key as a value.
#
# WHAT THIS IS ABOUT
#
# `WITH_TYPED=1` used to give one thing, typryx on its stub backend. Since
# TYPED_MODE there are three data modes an operator picks between:
#
#   jev        the named fields of each question go to TypeSafe's hosted API;
#              needs TYPED_JEV_KEY_FILE, a PATH to a file holding the key
#   own-model  a model server the operator runs (Ollama, vLLM); needs
#              TYPED_MODEL_URL (ending in /v1) and TYPED_MODEL_NAME
#   off        typryx is not installed (the default)
#
# and WITH_TYPED=1 with no TYPED_MODE keeps the stub exactly as before.
#
# WHAT THIS CHECKS
#
#   A. BEHAVIOUR. The functions between `# typed-mode: begin` and
#      `# typed-mode: end` in install.sh are lifted out and run, in a scratch
#      STACK_DIR, for every case that matters: nothing set stays off and leaves
#      .env untouched; WITH_TYPED=1 alone is the stub, untouched; jev with no
#      key file, a missing one, an empty one, or the key passed as the VALUE
#      each refuse (and the last never echoes what it was given); own-model
#      with no URL, a URL not ending in /v1, or no model each refuse; a good
#      jev and a good own-model run write what compose reads; the key's bytes
#      never appear in .env or in a single line of output; a re-run with
#      nothing set changes nothing; switching mode drops the old mode's lines.
#   B. COMPOSE. `docker compose config` for the default, the stub, jev and
#      own-model: typryx is absent without its profile; the backend and the
#      key FILE PATH are what each mode says; ./typed is mounted read only; and
#      a fake key placed in the mounted file appears nowhere in the resolved
#      configuration.
#   C. STATIC. install.sh passes `--profile typed` only on a line decided by
#      TYPED_PLANE, so the profile is never brought up unconditionally.
#   D. THE TRAINING LOG AND THE PIN. `TYPED_TRAINING=1` (off by default) is the
#      one switch for typryx's opt-in local training log. Off, nothing names
#      TYPRYX_TRAINING_DIR anywhere (.env, the resolved configuration). On, it
#      names a directory inside the typryxdata volume, mounted writable, beside
#      the ledger that holds the human truths the export needs; on with no
#      typryx to log, or with a value that is not 1 or 0, it refuses before
#      touching the box. And every typryx image pin is ONE tag, the one
#      compose.yaml defaults to (v0.4.0 now: the log needs v0.3.0 or later, and the
#      risk-signal proxy v0.4.0, see typed-risk-signal.sh).
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No markers, no `typed_resolve`/`typed_apply`, no `--profile typed` line, no
# typryx service in the resolved configuration, or no Docker to resolve it
# with: each is reported and fails. A gate that could not run its subject must
# not read as one that found nothing wrong.
#
# This file is the ONE copy of this check. CI and the pre-push hook call it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

FAKEKEY="tj_test_FAKE_not_a_real_key_9f3a1c77d20b"

# ---- A. behaviour ------------------------------------------------------------
BLOCK="$(sed -n '/^# typed-mode: begin$/,/^# typed-mode: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# typed-mode: begin' .. '# typed-mode: end' block, so this measured nothing about the typed data mode"
elif ! printf '%s' "$BLOCK" | grep -q '^typed_resolve()' || ! printf '%s' "$BLOCK" | grep -q '^typed_apply()'; then
  fail "the typed-mode block defines no typed_resolve or no typed_apply, so this measured nothing"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT

  # mk: a fresh STACK_DIR holding only a sentinel .env, the way a box that
  # already ran install.sh once looks to this block.
  mk() {
    local d
    d="$(mktemp -d "$scratch/box.XXXXXX")"
    printf 'SENTINEL=1\n' >"$d/.env"
    chmod 600 "$d/.env"
    printf '%s' "$d"
  }
  # run DIR [VAR=value ...]: resolve then apply, exactly as install.sh does,
  # with say/note/die stubbed. Prints everything the block said, then rc.
  run() {
    local d="$1"
    shift
    (
      cd "$d" || exit 99
      env -i PATH="$PATH" HOME="$d" STACK_DIR="$d" BLOCK="$BLOCK" "$@" bash -c '
        set -euo pipefail
        say() { :; }
        note() { printf "note: %s\n" "$*"; }
        die() { printf "die: %s\n" "$*"; exit 1; }
        chown() { :; }
        eval "$BLOCK"
        typed_resolve
        typed_apply
        printf "plane=%s\n" "$TYPED_PLANE"'
      printf 'rc=%s\n' "$?"
    ) 2>&1
  }
  plane_of() { printf '%s' "$1" | sed -n 's/^plane=//p'; }
  rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
  envhas() { grep -q -- "$2" "$1/.env"; }

  refuses() { # name dir needle VAR=...
    local name="$1" d="$2" needle="$3" out
    shift 3
    out="$(run "$d" "$@")"
    if [ "$(rc_of "$out")" = 0 ]; then
      fail "$name: it was accepted, and it must refuse"
    elif ! printf '%s' "$out" | grep -qF -- "$needle"; then
      fail "$name: it refused, but not saying '$needle'"
    elif [ "$(cat "$d/.env")" != "SENTINEL=1" ] || [ -e "$d/typed" ]; then
      fail "$name: it refused AFTER touching the box (.env or typed/ changed), which is half a job"
    fi
    if printf '%s' "$out" | grep -qF -- "$FAKEKEY"; then
      fail "$name: its refusal echoed the key it was given"
    fi
  }

  # 1. nothing set: off, and the box is left exactly as it was.
  d="$(mk)"
  out="$(run "$d")"
  [ "$(plane_of "$out")" = off ] || fail "nothing set: the plane is '$(plane_of "$out")', not off"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "nothing set: .env was changed"
  [ ! -e "$d/typed" ] || fail "nothing set: typed/ was created on a box that never asked for typed answers"

  # 2. WITH_TYPED=1 alone: the stub, as before TYPED_MODE existed.
  d="$(mk)"
  out="$(run "$d" WITH_TYPED=1)"
  [ "$(plane_of "$out")" = stub ] || fail "WITH_TYPED=1 alone: the plane is '$(plane_of "$out")', not stub"
  [ "$(cat "$d/.env")" = "SENTINEL=1" ] || fail "WITH_TYPED=1 alone: .env was changed, so it is no longer today's behaviour"
  printf '%s' "$out" | grep -q 'stub' || fail "WITH_TYPED=1 alone: it does not say it is the stub backend"

  # 3. off wins over WITH_TYPED, and says so.
  d="$(mk)"
  out="$(run "$d" WITH_TYPED=1 TYPED_MODE=off)"
  [ "$(plane_of "$out")" = off ] || fail "TYPED_MODE=off with WITH_TYPED=1: the plane is '$(plane_of "$out")', not off"
  envhas "$d" "^TYPED_MODE='off'" || fail "TYPED_MODE=off was not recorded in .env, so the question would be asked again"

  # 4. an unknown mode, and stub is not a mode an operator can name.
  refuses "TYPED_MODE=stub" "$(mk)" "TYPED_MODE must be" TYPED_MODE=stub
  refuses "TYPED_MODE=yes" "$(mk)" "TYPED_MODE must be" TYPED_MODE=yes

  # 5. settings with no mode are not silently ignored.
  refuses "a key file with no mode" "$(mk)" "TYPED_MODE" TYPED_JEV_KEY_FILE=/nonexistent

  # 6. jev: every way of having no usable key.
  refuses "jev with no key file" "$(mk)" "TYPED_JEV_KEY_FILE" TYPED_MODE=jev
  refuses "jev with a missing key file" "$(mk)" "TYPED_JEV_KEY_FILE" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/none"
  : >"$scratch/empty"
  refuses "jev with an empty key file" "$(mk)" "TYPED_JEV_KEY_FILE" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/empty"
  printf ' \n\t\n' >"$scratch/blank"
  refuses "jev with a blank key file" "$(mk)" "TYPED_JEV_KEY_FILE" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/blank"
  refuses "jev with the key passed as the value" "$(mk)" "TYPED_JEV_KEY_FILE" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$FAKEKEY"

  # 7. jev, a good key file.
  printf '%s\n' "$FAKEKEY" >"$scratch/jev.key"
  d="$(mk)"
  out="$(run "$d" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/jev.key")"
  [ "$(rc_of "$out")" = 0 ] || fail "jev with a good key file was refused: $out"
  [ "$(plane_of "$out")" = jev ] || fail "jev: the plane is '$(plane_of "$out")'"
  envhas "$d" "^TYPED_MODE='jev'" || fail "jev: TYPED_MODE is not in .env"
  envhas "$d" "^TYPRYX_BACKEND='jev'" || fail "jev: TYPRYX_BACKEND=jev is not in .env"
  envhas "$d" "^TYPRYX_JEV_KEY_FILE='/run/typed/jev-key'" || fail "jev: TYPRYX_JEV_KEY_FILE is not the container path of the mounted key"
  if [ ! -f "$d/typed/jev-key" ] || ! cmp -s "$scratch/jev.key" "$d/typed/jev-key"; then
    fail "jev: typed/jev-key is not a copy of the key file, so the container would have nothing to read"
  fi
  mode="$(stat -c '%a' "$d/typed/jev-key" 2>/dev/null || stat -f '%Lp' "$d/typed/jev-key")"
  [ "$mode" = 400 ] || fail "jev: typed/jev-key is mode $mode, not 400"
  if grep -rqF -- "$FAKEKEY" "$d/.env"; then fail "jev: the key's bytes are in .env"; fi
  if printf '%s' "$out" | grep -qF -- "$FAKEKEY"; then fail "jev: the key's bytes were printed"; fi
  if grep -q 'TYPRYX_JEV_KEY=' "$d/.env"; then fail "jev: the key is passed as an environment VALUE (TYPRYX_JEV_KEY)"; fi
  before="$(cat "$d/.env")"
  # 8. the re-run: nothing set, nothing changes, still jev (invariant 2).
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && [ "$(plane_of "$out")" = jev ] || fail "jev re-run with nothing set: $out"
  [ "$(cat "$d/.env")" = "$before" ] || fail "jev re-run with nothing set: .env changed"
  # 9. ...and a re-run that lost the key copy refuses rather than starting a typryx that cannot read one.
  rm -f "$d/typed/jev-key"
  refused="$(run "$d")"
  if [ "$(rc_of "$refused")" = 0 ]; then fail "jev re-run with the key copy gone was accepted"; fi
  # 10. a persisted off does not beat an explicit WITH_TYPED=1.
  d="$(mk)"
  run "$d" TYPED_MODE=off >/dev/null
  out="$(run "$d" WITH_TYPED=1)"
  [ "$(plane_of "$out")" = stub ] || fail "saved off plus WITH_TYPED=1: the plane is '$(plane_of "$out")', not stub"

  # 11. own-model: every way of not having a server.
  refuses "own-model with no URL" "$(mk)" "TYPED_MODEL_URL" TYPED_MODE=own-model TYPED_MODEL_NAME=qwen2.5:7b
  refuses "own-model with a URL not ending in /v1" "$(mk)" "/v1" TYPED_MODE=own-model TYPED_MODEL_NAME=m TYPED_MODEL_URL=http://h:11434
  refuses "own-model with credentials in the URL" "$(mk)" "/v1" TYPED_MODE=own-model TYPED_MODEL_NAME=m TYPED_MODEL_URL=http://u:p@h:11434/v1
  refuses "own-model with no model name" "$(mk)" "TYPED_MODEL_NAME" TYPED_MODE=own-model TYPED_MODEL_URL=http://h:11434/v1
  refuses "own-model with a missing key file" "$(mk)" "TYPED_MODEL_KEY_FILE" TYPED_MODE=own-model TYPED_MODEL_URL=http://h:11434/v1 TYPED_MODEL_NAME=m TYPED_MODEL_KEY_FILE="$scratch/none"

  # 12. own-model, good, with and without a key.
  d="$(mk)"
  out="$(run "$d" TYPED_MODE=own-model TYPED_MODEL_URL=http://host.docker.internal:11434/v1 TYPED_MODEL_NAME=qwen2.5:7b)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(plane_of "$out")" = own-model ] || fail "own-model with URL and name: $out"
  envhas "$d" "^TYPRYX_BACKEND='openai-logprobs'" || fail "own-model: TYPRYX_BACKEND is not openai-logprobs"
  envhas "$d" "^TYPRYX_OPENAI_URL='http://host.docker.internal:11434/v1'" || fail "own-model: TYPRYX_OPENAI_URL is not the URL given"
  envhas "$d" "^TYPRYX_OPENAI_MODEL='qwen2.5:7b'" || fail "own-model: TYPRYX_OPENAI_MODEL is not the name given"
  envhas "$d" "^TYPRYX_TIMEOUT_MS='30000'" || fail "own-model: no timeout sized for a model on a CPU (the default 2000 ms is below a measured p50 of 2130 ms)"
  if grep -q 'TYPRYX_OPENAI_KEY_FILE' "$d/.env"; then fail "own-model with no key file still names one"; fi
  # switching mode drops the old mode's lines, and the key it no longer uses is not named
  printf '%s\n' "$FAKEKEY" >"$scratch/model.key"
  out="$(run "$d" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/jev.key")"
  if grep -q 'TYPRYX_OPENAI_URL\|TYPRYX_OPENAI_MODEL\|openai-logprobs' "$d/.env"; then fail "switching own-model to jev left the own-model lines in .env"; fi
  d="$(mk)"
  out="$(run "$d" TYPED_MODE=own-model TYPED_MODEL_URL=http://h:8000/v1 TYPED_MODEL_NAME=m TYPED_MODEL_KEY_FILE="$scratch/model.key")"
  [ "$(rc_of "$out")" = 0 ] || fail "own-model with a key file was refused: $out"
  envhas "$d" "^TYPRYX_OPENAI_KEY_FILE='/run/typed/model-key'" || fail "own-model: the key file is not named by its container path"
  cmp -s "$scratch/model.key" "$d/typed/model-key" || fail "own-model: typed/model-key is not a copy of the key file"
  if grep -qF -- "$FAKEKEY" "$d/.env"; then fail "own-model: the key's bytes are in .env"; fi
  if printf '%s' "$out" | grep -qF -- "$FAKEKEY"; then fail "own-model: the key's bytes were printed"; fi
  # the re-run that changes only the URL keeps the mode
  out="$(run "$d" TYPED_MODEL_URL=http://h:9000/v1)"
  [ "$(plane_of "$out")" = own-model ] && envhas "$d" "^TYPRYX_OPENAI_URL='http://h:9000/v1'" || fail "own-model re-run with a new URL: $out"

  # 13. the training log (D). Off by default: no mode, good or stub, writes it.
  d="$(mk)"
  run "$d" WITH_TYPED=1 >/dev/null
  if grep -q 'TRAINING' "$d/.env"; then fail "WITH_TYPED=1 alone names a training log in .env"; fi
  d="$(mk)"
  run "$d" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/jev.key" >/dev/null
  if grep -q 'TRAINING' "$d/.env"; then fail "jev with no TYPED_TRAINING names a training log in .env"; fi
  d="$(mk)"
  run "$d" TYPED_MODE=own-model TYPED_MODEL_URL=http://h:8000/v1 TYPED_MODEL_NAME=m >/dev/null
  if grep -q 'TRAINING' "$d/.env"; then fail "own-model with no TYPED_TRAINING names a training log in .env"; fi
  # on: a path inside the typryxdata volume (compose mounts it at /var/lib/typryx), for each mode
  d="$(mk)"
  out="$(run "$d" WITH_TYPED=1 TYPED_TRAINING=1)"
  [ "$(rc_of "$out")" = 0 ] && [ "$(plane_of "$out")" = stub ] || fail "WITH_TYPED=1 TYPED_TRAINING=1: $out"
  envhas "$d" "^TYPRYX_TRAINING_DIR='/var/lib/typryx/training'" || fail "TYPED_TRAINING=1 (stub) did not write TYPRYX_TRAINING_DIR"
  d="$(mk)"
  out="$(run "$d" TYPED_MODE=jev TYPED_JEV_KEY_FILE="$scratch/jev.key" TYPED_TRAINING=1)"
  [ "$(rc_of "$out")" = 0 ] || fail "jev with TYPED_TRAINING=1 was refused: $out"
  envhas "$d" "^TYPRYX_TRAINING_DIR='/var/lib/typryx/training'" || fail "TYPED_TRAINING=1 (jev) did not write TYPRYX_TRAINING_DIR"
  if grep -qF -- "$FAKEKEY" "$d/.env"; then fail "jev with training: the key's bytes are in .env"; fi
  before="$(cat "$d/.env")"
  # a re-run with nothing set keeps the log on and changes nothing (invariant 2)
  out="$(run "$d")"
  [ "$(rc_of "$out")" = 0 ] && [ "$(cat "$d/.env")" = "$before" ] || fail "a re-run with nothing set changed a box that had training on: $out"
  # switching mode keeps the log the operator asked for
  out="$(run "$d" TYPED_MODE=own-model TYPED_MODEL_URL=http://h:8000/v1 TYPED_MODEL_NAME=m)"
  [ "$(rc_of "$out")" = 0 ] || fail "own-model over a jev box with training on was refused: $out"
  envhas "$d" "^TYPRYX_TRAINING_DIR='/var/lib/typryx/training'" || fail "switching mode silently turned the training log off"
  # and TYPED_TRAINING=0 turns it off again, and only it
  out="$(run "$d" TYPED_TRAINING=0)"
  [ "$(rc_of "$out")" = 0 ] || fail "TYPED_TRAINING=0 was refused: $out"
  if grep -q 'TRAINING' "$d/.env"; then fail "TYPED_TRAINING=0 left TYPRYX_TRAINING_DIR in .env"; fi
  envhas "$d" "^TYPRYX_BACKEND='openai-logprobs'" || fail "TYPED_TRAINING=0 changed the mode's own lines"
  # it refuses, before touching the box, when there is no typryx to log or the value is not a switch
  refuses "training with no typryx" "$(mk)" "TYPED_TRAINING" TYPED_TRAINING=1
  refuses "training with typryx explicitly off" "$(mk)" "TYPED_TRAINING" TYPED_MODE=off WITH_TYPED=1 TYPED_TRAINING=1
  refuses "TYPED_TRAINING=yes" "$(mk)" "TYPED_TRAINING" WITH_TYPED=1 TYPED_TRAINING=yes
fi

# ---- C. static: the profile is never brought up unconditionally --------------
hits="$(grep -n -- '--profile typed' install.sh | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [ -z "$hits" ]; then
  fail "install.sh never passes --profile typed, so this measured nothing about how it is gated"
else
  while IFS= read -r l; do
    case "$l" in
      *TYPED_PLANE*) ;;
      *) fail "install.sh:${l%%:*} passes --profile typed on a line TYPED_PLANE does not decide: ${l#*:}" ;;
    esac
  done <<<"$hits"
fi

# ---- D. one typryx pin ---------------------------------------------------------
# Every `typryx:vX.Y.Z` a live file names is the tag compose.yaml defaults to.
# Release notes of earlier launcher versions are history and are not read.
pin="$(sed -n 's/.*ghcr\.io\/taipanbox\/typryx:\(v[0-9][0-9.]*\).*/\1/p' compose.yaml | head -1)"
if [ -z "$pin" ]; then
  fail "compose.yaml names no ghcr.io/taipanbox/typryx:vX.Y.Z image, so this measured nothing about the pin"
else
  [ "$pin" = v0.4.0 ] || fail "compose.yaml pins typryx $pin; the training log needs v0.3.0 or later, the risk-signal proxy v0.4.0, and this gate names v0.4.0"
  for f in compose.yaml components.json README.md install.sh; do
    while IFS= read -r t; do
      [ "$t" = "$pin" ] || fail "$f names typryx:$t, but compose.yaml pins typryx:$pin"
    done < <(grep -o 'typryx:v[0-9][0-9.]*' "$f" | sed 's/^typryx://' | sort -u)
  done
  grep -q "ghcr.io/taipanbox/typryx:$pin" components.json || fail "components.json does not list ghcr.io/taipanbox/typryx:$pin in pulls_images"
fi

# ---- B. compose --------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d)"
  cp compose.yaml "$cdir/compose.yaml"
  mkdir -p "$cdir/typed"
  printf '%s\n' "$FAKEKEY" >"$cdir/typed/jev-key"
  # every variable compose demands (`:?`), with an obviously fake value
  {
    grep -o '\${[A-Z_]*:?' compose.yaml | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/'
    echo "TYPRYX_KEYS=fake-door-key=agent://local.invalid/default-agent"
  } >"$cdir/base.env"
  resolve() { # extra .env lines on stdin, profile flags in $@
    cat "$cdir/base.env" - >"$cdir/.env"
    docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" "$@" config --format json 2>"$cdir/err"
  }
  check_cfg() { # name, expect-json-python-snippet, compose args; stdin = env lines
    local name="$1" snippet="$2" cfg
    shift 2
    if ! cfg="$(resolve "$@")"; then
      fail "compose: $name: docker compose config failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
      return
    fi
    if ! printf '%s' "$cfg" | FAKEKEY="$FAKEKEY" python3 -c "
import json, os, sys
cfg = json.load(sys.stdin)
raw = json.dumps(cfg)
svc = cfg['services']
$snippet
" 2>"$cdir/pyerr"; then
      fail "compose: $name: $(tail -1 "$cdir/pyerr")"
    fi
  }

  check_cfg "without the typed profile there is no typryx" "
assert 'typryx' not in svc, 'typryx is in the default set'
assert 'tokenfuse-mcp-broker' not in svc, 'the broker is in the default set'
" </dev/null

  check_cfg "WITH_TYPED alone resolves to the stub" "
assert 'typryx' in svc, 'no typryx service in the resolved configuration with --profile typed, so this measured nothing'
e = svc['typryx']['environment']
assert e['TYPRYX_BACKEND'] == 'stub', 'backend is ' + e['TYPRYX_BACKEND']
assert not e.get('TYPRYX_JEV_KEY_FILE'), 'a jev key file is named on the stub'
assert not e.get('TYPRYX_TRAINING_DIR'), 'a training log is on by default: TYPRYX_TRAINING_DIR is ' + repr(e.get('TYPRYX_TRAINING_DIR'))
assert svc['typryx']['image'].endswith('/typryx:v0.4.0'), 'the typryx pin is ' + svc['typryx']['image']
" --profile typed </dev/null

  check_cfg "training on names a directory inside a writable volume, beside the ledger" "
assert 'typryx' in svc, 'no typryx service in the resolved configuration with --profile typed, so this measured nothing'
e = svc['typryx']['environment']
d = e.get('TYPRYX_TRAINING_DIR')
assert d == '/var/lib/typryx/training', 'TYPRYX_TRAINING_DIR is ' + repr(d) + ', so the log would not reach typryx'
led = e.get('TYPRYX_LEDGER_DIR')
assert led, 'no ledger: the export needs the human truths that live there'
vols = [v for v in svc['typryx'].get('volumes', []) if v.get('target') and (d + '/').startswith(v['target'].rstrip('/') + '/')]
assert vols, 'no volume holds ' + d + ', so the log would live in the container and vanish with it'
best = max(vols, key=lambda v: len(v['target']))
assert best.get('type') == 'volume' and not best.get('read_only'), 'the training log sits on a mount that is not a writable volume: ' + str(best)
assert best['target'] != '/run/typed', 'the training log is under the read-only key directory'
assert (led + '/').startswith(best['target'].rstrip('/') + '/'), 'the ledger and the training log are on different volumes: ' + str(best['target'])
" --profile typed <<'EOF'
TYPED_MODE='own-model'
TYPRYX_BACKEND='openai-logprobs'
TYPRYX_OPENAI_URL='http://host.docker.internal:11434/v1'
TYPRYX_OPENAI_MODEL='qwen2.5:7b'
TYPRYX_TRAINING_DIR='/var/lib/typryx/training'
EOF

  check_cfg "jev names the key FILE, mounts it read only, and carries no key value" "
assert 'typryx' in svc, 'no typryx service in the resolved configuration with --profile typed, so this measured nothing'
e = svc['typryx']['environment']
assert e['TYPRYX_BACKEND'] == 'jev', 'backend is ' + e['TYPRYX_BACKEND']
assert e['TYPRYX_JEV_KEY_FILE'] == '/run/typed/jev-key', 'key file is ' + e['TYPRYX_JEV_KEY_FILE']
m = [v for v in svc['typryx'].get('volumes', []) if v.get('target') == '/run/typed']
assert m, 'nothing is mounted at /run/typed'
assert m[0].get('type') == 'bind' and m[0].get('read_only') is True, 'the key mount is not a read-only bind: ' + str(m[0])
assert os.environ['FAKEKEY'] not in raw, 'the key file content appears in the resolved configuration'
" --profile typed <<'EOF'
TYPED_MODE='jev'
TYPRYX_BACKEND='jev'
TYPRYX_JEV_KEY_FILE='/run/typed/jev-key'
EOF

  check_cfg "own-model names the server, the model and the timeout" "
assert 'typryx' in svc, 'no typryx service in the resolved configuration with --profile typed, so this measured nothing'
e = svc['typryx']['environment']
assert e['TYPRYX_BACKEND'] == 'openai-logprobs', 'backend is ' + e['TYPRYX_BACKEND']
assert e['TYPRYX_OPENAI_URL'] == 'http://host.docker.internal:11434/v1', 'url is ' + e['TYPRYX_OPENAI_URL']
assert e['TYPRYX_OPENAI_MODEL'] == 'qwen2.5:7b', 'model is ' + e['TYPRYX_OPENAI_MODEL']
assert e['TYPRYX_TIMEOUT_MS'] == '30000', 'timeout is ' + e['TYPRYX_TIMEOUT_MS']
m = [v for v in svc['typryx'].get('volumes', []) if v.get('target') == '/run/typed']
assert m and m[0].get('read_only') is True, 'the key directory is not mounted read only'
eh = str(svc['typryx'].get('extra_hosts'))
assert 'host.docker.internal' in eh and 'host-gateway' in eh, 'host.docker.internal does not resolve on Linux'
" --profile typed <<'EOF'
TYPED_MODE='own-model'
TYPRYX_BACKEND='openai-logprobs'
TYPRYX_OPENAI_URL='http://host.docker.internal:11434/v1'
TYPRYX_OPENAI_MODEL='qwen2.5:7b'
TYPRYX_TIMEOUT_MS='30000'
EOF
  rm -rf "$cdir"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 18."
  exit 1
fi
echo "OK: typed answers are off unless chosen, WITH_TYPED=1 alone is still the stub, the training log"
echo "    is off unless TYPED_TRAINING=1 and lives beside the ledger, typryx is one pinned tag, jev and"
echo "    own-model refuse before touching the box when their inputs are missing, a key is only"
echo "    ever a file mounted read only (never a value, never printed), and a re-run changes nothing."
