#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 61: the console's approver key is minted once as PKCS#8
# P-256, owned by the console's uid and mode 0600, kept across re-runs and never
# printed; wardryx is at least 2.4.0, by digest; its approver statements are on only when
# the pinned console can print its public key set; WARDRYX_ALLOW_KEY_APPROVALS is never
# set; and the private key reaches the console alone.
#
# WHAT IT CHECKS
#   A. STATIC, compose.yaml. wardryx is pinned at v2.4.0 or later by digest; it reads the public
#      key set from ./approver-public and never mounts ./approver; the console mounts
#      ./approver read only and names GENARYX_APPROVER_KEY_FILE; WARDRYX_APPROVER_JWKS is
#      empty by default.
#   B. STATIC, install.sh and compose.yaml code lines. WARDRYX_ALLOW_KEY_APPROVALS names
#      nothing.
#   C. BEHAVIOUR. The block is lifted and run in a scratch STACK_DIR, with stub chown,
#      docker and compose on PATH: the key is PKCS#8 P-256 at mode 0600, a re-run keeps
#      its bytes, and nothing it prints contains the key; with a console that cannot
#      print its key set the JWKS is not written and WARDRYX_APPROVER_JWKS is not set;
#      with one that can, the file is written and the variable is set. The directory the key
#      lives in is root's, its group the console's, mode 0710, whatever the umask of the shell
#      that ran install.sh: the console passes through it to its key and nobody can list it.
#      The block runs under umask 077 and under 022, because the mode used to be whatever
#      mkdir left: 0700 under 077, and the console then refused every grant at start ("the
#      approver key file cannot be used ... Permission denied", 2026-11-12), and 0755 under
#      022, which lets every account on the host list it.
#   D. The console's user is pinned in compose.yaml, and it is the uid and gid the block gives
#      the key and the directory. Unpinned, the image decides who the console is, and the
#      modes above protect a key for somebody else.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
# Assembled, not written out: a secret scanner reads a source line that spells a private-key
# header as a key, and blocks the push (the scanner prints no value).
KEY_MARK="-----BEGIN"
PKCS8_HEADER="$KEY_MARK $(printf 'PRIVATE KEY')-----"
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  echo "approver-key-is-wired: no compose.yaml or install.sh, so nothing was measured"
  exit 1
fi

# ---- A. compose, static -------------------------------------------------------
WARDRYX_PIN="$(grep -oE 'ghcr\.io/taipanbox/wardryx:v[0-9.]+@sha256:[0-9a-f]{64}' compose.yaml | head -1)"
WARDRYX_VER="$(printf '%s' "$WARDRYX_PIN" | sed -E 's/.*:v([0-9.]+)@.*/\1/')"
[ -n "$WARDRYX_PIN" ] || fail "A. compose.yaml does not pin wardryx by a digest (the approver statements need v2.4.0 or later)"
[ "$(printf '%s\n%s\n' 2.4.0 "${WARDRYX_VER:-0}" | sort -V | head -1)" = 2.4.0 ] \
  || fail "A. compose.yaml pins wardryx v${WARDRYX_VER:-?}, older than v2.4.0, which does not read approver statements"
grep -qF "${WARDRYX_PIN:-no-pin}" components.json || fail "A. components.json does not record the same wardryx pin as compose.yaml"
grep -qE '^      - \./approver-public:/etc/wardryx/approver:ro$' compose.yaml \
  || fail "A. wardryx does not mount ./approver-public read only at /etc/wardryx/approver (its public key set, and nothing else)"
# Captured, not `grep -q` in a pipe: under pipefail a `grep -q` that exits early
# closes the pipe, and the pipeline then reads as no match (invariant 30).
# A flag, not a range: `/^  wardryx:/,/^  [a-z-]+:$/` ends on its own start line, so it
# read one line and this check could never fail.
if [ -n "$(awk 'f && /^  [a-z-]+:$/ { exit } /^  wardryx:/ { f = 1 } f' compose.yaml | grep -v '^[[:space:]]*#' | grep '\./approver:')" ]; then
  fail "A. the private approver key reaches wardryx: ./approver is mounted into wardryx"
fi
grep -qE '^      - \./approver:/run/approver:ro$' compose.yaml \
  || fail "A. the console does not mount ./approver read only at /run/approver"
grep -qE '^      GENARYX_APPROVER_KEY_FILE: /run/approver/approver\.pem$' compose.yaml \
  || fail "A. the console does not name GENARYX_APPROVER_KEY_FILE=/run/approver/approver.pem"
# D. who the console is. Read from its service block, so the block's chowns are judged against it.
CONSOLE_USER="$(awk 'f && /^  [a-z-]+:$/ { exit } /^  console:$/ { f = 1 } f' compose.yaml | sed -nE 's/^    user: "([0-9]+:[0-9]+)"$/\1/p' | head -1)"
[ -n "$CONSOLE_USER" ] \
  || fail "D. the console's user is not pinned in compose.yaml (user: \"UID:GID\"), so the image decides who reaches the approver key"
