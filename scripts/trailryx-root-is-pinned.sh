#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 60: the record seal pins the kid of custody's trailryx-root
# key set, taken once at install, and refuses to pin a set that does not hold exactly one ES384
# key. trailryx 1.5.0 refuses to start under the keyryx signer with no pin, so an install that
# cannot take one must say why, and must not take a guess.
#
# WHAT IT CHECKS
#   A. STATIC, install.sh. The `# trailryx-root-pin:` block defines trailryx_root_kid (which
#      reads GET /v1/jwks/trailryx-root from keyryx on the core network) and trailryx_pin_apply
#      (which writes TRAILRYX_KEYRYX_KID into .env once and keeps it on a re-run), and
#      trailryx_pin_apply runs before the record profile is first started.
#   B. COMPOSE. The record seal reads TRAILRYX_KEYRYX_KID from .env, so a pin the installer
#      wrote reaches the seal, and no TODO(trailryx#112) is left in compose.yaml.
#   C. BEHAVIOUR. The block runs with a stub docker serving fixture key sets: one ES384 key
#      gives its kid and nothing else is printed; zero, two, or a kid of the wrong shape is
#      refused with a reason and exit 3; an unreachable keyryx is exit 2 (retry); a pin already
#      in .env is kept with no fetch; a fresh pin is written once and the .env file keeps its mode.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  echo "trailryx-root-is-pinned: no compose.yaml or install.sh, so nothing was measured"
  exit 1
fi

BLOCK="$(sed -n '/^# trailryx-root-pin: begin$/,/^# trailryx-root-pin: end$/p' install.sh)"

# ---- A. install.sh, static -------------------------------------------------------------
if [ -z "$BLOCK" ]; then
  fail "A. install.sh has no '# trailryx-root-pin: begin' .. '# trailryx-root-pin: end' block, so the root pin was not measured"
else
  printf '%s\n' "$BLOCK" | grep -q '^trailryx_root_kid()' || fail "A. the block defines no trailryx_root_kid"
  printf '%s\n' "$BLOCK" | grep -q '^trailryx_pin_apply()' || fail "A. the block defines no trailryx_pin_apply"
  printf '%s\n' "$BLOCK" | grep -q '/v1/jwks/trailryx-root' || fail "A. the block does not read keyryx's trailryx-root key set (/v1/jwks/trailryx-root)"
  first_record_up="$(grep -n 'UP_PROFILES\[@\]}" up -d --remove-orphans' install.sh | head -1 | cut -d: -f1)"
  pin_call="$(grep -n '^trailryx_pin_apply$' install.sh | head -1 | cut -d: -f1)"
  if [ -z "$pin_call" ]; then
    fail "A. install.sh never calls trailryx_pin_apply, so the record seal would start with no pin"
  elif [ -z "$first_record_up" ] || [ "$pin_call" -ge "$first_record_up" ]; then
    fail "A. trailryx_pin_apply (line ${pin_call:-?}) does not run before the main up (line ${first_record_up:-?})"
  fi
fi

# ---- B. compose.yaml -----------------------------------------------------------------------
grep -qE '^      TRAILRYX_KEYRYX_KID: \$\{TRAILRYX_KEYRYX_KID:-\}$' compose.yaml \
  || fail "B. record-seal does not read TRAILRYX_KEYRYX_KID from .env (expected TRAILRYX_KEYRYX_KID: \${TRAILRYX_KEYRYX_KID:-})"
grep -q 'TODO(trailryx#112)' compose.yaml && fail "B. compose.yaml still names TODO(trailryx#112): the pin is wired now"

# ---- C. install.sh, behaviour ----------------------------------------------------------------
if [ -n "$BLOCK" ] && printf '%s\n' "$BLOCK" | grep -q '^trailryx_root_kid()'; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mkdir -p "$scratch/bin" "$scratch/stack"
  calls="$scratch/calls"
  : >"$calls"
  # A stub docker: every call is logged; `run ... wget` prints $JWKS_BODY_FILE, or fails when it is absent.
  cat >"$scratch/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS_LOG"
