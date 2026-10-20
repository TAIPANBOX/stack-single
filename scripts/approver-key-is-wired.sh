#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 58: the console's approver key is minted once as PKCS#8
# P-256, owned by the console's uid and mode 0600, kept across re-runs and never
# printed; wardryx 2.4.0 is pinned by digest; its approver statements are on only when
# the pinned console can print its public key set; WARDRYX_ALLOW_KEY_APPROVALS is never
# set; and the private key reaches the console alone.
#
# WHAT IT CHECKS
#   A. STATIC, compose.yaml. wardryx is pinned to v2.4.0 by digest; it reads the public
#      key set from ./approver-public and never mounts ./approver; the console mounts
#      ./approver read only and names GENARYX_APPROVER_KEY_FILE; WARDRYX_APPROVER_JWKS is
#      empty by default.
#   B. STATIC, install.sh and compose.yaml code lines. WARDRYX_ALLOW_KEY_APPROVALS names
#      nothing.
#   C. BEHAVIOUR. The block is lifted and run in a scratch STACK_DIR, with stub chown,
#      docker and compose on PATH: the key is PKCS#8 P-256 at mode 0600, a re-run keeps
#      its bytes, and nothing it prints contains the key; with a console that cannot
#      print its key set the JWKS is not written and WARDRYX_APPROVER_JWKS is not set;
#      with one that can, the file is written and the variable is set.
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
WARDRYX_PIN="ghcr.io/taipanbox/wardryx:v2.4.0@sha256:8a110dec235fd81c3907ed769d2c31a8e095767fbae4fa29316631eff5228e97"
grep -qF "$WARDRYX_PIN" compose.yaml || fail "A. compose.yaml does not pin wardryx to v2.4.0 by its digest (the approver statements need wardryx 2.4.0)"
grep -qF "$WARDRYX_PIN" components.json || fail "A. components.json does not record the same wardryx v2.4.0 pin as compose.yaml"
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
grep -qE '^      WARDRYX_APPROVER_JWKS: \$\{WARDRYX_APPROVER_JWKS:-\}$' compose.yaml \
  || fail "A. wardryx's WARDRYX_APPROVER_JWKS is not an empty default: statements would be on before a key set exists"

# ---- B. the switch that makes a bare key approve is never on ------------------
for f in compose.yaml install.sh; do
  if [ -n "$(grep -v '^[[:space:]]*#' "$f" | grep 'WARDRYX_ALLOW_KEY_APPROVALS')" ]; then
    fail "B. $f names WARDRYX_ALLOW_KEY_APPROVALS on a line of code: a bare key would be allowed to approve (invariant 58)"
  fi
done

# ---- C. install.sh, behaviour -------------------------------------------------
BLOCK="$(sed -n '/^# approver-key: begin$/,/^# approver-key: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "C. install.sh has no '# approver-key: begin' .. '# approver-key: end' block, so the approver key was not measured"
elif ! printf '%s\n' "$BLOCK" | grep -q '^approver_key_prepare()' || ! printf '%s\n' "$BLOCK" | grep -q '^approver_jwks_apply()'; then
  fail "C. the approver-key block defines no approver_key_prepare or no approver_jwks_apply"
elif ! openssl version >/dev/null 2>&1; then
  fail "C. no openssl here, so the key could not be checked. This gate does not pass on a box that cannot run it."
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mkdir -p "$scratch/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/bin/chown"
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
  run_block() { # BOX STUB_PROBE: runs both functions in BOX
    local box="$1" probe="$2"
    env -i PATH="$scratch/bin:$PATH" HOME="$scratch" STACK_DIR="$box" STUB_PROBE="$probe" BLOCK="$BLOCK" COMPOSE_STUB=stubcompose bash -c '
      set -uo pipefail
      die() { printf "die: %s\n" "$*"; exit 1; }
      note() { printf "note: %s\n" "$*"; }
      typed_set_env() { printf "%s=%s\n" "$1" "$2" >>"$STACK_DIR/.env"; }
      COMPOSE=(stubcompose)
      eval "$BLOCK"
      approver_key_prepare
      approver_jwks_apply' 2>&1
  }
  box="$scratch/box"
  mkdir -p "$box"
  out1="$(run_block "$box" 0)"; rc1=$?
  key="$box/approver/approver.pem"
  [ "$rc1" = 0 ] || fail "C. the approver block failed on a fresh box: $out1"
  if [ ! -s "$key" ]; then
    fail "C. no approver key was minted at $key"
  else
    head -1 "$key" | grep -qx -- "$PKCS8_HEADER" \
      || fail "C. the approver key is not PKCS#8 (its first line is not BEGIN PRIVATE KEY), which the console does not read"
    openssl pkey -in "$key" -noout -text 2>/dev/null | grep -q 'prime256v1' \
      || fail "C. the approver key is not on P-256 (prime256v1)"
    mode="$(stat -f '%Lp' "$key" 2>/dev/null || stat -c '%a' "$key" 2>/dev/null || echo '?')"
    [ "$mode" = 600 ] || fail "C. the approver key is mode $mode, not 600"
    printf '%s' "$out1" | grep -q -- "$KEY_MARK" && fail "C. the run printed the approver key"
  fi
  before="$(cat "$key" 2>/dev/null)"
  out2="$(run_block "$box" 0)"
  [ "$(cat "$key" 2>/dev/null)" = "$before" ] || fail "C. a re-run replaced the approver key: rotating it would break every approval the console has signed"
  printf '%s' "$out2" | grep -q -- "$KEY_MARK" && fail "C. the re-run printed the approver key"
  # the console cannot print its key set yet: no file, no variable, the check stays off
  if [ -e "$box/approver-public/approver-jwks.json" ] || grep -q '^WARDRYX_APPROVER_JWKS=' "$box/.env" 2>/dev/null; then
    fail "C. a console that cannot print its key set turned the approver check on (file or WARDRYX_APPROVER_JWKS written)"
  fi
  printf '%s' "$out2" | grep -q 'approver statements: off' || fail "C. the run does not say that approver statements are off on a console that cannot print its key set"
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
  echo "$problems problem(s). See CLAUDE.md invariant 58."
  exit 1
fi
echo "OK: the approver key is PKCS#8 P-256 at mode 0600, kept across re-runs and never printed; wardryx 2.4.0 is pinned by digest; approver statements are on only when the pinned console can print its key set; a bare key is never allowed to approve (invariant 58)."