CONSOLE_GID="${CONSOLE_USER##*:}"
grep -qE '^      WARDRYX_APPROVER_JWKS: \$\{WARDRYX_APPROVER_JWKS:-\}$' compose.yaml \
  || fail "A. wardryx's WARDRYX_APPROVER_JWKS is not an empty default: statements would be on before a key set exists"

# ---- B. the switch that makes a bare key approve is never on ------------------
for f in compose.yaml install.sh; do
  if [ -n "$(grep -v '^[[:space:]]*#' "$f" | grep 'WARDRYX_ALLOW_KEY_APPROVALS')" ]; then
    fail "B. $f names WARDRYX_ALLOW_KEY_APPROVALS on a line of code: a bare key would be allowed to approve (invariant 61)"
  fi
done

# ---- C. install.sh, behaviour -------------------------------------------------
BLOCK="$(sed -n '/^# approver-key: begin$/,/^# approver-key: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "C. install.sh has no '# approver-key: begin' .. '# approver-key: end' block, so the approver key was not measured"
elif ! grep -q '^approver_key_prepare()' <<<"$BLOCK" || ! grep -q '^approver_jwks_apply()' <<<"$BLOCK"; then
  fail "C. the approver-key block defines no approver_key_prepare or no approver_jwks_apply"
elif ! openssl version >/dev/null 2>&1; then
  fail "C. no openssl here, so the key could not be checked. This gate does not pass on a box that cannot run it."
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mkdir -p "$scratch/bin"
  # chown is recorded, not run: the scratch box is not root. Each line is OWNER TARGET.
  printf '#!/usr/bin/env bash\necho "$1 $2" >>"%s/chown.log"\nexit 0\n' "$scratch" >"$scratch/bin/chown"
  printf '#!/usr/bin/env bash\n# stub compose: the image list only\nif [ "$1" = config ]; then echo "ghcr.io/taipanbox/genaryx-console:v9.9.9@sha256:0000"; fi\nexit 0\n' >"$scratch/bin/stubcompose"
  # the stub docker answers the console's approver-jwks probe; STUB_PROBE=1 means the console can print
  cat >"$scratch/bin/docker" <<'EOD'
#!/usr/bin/env bash
if [ "${STUB_PROBE:-0}" = 1 ]; then
  printf '%s\n' '{"keys":[{"kty":"EC","crv":"P-256","kid":"stubkid","x":"AAAA","y":"BBBB"}]}'
  exit 0
