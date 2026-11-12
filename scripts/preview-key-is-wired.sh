#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 78: the console's preview key is made once by the pinned console image,
# owned by the console's uid at mode 0400 in a directory only the console's group may pass through, kept
# across re-runs and never printed; wardryx holds only the public half (WARDRYX_PREVIEW_RECIPIENT) and is
# pinned at 2.7.0 or later by digest; the private key is mounted into the console alone.
#
# WHAT IT CHECKS
#   A. STATIC, compose.yaml. wardryx is pinned at v2.7.0 or later by digest, the same pin as components.json;
#      WARDRYX_PREVIEW_RECIPIENT is an empty default on wardryx; the console mounts ./preview read only at
#      /run/preview and names GENARYX_PREVIEW_KEY_FILE=/run/preview/preview.key; no other service mounts
#      ./preview.
#   B. STATIC, install.sh. preview_key_apply is called once, after the block that defines it and before the
#      `up` that starts the stack.
#   C. BEHAVIOUR. The block is lifted and run in a scratch STACK_DIR, with stub chown, docker and compose on
#      PATH. A fresh box gets a key at mode 0400 given to the console's user, a directory root:console-group
#      0710 under umask 077 and 022, a recipient file at 0644 and WARDRYX_PREVIEW_RECIPIENT set to it, no
#      private key in anything printed and no mint directory left behind. A re-run keeps the key's bytes and
#      does not run the console again. A half pair stops the install and writes nothing. A pinned console that
#      cannot make the key stops the install; an operator's older console turns the preview off, says so, and
#      drops an earlier WARDRYX_PREVIEW_RECIPIENT.
#   D. The console's user is pinned in compose.yaml, and it is the uid and gid the block gives the key and the
#      directory.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  echo "preview-key-is-wired: no compose.yaml or install.sh, so nothing was measured"
  exit 1
fi

# ---- A. compose, static -------------------------------------------------------
WARDRYX_PIN="$(grep -oE 'ghcr\.io/taipanbox/wardryx:v[0-9.]+@sha256:[0-9a-f]{64}' compose.yaml | head -1)"
WARDRYX_VER="$(printf '%s' "$WARDRYX_PIN" | sed -E 's/.*:v([0-9.]+)@.*/\1/')"
[ -n "$WARDRYX_PIN" ] || fail "A. compose.yaml does not pin wardryx by a digest (the argument preview needs v2.7.0 or later)"
[ "$(printf '%s\n%s\n' 2.7.0 "${WARDRYX_VER:-0}" | sort -V | head -1)" = 2.7.0 ] \
  || fail "A. compose.yaml pins wardryx v${WARDRYX_VER:-?}, older than v2.7.0, which does not seal a preview"
grep -qF "${WARDRYX_PIN:-no-pin}" components.json || fail "A. components.json does not record the same wardryx pin as compose.yaml"
grep -qE '^      WARDRYX_PREVIEW_RECIPIENT: \$\{WARDRYX_PREVIEW_RECIPIENT:-\}$' compose.yaml \
  || fail "A. wardryx's WARDRYX_PREVIEW_RECIPIENT is not an empty default: previews would be sealed before a key exists"
grep -qE '^      - \./preview:/run/preview:ro$' compose.yaml \
  || fail "A. the console does not mount ./preview read only at /run/preview"
grep -qE '^      GENARYX_PREVIEW_KEY_FILE: /run/preview/preview\.key$' compose.yaml \
  || fail "A. the console does not name GENARYX_PREVIEW_KEY_FILE=/run/preview/preview.key"
# Captured, not `grep -c` in a pipe under pipefail (invariant 30).
mounts="$(grep -v '^[[:space:]]*#' compose.yaml | grep -E '^[[:space:]]+- \./preview(:|/)' || true)"
[ "$(printf '%s' "$mounts" | grep -c . || true)" = 1 ] \
  || fail "A. ./preview is mounted by more than the console: the private preview key reaches another service"
if [ -n "$(awk 'f && /^  [a-z-]+:$/ { exit } /^  wardryx:/ { f = 1 } f' compose.yaml | grep -v '^[[:space:]]*#' | grep '\./preview')" ]; then
  fail "A. the private preview key reaches wardryx: ./preview is mounted into wardryx"
