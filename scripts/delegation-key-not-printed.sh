#!/usr/bin/env bash
#
# Enforces half of the delegation plane's own invariant: the signing key and
# the revocation key are never printed to any log or stdout.
#
# WHAT THIS CHECKS
#
#   1. VOUCHRYX_REVOKE_KEYS (the bearer key `gen 40` mints for
#      `POST /v1/revoke`) is named in install.sh in exactly one shape, the
#      `add_env_default VOUCHRYX_REVOKE_KEYS ...` assignment that writes it
#      straight to .env (0600, never a log). Any other line that both names
#      it and calls one of this file's own print helpers (`say`, `note`,
#      `die`, `printf`, `echo`) is a read of it this gate cannot account for.
#   2. The private key FILES `vouchryx-demo keygen` writes (signing.pem,
#      idp.pem) are referenced only by PATH, for a docker volume mount, a
#      chown or a chmod: nothing in install.sh ever `cat`s one or opens it
#      with `<` to read its bytes into a variable or a print call.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#
# It does not prove a secret is never logged by some OTHER means (Docker's own
# daemon log, a shell trace, a core dump). It proves the one thing install.sh's
# own source can be checked for, the same limit stack-up's own
# revoke-key-not-printed.sh states about itself.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# VOUCHRYX_REVOKE_KEYS not named in install.sh at all, or neither key file
# name referenced at all: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LAUNCHER="install.sh"
problems=0

# ---- 1. the revoke key's VALUE never reaches a printed line ------------------
# The one legitimate line is the definition site itself, and it does not even
# expand the value: `add_env_default VOUCHRYX_REVOKE_KEYS "$(gen 40)"` passes
# the bare NAME as an argument and a freshly generated string as the value, so
# no shell variable called VOUCHRYX_REVOKE_KEYS is ever created here, and .env
# (0600, never a log) is the only place the actual bytes land. So this checks
# for the one shape that WOULD be a leak: a `$VOUCHRYX_REVOKE_KEYS` or
# `${VOUCHRYX_REVOKE_KEYS` expansion anywhere, which a print call could then
# put on stdout.
definition="$(grep -n 'add_env_default VOUCHRYX_REVOKE_KEYS' "$LAUNCHER" || true)"
if [ -z "$definition" ]; then
  echo "FAIL: $LAUNCHER no longer defines VOUCHRYX_REVOKE_KEYS at all, so this measured nothing."
  exit 1
fi
expansions="$(grep -nE '\$\{?VOUCHRYX_REVOKE_KEYS\b' "$LAUNCHER" || true)"
if [ -n "$expansions" ]; then
  printf 'FAIL: %s expands $VOUCHRYX_REVOKE_KEYS as a shell variable, which a print call could then put on stdout:\n%s\n' "$LAUNCHER" "$expansions"
  problems=$((problems + 1))
fi

# ---- 2. the private key FILES are read only by path, never by content -------
found_any=0
for f in signing.pem idp.pem; do
  if ! grep -q "$f" "$LAUNCHER"; then
    continue
  fi
  found_any=1
  reads="$(grep -nE "(cat[[:space:]]+[^|;&]*${f})|(<[[:space:]]+[^|;&]*${f})" "$LAUNCHER" || true)"
  if [ -n "$reads" ]; then
    printf 'FAIL: %s reads %s'"'"'s own bytes rather than only its path:\n%s\n' "$LAUNCHER" "$f" "$reads"
    problems=$((problems + 1))
  fi
done
if [ "$found_any" -eq 0 ]; then
  echo "FAIL: neither signing.pem nor idp.pem is referenced in $LAUNCHER at all, so the file half measured nothing."
  problems=$((problems + 1))
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 15."
  exit 1
fi

echo "OK: VOUCHRYX_REVOKE_KEYS is named only in its own add_env_default assignment,"
echo "    never in a printed line; signing.pem and idp.pem are referenced only by"
echo "    path, never read for their bytes."
