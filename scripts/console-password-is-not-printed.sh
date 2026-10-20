#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 56: the console's first sign-in password is never
# printed, logged or passed on an argument list. It is generated into one file under
# STACK_DIR, mode 0600, made under umask 077, and the console reads it from that file.
# The closing report names the file and the one command that reads it.
#
# WHY THIS SHAPE
#
# Found on a live install (stack-single v1.3.1, 2026-10-19): the closing report printed
# the password, so it sat in any captured install log. The same class as stack-up's
# revoke-key gate: the bytes, not the path, are what must not leave the box. A grep for
# the word "password" would flag the report's own honest line, so this looks for the
# identifiers that held the value and for any read of the file outside its one place.
#
# WHAT IT CHECKS
#
#   A. STATIC. install.sh has a `# console-password:` block that defines
#      console_password_file, and that function makes its file under umask 077 and
#      sets it 0600.
#   B. NO VARIABLE HOLDS THE VALUE. The identifier CONSOLE_PASSWORD (what v1.3.1 used,
#      and what the closing report printed) appears nowhere in install.sh, and
#      `gen 28` is called only inside the block.
#   C. ONE READ, FROM THE FILE. The line that runs set-password redirects its stdin
#      from the password file and passes nothing that is a command substitution.
#   D. BEHAVIOUR. The block and the gen block are lifted and run in a scratch
#      directory under umask 022: the file is 0600, holds 28 characters and a newline,
#      and the run prints nothing on stdout or stderr that contains the value.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no block, no gen, no set-password line, or
# no install.sh is each reported and fails.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f install.sh ]; then
  echo "console-password-is-not-printed: no install.sh, so nothing was measured"
  exit 1
fi

# ---- A. static: the block and its umask ---------------------------------------
BLOCK="$(sed -n '/^# console-password: begin$/,/^# console-password: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# console-password: begin' .. '# console-password: end' block, so the password's file was not measured"
elif ! printf '%s\n' "$BLOCK" | grep -q '^console_password_file()'; then
  fail "the console-password block defines no console_password_file"
else
  # Code lines only: a comment that says "umask 077" proves nothing about the code.
  CODE="$(printf '%s\n' "$BLOCK" | grep -v '^[[:space:]]*#')"
  printf '%s\n' "$CODE" | grep -q 'umask 077;' || fail "console_password_file does not make its file under umask 077"
  printf '%s\n' "$CODE" | grep -q 'chmod 0600' || fail "console_password_file does not set its file 0600"
fi

# ---- B. no variable holds the value -------------------------------------------
if grep -n 'CONSOLE_PASSWORD' install.sh >/dev/null; then
  fail "install.sh still names CONSOLE_PASSWORD, the variable whose value the closing report printed: $(grep -n 'CONSOLE_PASSWORD' install.sh | head -1)"
fi
gen_outside="$(grep -n 'gen 28' install.sh | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [ -n "$gen_outside" ]; then
  while IFS= read -r l; do
    lineno="${l%%:*}"
    if [ -z "$BLOCK" ] || ! printf '%s\n' "$BLOCK" | grep -qF -- "${l#*:}"; then
      fail "install.sh:$lineno generates the console password outside the console-password block: ${l#*:}"
    fi
  done <<<"$gen_outside"
fi

# ---- C. one read, from the file -----------------------------------------------
setpw="$(grep -n 'set-password' install.sh | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [ -z "$setpw" ]; then
  fail "install.sh never runs set-password, so this measured nothing about how the console reads its password"
else
  while IFS= read -r l; do
    lineno="${l%%:*}"
    content="${l#*:}"
    case "$content" in
      *'<"'*) ;;
      *) fail "install.sh:$lineno runs set-password without reading its password from a file: $content" ;;
    esac
    case "$content" in
      *'$('*) fail "install.sh:$lineno passes a command substitution to set-password, so the password could reach an argument list: $content" ;;
    esac
  done <<<"$setpw"
fi

# ---- D. behaviour --------------------------------------------------------------
GENBLOCK="$(sed -n '/^gen() {/,/^}/p' install.sh)"
if [ -z "$BLOCK" ] || [ -z "$GENBLOCK" ]; then
  fail "behaviour: the console-password block or gen is missing, so the file's behaviour was not measured"
else
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  out="$(env -i PATH="$PATH" HOME="$scratch" BLOCK="$BLOCK" GENBLOCK="$GENBLOCK" D="$scratch/pw" bash -c '
    set -uo pipefail
    die() { printf "die: %s\n" "$*"; exit 1; }
    eval "$GENBLOCK"
    eval "$BLOCK"
    ( umask 022; console_password_file "$D" ) 2>&1
    printf "rc=%s\n" "$?"' 2>&1)"
  value="$(head -1 "$scratch/pw" 2>/dev/null || true)"
  if ! printf '%s\n' "$out" | grep -qx 'rc=0'; then
    fail "behaviour: console_password_file failed: $out"
  fi
  if [ -n "$value" ] && printf '%s\n' "$out" | grep -qF -- "$value"; then
    fail "behaviour: console_password_file printed the password on its own output"
  fi
  mode="$(stat -f '%Lp' "$scratch/pw" 2>/dev/null || stat -c '%a' "$scratch/pw" 2>/dev/null || echo '?')"
  [ "$mode" = 600 ] || fail "behaviour: the password file is mode $mode, not 600"
  [ "$(wc -c <"$scratch/pw" | tr -d ' ')" = 29 ] || fail "behaviour: the password file is not 28 characters and a newline"
  [ -z "$(printf '%s' "$out" | sed 's/rc=0//')" ] || fail "behaviour: the run printed something besides rc=0: $out"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 56."
  exit 1
fi
echo "OK: the console's sign-in password is written to one 0600 file under umask 077, read from that file by set-password, and printed by nothing (invariant 56)."