fi
# D. who the console is, read from its service block.
CONSOLE_USER="$(awk 'f && /^  [a-z-]+:$/ { exit } /^  console:$/ { f = 1 } f' compose.yaml | sed -nE 's/^    user: "([0-9]+:[0-9]+)"$/\1/p' | head -1)"
[ -n "$CONSOLE_USER" ] \
  || fail "D. the console's user is not pinned in compose.yaml (user: \"UID:GID\"), so the image decides who reaches the preview key"
CONSOLE_GID="${CONSOLE_USER##*:}"

# ---- B. install.sh calls it before `up` ---------------------------------------
end_line="$(grep -n '^# preview-key: end$' install.sh | head -1 | cut -d: -f1)"
call_lines="$(grep -n '^preview_key_apply$' install.sh | cut -d: -f1)"
# The `up` that starts the stack, wardryx and the console with it.
up_line="$(grep -n -F '"${COMPOSE[@]}" "${UP_PROFILES[@]}" up -d' install.sh | head -1 | cut -d: -f1)"
if [ "$(printf '%s\n' "$call_lines" | grep -c . || true)" != 1 ]; then
  fail "B. install.sh calls preview_key_apply $(printf '%s\n' "$call_lines" | grep -c . || true) time(s), not once"
elif [ -z "$end_line" ] || [ -z "$up_line" ] || [ "$call_lines" -le "$end_line" ] || [ "$call_lines" -ge "$up_line" ]; then
  fail "B. preview_key_apply is not called after its block and before the up that starts the stack (block ends ${end_line:-?}, call ${call_lines:-?}, up ${up_line:-?})"
fi

# ---- C. install.sh, behaviour -------------------------------------------------
BLOCK="$(sed -n '/^# preview-key: begin$/,/^# preview-key: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "C. install.sh has no '# preview-key: begin' .. '# preview-key: end' block, so the preview key was not measured"
elif ! grep -q '^preview_key_apply()' <<<"$BLOCK"; then
  fail "C. the preview-key block defines no preview_key_apply"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mkdir -p "$scratch/bin"
  # chown is recorded, not run: the scratch box is not root. Each line is OWNER TARGET.
  printf '#!/usr/bin/env bash\necho "$1 $2" >>"%s/chown.log"\nexit 0\n' "$scratch" >"$scratch/bin/chown"
  printf '#!/usr/bin/env bash\nif [ "$1" = config ]; then echo "ghcr.io/taipanbox/genaryx-console:v9.9.9@sha256:0000"; fi\nexit 0\n' >"$scratch/bin/stubcompose"
  # The stub docker plays `genaryx-web preview-key --out /out/preview.key` with -v DIR:/out. STUB_PROBE=1 means
  # the console can make the key. Every call is logged, so a re-run that runs the console again is seen.
  cat >"$scratch/bin/docker" <<EOD
#!/usr/bin/env bash
echo "\$*" >>"$scratch/docker.log"
case "\${STUB_PROBE:-0}" in 1 | 2) ;; *) exit 2 ;; esac
src=""
while [ \$# -gt 0 ]; do
  case "\$1" in -v) src="\${2%%:/out}"; shift 2 ;; *) shift ;; esac
