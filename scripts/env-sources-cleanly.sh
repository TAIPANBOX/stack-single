#!/usr/bin/env bash
#
# install.sh writes .env and then sources it (`. ./.env`), so every value in it
# is shell. From v1.1.9 to v1.1.12 one default carried an unquoted `|`, the
# shell ran the words after it as commands, and every install stopped there
# (measured 2026-09-27 on Debian 13; nothing had run install.sh on a real box
# since the line went in).
#
# WHAT THIS CHECKS
#   1. Every `add_env_default NAME VALUE` in install.sh whose VALUE is a
#      literal (not "$(sq_ ...)" and not "$(gen ...)...") holds no character
#      the shell would act on.
#   2. install.sh calls `repair_env_quoting .env` before its `. ./.env`.
#   3. repair_env_quoting, lifted out of install.sh and run on a .env shaped
#      like one those releases wrote, leaves a file `set -e` can source, with
#      the value intact.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no add_env_default line, or no
# repair_env_quoting function, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
lines=$(grep -nE '^[[:space:]]*add_env_default [A-Z_]+ ' install.sh || true)
[ -n "$lines" ] || { echo "FAIL: install.sh has no add_env_default line, so this measured nothing"; exit 1; }
while IFS= read -r l; do
  val=$(printf '%s' "$l" | sed -E 's/^[0-9]+:[[:space:]]*add_env_default [A-Z_]+[[:space:]]+//')
  case "$val" in
    '"$(sq_ '*|'"$(gen '*) continue ;;
  esac
  lit=$(printf '%s' "$val" | sed -E 's/^"(.*)"$/\1/')
  if printf '%s' "$lit" | grep -qE '[|&;<>()`[:space:]]'; then
    echo "FAIL: install.sh:${l%%:*} writes an unquoted value the shell would act on when .env is sourced: $val"
    fail=1
  fi
done <<<"$lines"
call=$(grep -n '^repair_env_quoting \.env' install.sh | head -1 | cut -d: -f1)
src=$(grep -n '^\. \./\.env' install.sh | head -1 | cut -d: -f1)
if [ -z "$call" ] || [ -z "$src" ] || [ "$call" -gt "$src" ]; then
  echo "FAIL: install.sh does not call repair_env_quoting .env before its first '. ./.env'"
  fail=1
fi
fn=$(sed -n '/^repair_env_quoting() {/,/^}/p' install.sh)
if [ -z "$fn" ]; then
  echo "FAIL: install.sh has no repair_env_quoting function, so this measured nothing about repair"
  exit 1
fi
d=$(mktemp -d)
printf "A=plain\nTOKENFUSE_MCP_SECRET_SCOPES=typryx_key=tools:ask|ask_freeform|list_questions\nB='already|quoted'\n" >"$d/.env"
( cd "$d" && note() { :; } && eval "$fn" && repair_env_quoting .env ) || { echo "FAIL: repair_env_quoting failed on a v1.1.9-shaped .env"; fail=1; }
got=$(cd "$d" && bash -c 'set -e; . ./.env; printf "%s|%s" "$TOKENFUSE_MCP_SECRET_SCOPES" "$B"' 2>&1)
if [ "$got" != "typryx_key=tools:ask|ask_freeform|list_questions|already|quoted" ]; then
  echo "FAIL: after repair_env_quoting a v1.1.9-shaped .env does not source cleanly: $got"
  fail=1
fi
rm -rf "$d"
[ "$fail" = 0 ] || exit 1
echo "OK: every literal .env default is shell-safe, and a .env from v1.1.9 to v1.1.12 is repaired before it is sourced."