fi
exit 2
EOD
  chmod +x "$scratch/bin"/*
  run_block() { # BOX STUB_PROBE [CONSOLE_IMAGE [UMASK]]: runs both functions in BOX
    local box="$1" probe="$2" override="${3:-}" mask="${4:-077}"
    umask "$mask"
    env -i PATH="$scratch/bin:$PATH" HOME="$scratch" STACK_DIR="$box" STUB_PROBE="$probe" BLOCK="$BLOCK" COMPOSE_STUB=stubcompose ${override:+CONSOLE_IMAGE="$override"} bash -c '
      set -uo pipefail
      die() { printf "die: %s\n" "$*"; exit 1; }
      note() { printf "note: %s\n" "$*"; }
      typed_set_env() { printf "%s=%s\n" "$1" "$2" >>"$STACK_DIR/.env"; }
      typed_env_get() { [ -f "$STACK_DIR/.env" ] && sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env"; return 0; }
      typed_forget_env() { [ -f "$STACK_DIR/.env" ] && sed -i.bak "/^$1=/d" "$STACK_DIR/.env"; return 0; }
      COMPOSE=(stubcompose)
      eval "$BLOCK"
      approver_key_prepare
      approver_jwks_apply' 2>&1
  }
  # who a path was last given to, from the chown log
  last_owner() { sed -n "s#^\([^ ]*\) $1\$#\1#p" "$scratch/chown.log" 2>/dev/null | tail -1; }
  # The approver directory: root's, the console's group, 0710 (pass through, never list).
  check_dir() { # BOX UMASK
    local d="$1/approver" m g o owner
    m="$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null || echo '?')"
    owner="$(last_owner "$d")"
    if [ "$m" = '?' ]; then
      fail "C. no approver directory at $d (umask $2)"
      return
    fi
    m=$((8#$m)); g=$(((m >> 3) & 7)); o=$((m & 7))
    [ $((g & 1)) = 1 ] \
      || fail "C. under umask $2 the approver directory is mode $(printf '%o' "$m"): the console's group cannot pass through it to its key, so the console refuses every grant at start"
    [ "$o" = 0 ] \
      || fail "C. under umask $2 the approver directory is mode $(printf '%o' "$m"): others can enter or list it"
    [ $((g & 6)) = 0 ] \
      || fail "C. under umask $2 the approver directory is mode $(printf '%o' "$m"): its group can list or write it"
    [ "$owner" = "0:${CONSOLE_GID:-?}" ] \
      || fail "C. under umask $2 the approver directory is given to ${owner:-nobody (it keeps whoever ran install.sh)}, not root with the console's group (0:${CONSOLE_GID:-?})"
  }
  box="$scratch/box"
  mkdir -p "$box"
  out1="$(run_block "$box" 1 "" 077)"; rc1=$?
  check_dir "$box" 077
  box22="$scratch/box22"
  mkdir -p "$box22"
  out22="$(run_block "$box22" 1 "" 022)" || fail "C. the approver block failed under umask 022: $out22"
  check_dir "$box22" 022
  key="$box/approver/approver.pem"
  [ "$rc1" = 0 ] || fail "C. the approver block failed on a fresh box: $out1"
  if [ ! -s "$key" ]; then
    fail "C. no approver key was minted at $key"
  else
    grep -qx -- "$PKCS8_HEADER" <<<"$(head -1 "$key")" \
      || fail "C. the approver key is not PKCS#8 (its first line is not BEGIN PRIVATE KEY), which the console does not read"
    grep -q 'prime256v1' <<<"$(openssl pkey -in "$key" -noout -text 2>/dev/null)" \
      || fail "C. the approver key is not on P-256 (prime256v1)"
    mode="$(stat -c '%a' "$key" 2>/dev/null || stat -f '%Lp' "$key" 2>/dev/null || echo '?')"
    [ "$mode" = 600 ] || fail "C. the approver key is mode $mode, not 600"
    grep -q -- "$KEY_MARK" <<<"$out1" && fail "C. the run printed the approver key"
    kowner="$(last_owner "$key")"
    [ "$kowner" = "${CONSOLE_USER:-?}" ] \
      || fail "C. the approver key is given to ${kowner:-nobody}, not the console's user (${CONSOLE_USER:-unpinned})"
  fi
  before="$(cat "$key" 2>/dev/null)"
  out2="$(run_block "$box" 1)"
  [ "$(cat "$key" 2>/dev/null)" = "$before" ] || fail "C. a re-run replaced the approver key: rotating it would break every approval the console has signed"
  grep -q -- "$KEY_MARK" <<<"$out2" && fail "C. the re-run printed the approver key"
  # the pinned console cannot print its key set: that is a fault, and it stops the install, because off
  # would decide every hold on a bearer key with no person named
  boxp="$scratch/boxp"
  mkdir -p "$boxp"
  outp="$(run_block "$boxp" 0)"; rcp=$?
  [ "$rcp" != 0 ] || fail "C. a pinned console that cannot print its key set let the install go on with the approver check off"
  grep -q 'die: the pinned console image' <<<"$outp" || fail "C. the stop on a pinned console does not say why: $outp"
  if [ -e "$boxp/approver-public/approver-jwks.json" ] || grep -q '^WARDRYX_APPROVER_JWKS=' "$boxp/.env" 2>/dev/null; then
    fail "C. a console that cannot print its key set turned the approver check on (file or WARDRYX_APPROVER_JWKS written)"
  fi
  # an operator named an older console: the check is off, said out loud, and an earlier value is gone
  boxo="$scratch/boxo"
  mkdir -p "$boxo"
  printf 'WARDRYX_APPROVER_JWKS=/etc/wardryx/approver/approver-jwks.json\n' >"$boxo/.env"
  outo="$(run_block "$boxo" 0 older-console:v1)"; rco=$?
  [ "$rco" = 0 ] || fail "C. an operator's older console stopped the install: $outo"
  grep -q 'approver statements: off' <<<"$outo" || fail "C. the run does not say that approver statements are off on an operator's older console"
  grep -q '^WARDRYX_APPROVER_JWKS=' "$boxo/.env" 2>/dev/null && fail "C. an older console keeps WARDRYX_APPROVER_JWKS, so wardryx refuses every decision it sends"
  # the console can print it: the file is written and the variable names it
  box2="$scratch/box2"
  mkdir -p "$box2"
  cp -p "$key" "$box2/" 2>/dev/null || true
  mkdir -p "$box2/approver"
  cp "$key" "$box2/approver/approver.pem" 2>/dev/null || true
  out3="$(run_block "$box2" 1)"
  [ -s "$box2/approver-public/approver-jwks.json" ] || fail "C. a console that can print its key set did not get the file written: $out3"
  grep -qx 'WARDRYX_APPROVER_JWKS=/etc/wardryx/approver/approver-jwks.json' "$box2/.env" 2>/dev/null \
    || fail "C. the variable naming the key set is not written when the console can print it"
  grep -q 'WARDRYX_ALLOW_KEY_APPROVALS' "$box2/.env" 2>/dev/null && fail "C. the approver block wrote WARDRYX_ALLOW_KEY_APPROVALS into .env"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 61."
  exit 1
fi
echo "OK: the approver key is PKCS#8 P-256 at mode 0600, owned by the console's pinned user ${CONSOLE_USER}, in a directory root:${CONSOLE_GID} 0710 under umask 077 and 022, kept across re-runs and never printed; wardryx is pinned by digest at 2.4.0 or later; approver statements are on only when the pinned console can print its key set; a bare key is never allowed to approve (invariant 61)."