case "$*" in
  *wget*)
    [ -n "${JWKS_BODY_FILE:-}" ] && [ -f "$JWKS_BODY_FILE" ] || exit 1
    cat "$JWKS_BODY_FILE" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$scratch/bin/docker"
  K1="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  K2="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  ONE_ES='{"keys":[{"kty":"EC","crv":"P-384","alg":"ES384","kid":"'"$K1"'","x":"XCOORD-ONE","y":"YCOORD-ONE"},{"kty":"EC","alg":"mldsa65","kid":"mldsa65:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}]}'
  NO_ES='{"keys":[{"alg":"ML-DSA-65","kid":"mldsa65:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}]}'
  TWO_ES='{"keys":[{"alg":"ES384","kid":"'"$K1"'","x":"XCOORD-A"},{"alg":"ES384","kid":"'"$K2"'","x":"XCOORD-B"}]}'
  BAD_SHAPE='{"keys":[{"alg":"ES384","kid":"short-kid","x":"XCOORD-C"}]}'
  run_kid() { # BODY: prints the function's stdout, its exit, and its stderr
    local body="$scratch/jwks.body" out err rc
    printf '%s' "$1" >"$body"
    out="$(env -i PATH="$scratch/bin:/usr/bin:/bin" HOME="$scratch" BLOCK="$BLOCK" CALLS_LOG="$calls" JWKS_BODY_FILE="$body" \
      bash -c '
        set -uo pipefail
        die() { printf "die: %s\n" "$*" >&2; exit 3; }
        note() { :; }
        COMPOSE=(docker compose)
        eval "$BLOCK"
        trailryx_root_kid
      ' 2>"$scratch/err")"
    rc=$?
    err="$(cat "$scratch/err")"
    printf '%s\n--rc=%s\n--err=%s\n' "$out" "$rc" "$err"
  }
  export BLOCK
  one="$(run_kid "$ONE_ES")"
  printf '%s' "$one" | grep -qx -- "$K1" || fail "C. one ES384 key: the kid is not printed alone (got: $(printf '%s' "$one" | head -1))"
  printf '%s' "$one" | grep -q 'XCOORD-ONE\|YCOORD' && fail "C. the key's coordinates were printed: only the kid may leave the function"
  printf '%s' "$one" | grep -q -- '--rc=0' || fail "C. one ES384 key was not accepted (exit is not 0)"
  none="$(run_kid "$NO_ES")"
  printf '%s' "$none" | grep -q -- '--rc=3' || fail "C. a set with no ES384 key was not refused with exit 3"
  printf '%s' "$none" | grep -q 'ES384' || fail "C. the refusal for no ES384 key gives no reason naming ES384"
  two="$(run_kid "$TWO_ES")"
  printf '%s' "$two" | grep -q -- '--rc=3' || fail "C. a set with two ES384 keys was not refused (a rotation must be done on purpose, by deleting the pin)"
  shape="$(run_kid "$BAD_SHAPE")"
  printf '%s' "$shape" | grep -q -- '--rc=3' || fail "C. an ES384 kid of the wrong shape was not refused"
  unreach="$(run_kid "")"
  printf '%s' "$unreach" | grep -q -- '--rc=2' || fail "C. an unreachable keyryx was not reported as retryable (exit 2)"

  # The pin: kept when present, written once when absent, and refused sets write nothing.
  pin_run() { # ENV_CONTENT BODY: runs trailryx_pin_apply in a fresh STACK_DIR; prints rc and the .env
    local sd="$scratch/stack.$RANDOM"
    mkdir -p "$sd"
    printf '%s\n' "$1" >"$sd/.env"
    chmod 0600 "$sd/.env"
    printf '%s' "$2" >"$scratch/jwks.body"
    : >"$calls"
    env -i PATH="$scratch/bin:/usr/bin:/bin" HOME="$scratch" BLOCK="$BLOCK" CALLS_LOG="$calls" JWKS_BODY_FILE="$scratch/jwks.body" \
      STACK_DIR="$sd" RECORD_ON="${RECORD:-1}" bash -c '
        set -uo pipefail
        die() { printf "die: %s\n" "$*" >&2; exit 3; }
        note() { :; }
        COMPOSE=(docker compose)
        eval "$BLOCK"
        trailryx_pin_apply
      ' >/dev/null 2>"$sd/err"
    printf 'rc=%s\n' "$?"
    cat "$sd/.env"
    printf 'mode=%s\n' "$(stat -c %a "$sd/.env" 2>/dev/null || stat -f %Lp "$sd/.env")"
    printf 'fetches=%s\n' "$(grep -c wget "$calls")"
  }
  kept="$(pin_run 'TRAILRYX_KEYRYX_KID=KEPTPIN' "$ONE_ES")"
  printf '%s' "$kept" | grep -q 'rc=0' || fail "C. a pin already in .env stopped the install"
  printf '%s' "$kept" | grep -qx 'TRAILRYX_KEYRYX_KID=KEPTPIN' || fail "C. a pin already in .env was not kept"
  printf '%s' "$kept" | grep -q 'fetches=0' || fail "C. a kept pin still fetched the key set (the pin is kept without asking keyryx again)"
  fresh="$(pin_run 'OTHER=1' "$ONE_ES")"
  printf '%s' "$fresh" | grep -qx "TRAILRYX_KEYRYX_KID=$K1" || fail "C. a fresh install did not write TRAILRYX_KEYRYX_KID from the one ES384 key"
  printf '%s' "$fresh" | grep -q 'mode=600' || fail "C. writing the pin changed .env's mode"
  printf '%s' "$fresh" | grep -q 'XCOORD' && fail "C. the key's coordinates were written to .env"
  off="$(RECORD=0 pin_run 'OTHER=1' "$ONE_ES")"
  printf '%s' "$off" | grep -q 'fetches=0' || fail "C. with the record plane off the installer still asked keyryx for the root"
  printf '%s' "$off" | grep -q 'TRAILRYX_KEYRYX_KID=' && fail "C. with the record plane off a pin was written"
  refused="$(pin_run 'OTHER=1' "$TWO_ES")"
  printf '%s' "$refused" | grep -q 'rc=3' || fail "C. two ES384 keys did not stop the install at the pin"
  printf '%s' "$refused" | grep -q 'TRAILRYX_KEYRYX_KID=' && fail "C. a refused key set left a pin in .env"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 60."
  exit 1
fi
echo "OK: the record seal pins the one ES384 kid of custody's trailryx-root key set at install (kept on a re-run; refused with a reason on zero, two or a malformed kid), and reads it from .env (invariant 60)."