done
[ -n "\$src" ] || exit 3
printf 'hpke-private:647a:STUBPRIVATEKEYMATERIAL\n' >"\$src/preview.key" && chmod 0400 "\$src/preview.key"
if [ "\${STUB_PROBE}" = 2 ]; then printf "hpke:647a:STUB' x=\\\$(id)\\n"; else printf 'hpke:647a:STUBRECIPIENT\n'; fi
EOD
  chmod +x "$scratch/bin"/*
  run_block() { # BOX STUB_PROBE [CONSOLE_IMAGE [UMASK]]
    local box="$1" probe="$2" override="${3:-}" mask="${4:-077}"
    umask "$mask"
    env -i PATH="$scratch/bin:$PATH" HOME="$scratch" STACK_DIR="$box" STUB_PROBE="$probe" BLOCK="$BLOCK" ${override:+CONSOLE_IMAGE="$override"} bash -c '
      set -uo pipefail
      die() { printf "die: %s\n" "$*"; exit 1; }
      note() { printf "note: %s\n" "$*"; }
      typed_set_env() { { [ -f "$STACK_DIR/.env" ] && grep -v "^$1=" "$STACK_DIR/.env"; printf "%s=%s\n" "$1" "$2"; } >"$STACK_DIR/.env.new"; mv "$STACK_DIR/.env.new" "$STACK_DIR/.env"; }
      typed_env_get() { [ -f "$STACK_DIR/.env" ] && sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env"; return 0; }
      typed_forget_env() { [ -f "$STACK_DIR/.env" ] && sed -i.bak "/^$1=/d" "$STACK_DIR/.env"; return 0; }
      COMPOSE=(stubcompose)
      eval "$BLOCK"
      preview_key_apply' 2>&1
  }
  last_owner() { sed -n "s#^\([^ ]*\) $1\$#\1#p" "$scratch/chown.log" 2>/dev/null | tail -1; }
  mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'; }
  check_dir() { # BOX UMASK
    local d="$1/preview" m g o owner
    m="$(mode_of "$d")"
    owner="$(last_owner "$d")"
    if [ "$m" = '?' ]; then
      fail "C. no preview directory at $d (umask $2)"
      return
    fi
    m=$((8#$m)); g=$(((m >> 3) & 7)); o=$((m & 7))
    [ $((g & 1)) = 1 ] || fail "C. under umask $2 the preview directory is mode $(printf '%o' "$m"): the console's group cannot pass through it to its key"
    [ "$o" = 0 ] || fail "C. under umask $2 the preview directory is mode $(printf '%o' "$m"): others can enter or list it"
    [ $((g & 6)) = 0 ] || fail "C. under umask $2 the preview directory is mode $(printf '%o' "$m"): its group can list or write it"
    [ "$owner" = "0:${CONSOLE_GID:-?}" ] \
      || fail "C. under umask $2 the preview directory is given to ${owner:-nobody}, not root with the console's group (0:${CONSOLE_GID:-?})"
  }

  # a fresh box
  box="$scratch/box"; mkdir -p "$box"
  out1="$(run_block "$box" 1 "" 077)"; rc1=$?
  [ "$rc1" = 0 ] || fail "C. the preview block failed on a fresh box: $out1"
  check_dir "$box" 077
  box22="$scratch/box22"; mkdir -p "$box22"
  out22="$(run_block "$box22" 1 "" 022)" || fail "C. the preview block failed under umask 022: $out22"
  check_dir "$box22" 022
  key="$box/preview/preview.key"
  pub="$box/preview-public/recipient"
  if [ ! -s "$key" ]; then
    fail "C. no preview key was made at $key"
  else
    [ "$(mode_of "$key")" = 400 ] || fail "C. the preview key is mode $(mode_of "$key"), not 400"
    [ "$(last_owner "$key")" = "${CONSOLE_USER:-?}" ] \
      || fail "C. the preview key is given to $(last_owner "$key"), not the console's user (${CONSOLE_USER:-unpinned})"
  fi
  [ "$(head -1 "$pub" 2>/dev/null)" = "hpke:647a:STUBRECIPIENT" ] || fail "C. the recipient was not kept at $pub"
  [ "$(mode_of "$pub")" = 644 ] || fail "C. the recipient file is mode $(mode_of "$pub"), not 644"
  grep -qx 'WARDRYX_PREVIEW_RECIPIENT=hpke:647a:STUBRECIPIENT' "$box/.env" 2>/dev/null \
    || fail "C. WARDRYX_PREVIEW_RECIPIENT is not set to the recipient the console printed"
  grep -q 'STUBPRIVATEKEYMATERIAL' <<<"$out1" && fail "C. the run printed the private preview key"
  grep -q 'STUBPRIVATEKEYMATERIAL' "$box/.env" 2>/dev/null && fail "C. the private preview key reached .env"
  # shellcheck disable=SC2012  # a count of names, nothing parsed out of them
  [ "$(ls -A "$box" | grep -c '^\.preview-mint\.' || true)" = 0 ] || fail "C. the mint directory was left behind in STACK_DIR"

  # a re-run keeps the pair and does not run the console again
  before="$(cat "$key" 2>/dev/null)"
  calls_before="$(grep -c . "$scratch/docker.log" 2>/dev/null || echo 0)"
  out2="$(run_block "$box" 1)" || fail "C. a re-run of the preview block failed: $out2"
  [ "$(cat "$key" 2>/dev/null)" = "$before" ] || fail "C. a re-run replaced the preview key: every preview sealed to the old one is lost"
  [ "$(grep -c . "$scratch/docker.log" 2>/dev/null || echo 0)" = "$calls_before" ] || fail "C. a re-run ran the console again to make a key"
  grep -qx 'WARDRYX_PREVIEW_RECIPIENT=hpke:647a:STUBRECIPIENT' "$box/.env" 2>/dev/null \
    || fail "C. a re-run did not set WARDRYX_PREVIEW_RECIPIENT from the kept recipient"

  # a half pair stops and writes nothing
  boxh="$scratch/boxh"; mkdir -p "$boxh/preview"
  printf 'hpke-private:647a:LEFTOVER\n' >"$boxh/preview/preview.key"
  outh="$(run_block "$boxh" 1)"; rch=$?
  [ "$rch" != 0 ] || fail "C. a key with no recipient beside it let the install go on"
  grep -q 'are not both in' <<<"$outh" || fail "C. the stop on a half pair does not say why: $outh"
  grep -q '^WARDRYX_PREVIEW_RECIPIENT=' "$boxh/.env" 2>/dev/null && fail "C. a half pair set WARDRYX_PREVIEW_RECIPIENT"
  [ "$(cat "$boxh/preview/preview.key")" = "hpke-private:647a:LEFTOVER" ] || fail "C. a half pair rewrote the key that was there"

  # the pinned console cannot make the key: the install stops
  boxp="$scratch/boxp"; mkdir -p "$boxp"
  outp="$(run_block "$boxp" 0)"; rcp=$?
  [ "$rcp" != 0 ] || fail "C. a pinned console that cannot make a preview key let the install go on with the preview off"
  grep -q 'die: the pinned console image did not make a preview key' <<<"$outp" || fail "C. the stop on a pinned console does not say why: $outp"
  [ -e "$boxp/preview/preview.key" ] && fail "C. a console that cannot make a key left a key file"
  grep -q '^WARDRYX_PREVIEW_RECIPIENT=' "$boxp/.env" 2>/dev/null && fail "C. a console that cannot make a key set WARDRYX_PREVIEW_RECIPIENT"

  # a console that prints a recipient outside base64url: refused, nothing lands in .env
  boxb="$scratch/boxb"; mkdir -p "$boxb"
  outb="$(run_block "$boxb" 2)"; rcb=$?
  [ "$rcb" != 0 ] || fail "C. a recipient outside base64url was accepted: it would land in .env and in wardryx's environment"
  grep -q '^WARDRYX_PREVIEW_RECIPIENT=' "$boxb/.env" 2>/dev/null && fail "C. a recipient outside base64url was written to .env"

  # an operator named an older console: off, said out loud, and an earlier value is gone
  boxo="$scratch/boxo"; mkdir -p "$boxo"
  printf 'WARDRYX_PREVIEW_RECIPIENT=hpke:647a:OLD\n' >"$boxo/.env"
  outo="$(run_block "$boxo" 0 older-console:v1)"; rco=$?
  [ "$rco" = 0 ] || fail "C. an operator's older console stopped the install: $outo"
  grep -q 'argument preview: off' <<<"$outo" || fail "C. the run does not say the argument preview is off on an operator's older console"
  grep -q '^WARDRYX_PREVIEW_RECIPIENT=' "$boxo/.env" 2>/dev/null \
    && fail "C. an older console keeps WARDRYX_PREVIEW_RECIPIENT, so wardryx seals holds that console cannot decide"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 78."
  exit 1
fi
echo "OK: the preview key is made once by the pinned console, mode 0400 for the console's user ${CONSOLE_USER} in a directory root:${CONSOLE_GID} 0710 under umask 077 and 022, kept across re-runs without running the console again and never printed; wardryx v${WARDRYX_VER} holds only the recipient; a half pair and a pinned console that cannot make the key stop the install (invariant 78)."
