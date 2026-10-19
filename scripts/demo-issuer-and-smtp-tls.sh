#!/usr/bin/env bash
#
# Enforces two installer rules that the 2026-10-19 pin move made new (CLAUDE.md invariant 45):
#
#   1. THE DEMO ISSUER LINE. vouchryx 0.5.0 and later refuse a subject token with no cnf.jkt unless its issuer
#      line ends in |unbound, and the demo IdP sends unbound tokens. An install from before that release keeps the
#      old demo line in .env, because add_env_default never rewrites a line that exists. A rerun migrates exactly
#      that line, and no other: an operator's own line is never touched.
#   2. THE MAIL TLS MODE. SMTP_TLS is written into .env as HERALDYX_SMTP_TLS. install.sh refuses any value heraldyx
#      does not read, and refuses plain for a host that is not loopback, before anything is installed.
#
# Both are lifted out of install.sh (the `# demo-issuer:` and `# smtp-tls:` blocks) and run for real in a
# scratch directory. The gate refuses to report OK when a block is missing: an empty lift measured nothing.
#
# Teeth: scripts/gates-have-teeth.sh, cases named "demo-issuer-and-smtp-tls:".
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f install.sh ]; then
  echo "FAIL: install.sh is not there, so this gate measured NOTHING."
  exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/demo-issuer.XXXXXX")" || exit 1
trap 'rm -rf "$scratch"' EXIT

lift() { # NAME: the lines between `# NAME: begin` and `# NAME: end`, or nothing
  sed -n "/^# $1: begin\$/,/^# $1: end\$/p" install.sh
}

DEMO="$(lift demo-issuer)"
SMTP="$(lift smtp-tls)"
for pair in "demo-issuer:$DEMO" "smtp-tls:$SMTP"; do
  if [ -z "${pair#*:}" ]; then
    fail "install.sh has no '# ${pair%%:*}: begin' .. 'end' block, so this gate measured NOTHING about it"
  fi
done
[ "$problems" -eq 0 ] || { printf 'demo-issuer-and-smtp-tls: %d problem(s)\n' "$problems"; exit 1; }

# The call site: the delegation block migrates the .env it reads, and the image pin the installer names is one.
grep -q '^  demo_issuer_migrate \.env$' install.sh || fail "the delegation block does not call demo_issuer_migrate .env"
grep -q '^smtp_tls_resolve$' install.sh || fail "install.sh does not call smtp_tls_resolve before anything is installed"
grep -q 'add_env_default SMTP_TLS ' install.sh || fail "install.sh does not write SMTP_TLS into .env"

# ---- 1. the demo issuer line --------------------------------------------------------------------------------
printf '%s\n' "$DEMO" >"$scratch/demo.sh"
OLD='https://idp.stack-single.local|stack-single|/etc/vouchryx/idp.jwks.json'
NEW="$OLD|unbound"
run_demo() { # ENV_FILE: source the block with its helpers, and migrate ENV_FILE
  bash -c '
    note() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    . "$1"
    demo_issuer_migrate "$2"
  ' _ "$scratch/demo.sh" "$1"
}

# A. the exact old demo line becomes the new one, and every other line is byte for byte the same.
printf '%s\n' "ALERT_TO='ops@example.com'" "VOUCHRYX_TRUSTED_ISSUERS='$OLD'" "VOUCHRYX_REVOKE_KEYS='x'" >"$scratch/a.env"
run_demo "$scratch/a.env" || fail "A. the migration refused an old demo line"
want="$(printf '%s\n' "ALERT_TO='ops@example.com'" "VOUCHRYX_TRUSTED_ISSUERS='$NEW'" "VOUCHRYX_REVOKE_KEYS='x'")"
[ "$(cat "$scratch/a.env")" = "$want" ] || fail "A. the old demo line was not rewritten to the |unbound form, or another line changed: $(cat "$scratch/a.env")"

