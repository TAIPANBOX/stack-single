#!/usr/bin/env bash
#
# Enforces the other half of the delegation plane's own invariant: the
# signing key and the revocation key are generated once and REUSED on a
# re-run, never regenerated and never dropped. Installer second-run faults
# are a known class in this estate (see the `installer-second-run-faults`
# lore this repository's own CLAUDE.md invariant 2 names): a key that gets a
# fresh value on every run silently invalidates every token already issued
# and every revocation already recorded under the old one.
#
# WHAT THIS DOES
#
# The exact slice of install.sh from its `add_env_default VOUCHRYX_REVOKE_KEYS`
# line (VOUCHRYX_REVOKE_KEYS is generated unconditionally, like every other
# opt-in plane's own key, so it sits just above the delegation section proper)
# through the `# ---- 3c. the images, pulled` marker is sourced TWICE in a
# scratch directory, with `docker` and `chown` stubbed so nothing here needs
# root or the network, and WITH_DELEGATION=1 WITH_DELEGATION_DEMO_ISSUER=1 so
# both keys are actually minted on the first run. Between the two runs:
#
#   - signing.pem and idp.pem must be byte-identical (their sha256 unchanged)
#   - VOUCHRYX_REVOKE_KEYS in .env must be the same value both times
#   - VOUCHRYX_TRUSTED_ISSUERS in .env must be the same value both times
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# The slice's own anchors moved, or the stub docker was never invoked on the
# first run at all (nothing was minted, so "unchanged" would be vacuously
# true): each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

start=$(grep -n 'add_env_default VOUCHRYX_REVOKE_KEYS' install.sh | head -1 | cut -d: -f1)
end=$(grep -n '^# ---- 3c\. the images, pulled' install.sh | head -1 | cut -d: -f1)
if [ -z "$start" ] || [ -z "$end" ] || [ "$end" -le "$start" ]; then
  echo "FAIL: the delegation section's own anchors (the add_env_default"
  echo "      VOUCHRYX_REVOKE_KEYS line ... # ---- 3c. the images, pulled) are not"
  echo "      both in install.sh, so this gate measured NOTHING."
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n "${start},$((end - 1))p" install.sh >"$work/slice.sh"

mkdir -p "$work/bin"
# A stub docker that understands only the one shape the slice actually runs:
# `docker run --rm --user 0:0 -v <host>:/out --entrypoint vouchryx-demo <image>
# keygen -out /out/<prefix> [-kid <kid>]`. It mints believable stand-ins for
# vouchryx-demo's own output (a 0600 "private key" file and a "public JWKS"
# file) rather than pulling a real image, which is the whole point of a gate
# that needs no network and no root.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" != run ]; then exit 0; fi
shift
hostdir=""
prefix=""
prev=""
for a in "$@"; do
  case "$prev" in
    -v) hostdir="${a%%:*}" ;;
    -out) prefix="${a#/out/}" ;;
  esac
  prev="$a"
done
[ -n "$hostdir" ] && [ -n "$prefix" ] || exit 1
# A fresh value every invocation, on purpose: a REAL keygen mints a fresh key
# every time it runs too, and the whole point of "reused on a re-run" is that
# install.sh must not let a second invocation happen at all when the file is
# already there. A stub that wrote the same bytes every time would pass this
# gate even with the `[ ! -f ... ]` guard removed entirely.
printf 'stub private key %s %s\n' "$(date +%s%N)" "$RANDOM$RANDOM" >"$hostdir/$prefix.pem"
chmod 600 "$hostdir/$prefix.pem"
printf '{"keys":[],"minted":"%s"}\n' "$(date +%s%N)" >"$hostdir/$prefix.jwks.json"
EOF
# chown to a uid this test does not have permission for on most machines;
# a no-op stub is the same trade apt-never-removes-docker.sh already makes
# for privileged operations it does not need to actually perform to prove the
# SHELL LOGIC around them.
cat >"$work/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$work/bin/docker" "$work/bin/chown"

