#!/usr/bin/env bash
#
# Enforces invariant 37 of CLAUDE.md: the gateway's key on the policy plane is a
# `pep`, never a `viewer`, on a box installed today and on a box installed before
# this change that is re-run now.
#
# WHY
#
# wardryx 2.0.0 refuses a viewer key on POST /v1/decide and POST /v1/filter-tools
# with a 403. The gateway, the MCP broker and scopyx present this one key on every
# governed call, and the gateway and the broker fail closed, so a viewer key left
# in .env turns every governed call into a refused one. install.sh leaves an
# existing .env as is, so the migration for a box that already has one cannot be
# the fresh .env's own line: it has to rewrite that one entry, on every run, before
# the stack comes up.
#
# WHAT THIS CHECKS
#
#   A. THE FRESH .env. The WARDRYX_KEYS line install.sh writes for a new box gives
#      the gateway's secret the role pep, and no line in install.sh gives it viewer.
#   B. THE RE-RUN MIGRATION. The `# wardryx-role:` block of install.sh is lifted out
#      and run against scratch .env files. It moves the gateway's own entry from
#      viewer to pep and nothing else: the secret, the org, an agent list, another
#      entry that is also a viewer, the admin entry and every other line stay byte
#      for byte, and the file keeps its mode. A .env already at pep is left alone,
#      and so is one with no gateway entry, and a directory with no .env.
#   C. THE ORDER. The migration is called before the first `up` in install.sh, so
#      the new wardryx never takes traffic with the old key.
#
# WHAT THIS DOES NOT CHECK
#
# That wardryx 2.0.0 answers a pep key on /v1/decide. That is the install's own
# checks, and the CI job install.yml, which runs the real install on a fresh runner.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

# ---- A. the fresh .env ------------------------------------------------------------
if ! grep -qE '^WARDRYX_KEYS=\$WARDRYX_ADMIN_SECRET:default:admin,\$WARDRYX_GATEWAY_SECRET:default:pep$' install.sh; then
  fail "install.sh's fresh .env does not give the gateway's policy-plane key the role pep"
fi
if grep -q 'WARDRYX_GATEWAY_SECRET:default:viewer' install.sh; then
  fail "install.sh still mints the gateway's policy-plane key as viewer, which wardryx 2.0.0 refuses on /v1/decide"
fi

# ---- B. the re-run migration, lifted out of install.sh ----------------------------
BLOCK="$(sed -n '/^# wardryx-role: begin$/,/^# wardryx-role: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "install.sh has no '# wardryx-role: begin' .. 'end' block, so the re-run migration measured nothing"
fi
grep -q '^wardryx_gateway_role() {' <<<"$BLOCK" \
  || fail "the wardryx-role block defines no wardryx_gateway_role, so the re-run migration measured nothing"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/wardryx-role.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

GW="gwsecret0123456789ABCDEFGHIJKLMNOPQRSTUV"
GWX="${GW}X"
ADM="admsecret0123456789ABCDEFGHIJKLMNOPQRST"
OTH="othsecret0123456789ABCDEFGHIJKLMNOPQRS"

# run DIR: runs the migration in DIR and prints what it said. Its own output and
# exit status are kept, so a refusal is a failure of the case, not of this gate.
run_migration() {
  (
    cd "$1" && env -i PATH="$PATH" HOME="$1" BLOCK="$BLOCK" bash -c '
      set -euo pipefail
      note() { printf "note: %s\n" "$*"; }
      die() { printf "die: %s\n" "$*"; exit 1; }
      eval "$BLOCK"
      wardryx_gateway_role
    ' 2>&1
  )
}