# B3. a line that names the demo host is not the demo line, even when the demo line sits beside it.
printf '%s\n' "VOUCHRYX_TRUSTED_ISSUERS='$OLD'" "NOTE='see $OLD'" >"$scratch/b3.env"
run_demo "$scratch/b3.env" || fail "B3. the migration refused a file with a note that names the demo host"
want3="$(printf '%s\n' "VOUCHRYX_TRUSTED_ISSUERS='$NEW'" "NOTE='see $OLD'")"
[ "$(cat "$scratch/b3.env")" = "$want3" ] || fail "B3. a line that names the demo host, next to the demo line, was rewritten: $(cat "$scratch/b3.env")"

# B. an operator's own line is never touched, not even one that starts with the demo line.
printf '%s\n' "VOUCHRYX_TRUSTED_ISSUERS='https://idp.example.com|tokenfuse|/etc/vouchryx/jwks.json'" >"$scratch/b1.env"
cp "$scratch/b1.env" "$scratch/b1.before"
run_demo "$scratch/b1.env" || fail "B. the migration refused an operator's line"
cmp -s "$scratch/b1.env" "$scratch/b1.before" || fail "B. an operator's own issuer line was rewritten"
printf '%s\n' "VOUCHRYX_TRUSTED_ISSUERS='$OLD;https://idp.example.com|tokenfuse|/etc/x.json'" >"$scratch/b2.env"
cp "$scratch/b2.env" "$scratch/b2.before"
run_demo "$scratch/b2.env" || fail "B. the migration refused a line with the demo line inside it"
cmp -s "$scratch/b2.env" "$scratch/b2.before" || fail "B. a line that only contains the demo line was rewritten"

# C. no .env at all: nothing is created and nothing fails.
run_demo "$scratch/none.env" || fail "C. the migration failed with no .env"
[ ! -e "$scratch/none.env" ] || fail "C. the migration created a .env that did not exist"

# D. a second run changes nothing: the migration is idempotent.
run_demo "$scratch/a.env" || fail "D. the second migration run failed"
[ "$(cat "$scratch/a.env")" = "$want" ] || fail "D. a second run changed a migrated .env"

# E. the new value is the old demo line plus |unbound, and only that.
grep -q "^DEMO_ISSUER_NEW=\"\\\$DEMO_ISSUER_OLD|unbound\"\$" "$scratch/demo.sh" \
  || fail "E. DEMO_ISSUER_NEW is not the demo line with |unbound appended (vouchryx 0.5.0 refuses the unbound demo tokens otherwise)"

# ---- 2. the mail TLS mode -----------------------------------------------------------------------------------
printf '%s\n' "$SMTP" >"$scratch/smtp.sh"
smtp_check() { # SMTP_TLS SMTP_HOST: exit status of the preflight check, with its refusal on stderr
  env -i PATH="$PATH" SMTP_TLS="$1" SMTP_HOST="$2" bash -c '
    die() { echo "DIE: $*" >&2; exit 1; }
    . "$1"
  ' _ "$scratch/smtp.sh"
}

smtp_check "" "" >/dev/null 2>&1 || fail "F. an unset SMTP_TLS (heraldyx's default) was refused"
smtp_check starttls smtp.example.com:587 >/dev/null 2>&1 || fail "F. starttls was refused"
smtp_check implicit smtp.example.com:465 >/dev/null 2>&1 || fail "F. implicit was refused"
smtp_check plain 127.0.0.1:25 >/dev/null 2>&1 || fail "F. plain to loopback was refused"
smtp_check plain '[::1]:25' >/dev/null 2>&1 || fail "F. plain to [::1] was refused"

out="$(smtp_check bogus smtp.example.com:587 2>&1)" && fail "G. a value heraldyx does not read was accepted"
case "$out" in *bogus*) fail "G. the refusal echoed the value it was given" ;; esac
out="$(smtp_check plain smtp.example.com:587 2>&1)" && fail "H. plain was accepted for a host that is not loopback"
case "$out" in *loopback*) : ;; *) fail "H. the plain refusal does not say it is for loopback only" ;; esac

if [ "$problems" -ne 0 ]; then
  printf 'demo-issuer-and-smtp-tls: %d problem(s)\n' "$problems"
  exit 1
fi
echo "OK: demo-issuer-and-smtp-tls (invariant 45): the exact old demo line is migrated to |unbound and nothing else is touched, and SMTP_TLS refuses a value heraldyx does not read and plain for a host that is not loopback"