cat >"$work/run.sh" <<'EOF'
set -euo pipefail
say()  { :; }
note() { :; }
die()  { printf 'die: %s\n' "$*" >&2; exit 1; }
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-40}"; }
sq_() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }
add_env_default() {
  grep -q "^${1}=" .env 2>/dev/null && return 0
  printf '%s=%s\n' "$1" "$2" >>.env
}
GATEWAY_PROBE=127.0.0.1
BUILD_FROM_SOURCE=""
WITH_DELEGATION=1
WITH_DELEGATION_DEMO_ISSUER=1
STACK_DIR="$PWD"
if [ -s .env ]; then
  # shellcheck disable=SC1091
  . ./.env
fi
. "$1"
EOF

sandbox="$work/box"
mkdir -p "$sandbox"
cd "$sandbox" || exit 1
: >.env

run_once() {
  PATH="$work/bin:$PATH" bash "$work/run.sh" "$work/slice.sh"
}

if ! run_once >"$work/run1.log" 2>&1; then
  echo "FAIL: the first run of the delegation slice did not complete:"
  sed 's/^/      /' "$work/run1.log"
  exit 1
fi
[ -f delegation/signing.pem ] && [ -f delegation/idp.pem ] || {
  echo "FAIL: after the first run, delegation/signing.pem and delegation/idp.pem should both"
  echo "      exist (WITH_DELEGATION_DEMO_ISSUER=1 mints both), so this gate measured NOTHING"
  echo "      about reuse: there was nothing minted to prove unchanged."
  exit 1
}
sig1="$(sha256sum delegation/signing.pem | cut -d' ' -f1)"
idp1="$(sha256sum delegation/idp.pem | cut -d' ' -f1)"
revoke1="$(sed -n 's/^VOUCHRYX_REVOKE_KEYS=//p' .env | head -1)"
trusted1="$(sed -n 's/^VOUCHRYX_TRUSTED_ISSUERS=//p' .env | head -1)"
[ -n "$revoke1" ] || { echo "FAIL: .env has no VOUCHRYX_REVOKE_KEYS after the first run, so this measured NOTHING"; exit 1; }

if ! run_once >"$work/run2.log" 2>&1; then
  echo "FAIL: the second run of the delegation slice did not complete:"
  sed 's/^/      /' "$work/run2.log"
  exit 1
fi
sig2="$(sha256sum delegation/signing.pem | cut -d' ' -f1)"
idp2="$(sha256sum delegation/idp.pem | cut -d' ' -f1)"
revoke2="$(sed -n 's/^VOUCHRYX_REVOKE_KEYS=//p' .env | head -1)"
trusted2="$(sed -n 's/^VOUCHRYX_TRUSTED_ISSUERS=//p' .env | head -1)"

problems=0
if [ "$sig1" != "$sig2" ]; then
  echo "FAIL: signing.pem changed between the first and second run: a re-run regenerated the signing key"
  problems=$((problems + 1))
fi
if [ "$idp1" != "$idp2" ]; then
  echo "FAIL: idp.pem changed between the first and second run: a re-run regenerated the demo issuer key"
  problems=$((problems + 1))
fi
if [ "$revoke1" != "$revoke2" ]; then
  echo "FAIL: VOUCHRYX_REVOKE_KEYS changed between the first and second run: a re-run rotated the revocation key, which orphans every revocation already recorded under the old one"
  problems=$((problems + 1))
fi
if [ "$trusted1" != "$trusted2" ]; then
  echo "FAIL: VOUCHRYX_TRUSTED_ISSUERS changed between the first and second run"
  problems=$((problems + 1))
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 15."
  exit 1
fi

echo "OK: signing.pem, idp.pem, VOUCHRYX_REVOKE_KEYS and VOUCHRYX_TRUSTED_ISSUERS are all"
echo "    unchanged across a second run of the delegation section."