# case_dir NAME: an empty scratch directory for one case
case_dir() {
  local d="$scratch/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# expect_same DIR: .env is byte for byte what it was, with mode 0600
mode_of() { ls -l "$1" | cut -c1-10; }

# B1: viewer becomes pep, and nothing else in the file changes
d="$(case_dir viewer)"
printf 'SENTINEL=1\nWARDRYX_KEYS=%s:default:admin,%s:default:viewer\nWARDRYX_ADMIN=%s\nWARDRYX_GATEWAY=%s\nTAIL=last\n' \
  "$ADM" "$GW" "$ADM" "$GW" >"$d/.env"
chmod 600 "$d/.env"
printf 'SENTINEL=1\nWARDRYX_KEYS=%s:default:admin,%s:default:pep\nWARDRYX_ADMIN=%s\nWARDRYX_GATEWAY=%s\nTAIL=last\n' \
  "$ADM" "$GW" "$ADM" "$GW" >"$scratch/viewer.want"
out="$(run_migration "$d")" || fail "the migration refused a viewer entry: $out"
cmp -s "$d/.env" "$scratch/viewer.want" \
  || fail "the migration did not change exactly the gateway's role: $(cat "$d/.env")"
[ "$(mode_of "$d/.env")" = "-rw-------" ] || fail "the migration changed .env's mode to $(mode_of "$d/.env")"
case "$out" in *"$GW"*) fail "the migration printed the gateway's secret" ;; esac

# B2: an entry already at pep is left byte for byte, and a second run changes nothing
d="$(case_dir pep)"
printf 'WARDRYX_KEYS=%s:default:admin,%s:default:pep\nWARDRYX_GATEWAY=%s\n' "$ADM" "$GW" "$GW" >"$d/.env"
cp "$d/.env" "$scratch/pep.before"
run_migration "$d" >/dev/null || fail "the migration refused an entry already at pep"
cmp -s "$d/.env" "$scratch/pep.before" || fail "the migration rewrote an entry that was already pep"

# B3: an agent list after the role is kept; an entry for another key is not touched
d="$(case_dir agents)"
printf 'WARDRYX_KEYS=%s:default:admin,%s:default:viewer:agent://acme.example/runner,%s:acme:viewer\nWARDRYX_GATEWAY=%s\n' \
  "$ADM" "$GW" "$OTH" "$GW" >"$d/.env"
chmod 600 "$d/.env"
run_migration "$d" >/dev/null || fail "the migration refused an entry with an agent list"
grep -q "^WARDRYX_KEYS=$ADM:default:admin,$GW:default:pep:agent://acme.example/runner,$OTH:acme:viewer\$" "$d/.env" \
  || fail "the migration did not keep the agent list, or touched the other key: $(grep '^WARDRYX_KEYS=' "$d/.env")"

# B4: a key that only starts with the gateway's secret is not the gateway's entry
d="$(case_dir prefix)"
printf 'WARDRYX_KEYS=%s:default:viewer,%s:default:viewer\nWARDRYX_GATEWAY=%s\n' "$GWX" "$GW" "$GW" >"$d/.env"
run_migration "$d" >/dev/null || fail "the migration refused a .env holding a key that begins with the gateway's secret"
grep -q "^WARDRYX_KEYS=$GWX:default:viewer,$GW:default:pep\$" "$d/.env" \
  || fail "the migration rewrote a key that only begins with the gateway's secret: $(grep '^WARDRYX_KEYS=' "$d/.env")"

# B5: no gateway entry in .env, or no .env at all: nothing changes, nothing is made
d="$(case_dir nogateway)"
printf 'WARDRYX_KEYS=%s:default:admin,%s:default:viewer\n' "$ADM" "$GW" >"$d/.env"
cp "$d/.env" "$scratch/nogateway.before"
run_migration "$d" >/dev/null || fail "the migration refused a .env with no WARDRYX_GATEWAY line"
cmp -s "$d/.env" "$scratch/nogateway.before" || fail "the migration changed a .env with no WARDRYX_GATEWAY line"
d="$(case_dir nofile)"
run_migration "$d" >/dev/null || fail "the migration refused a directory with no .env"
[ ! -e "$d/.env" ] || fail "the migration created a .env where there was none"

# ---- C. the order -----------------------------------------------------------------
call_line="$(grep -n '^wardryx_gateway_role$' install.sh | head -n 1 | cut -d: -f1 || true)"
[ -n "$call_line" ] || fail "install.sh never calls wardryx_gateway_role, so a re-run keeps the viewer key"
up_line="$(grep -n ' up -d' install.sh | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1 || true)"
if [ -n "$up_line" ] && [ "$call_line" -gt "$up_line" ]; then
  fail "install.sh calls wardryx_gateway_role at line $call_line, after the first 'up -d' at line $up_line"
fi

echo "OK: the gateway's policy-plane key is a pep on a fresh .env, and a re-run moves an old viewer entry to pep and nothing else."
