#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 59: the record seal signs its sealed roots through the
# box's keyryx custody, with a consumer credential the custody holds only as a digest;
# the keyryx witness reads the records and attests to them; and the seal reads those
# attestations. The trailryx root pin (TRAILRYX_KEYRYX_KID, trailryx#112) is not released
# yet, so it stays a named TODO and is not set.
#
# WHAT IT CHECKS
#   A. COMPOSE, RESOLVED (--profile record). The seal runs with TRAILRYX_SIGNER=keyryx, the
#      custody URL and the credential file it mounts read only; it sets no attestations
#      folder (keyryx v0.1.1 writes them 0600 under the witness uid) and mounts no witness
#      volume; the witness
#      reads the records as KEYRYX_WITNESS_RECORDS=acme|/var/lib/stack/records, mounts the
#      records read only, and keeps network_mode none.
#   B. STATIC, install.sh. The `# record-signer:` block defines record_seal_key_prepare,
#      which writes the credential with no trailing newline under umask 077, mode 0400,
#      owned by the seal's uid (10001), puts its sha256 digest into keyryx's policy in place
#      of the placeholder, and never prints the credential.
#   C. BEHAVIOUR. The block runs in a scratch directory with a stub chown: the digest in the
#      policy is the sha256 of the credential, the credential survives a re-run, nothing is
#      printed, and no placeholder is left.
#   D. THE TODO. compose.yaml names TRAILRYX_KEYRYX_KID only in a comment, not as a variable.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
  echo "record-is-signed-by-keyryx: no compose.yaml or install.sh, so nothing was measured"
  exit 1
fi

# ---- A. compose, resolved ------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  fail "A. no docker compose here, so the resolved configuration could not be read. This gate does not pass on a box that cannot run it."
else
  cdir="$(mktemp -d)"
  trap 'rm -rf "$cdir"' EXIT
  cp compose.yaml "$cdir/compose.yaml"
  grep -v '^[[:space:]]*#' compose.yaml | grep -o '\${[A-Z_]*:?' | tr -d '${:?' | sort -u | sed 's/$/=fake-not-a-secret/' >"$cdir/.env"
  if docker compose --project-directory "$cdir" -f "$cdir/compose.yaml" --profile record config --format json >"$cdir/record.json" 2>"$cdir/err"; then
    python3 - "$cdir/record.json" <<'PY' || problems=$((problems + 1))
import json
import sys

svc = json.load(open(sys.argv[1]))["services"]
problems = []
seal = svc.get("record-seal")
witness = svc.get("keyryx-witness")
if seal is None or witness is None:
    print("FAIL: A. the record profile renders no record-seal or no keyryx-witness: this gate measured NOTHING")
    sys.exit(1)
env = seal.get("environment") or {}
want = {
    "TRAILRYX_SIGNER": "keyryx",
    "TRAILRYX_KEYRYX_URL": "http://keyryx:4340",
    "TRAILRYX_KEYRYX_CREDENTIAL_FILE": "/run/keyryx/record-seal.key",
}
for k, v in want.items():
    if env.get(k) != v:
        problems.append("A. record-seal resolves %s as %r, not %r" % (k, env.get(k), v))
if "TRAILRYX_WITNESS_ATTESTATIONS" in env:
    problems.append("A. record-seal sets TRAILRYX_WITNESS_ATTESTATIONS: keyryx v0.1.1 writes attestations 0600 under the witness uid, so the seal (uid 10001) cannot read them (invariant 59, TODO(keyryx-attest-mode))")
if "TRAILRYX_KEYRYX_KID" in env:
    problems.append("A. record-seal sets TRAILRYX_KEYRYX_KID: the root pin is not released (trailryx#112) and must stay a TODO")
vols = [v for v in seal.get("volumes") or [] if isinstance(v, dict)]
key_mounts = [v for v in vols if v.get("target") == "/run/keyryx/record-seal.key"]
if not key_mounts or not key_mounts[0].get("read_only"):
    problems.append("A. the credential is not mounted read only at /run/keyryx/record-seal.key")
if any(v.get("target") == "/var/lib/keyryx-witness" for v in vols):
    problems.append("A. record-seal mounts the witness volume, which it cannot read yet (TODO(keyryx-attest-mode))")
wenv = witness.get("environment") or {}
if wenv.get("KEYRYX_WITNESS_RECORDS") != "acme|/var/lib/stack/records":
    problems.append("A. keyryx-witness resolves KEYRYX_WITNESS_RECORDS as %r, not acme|/var/lib/stack/records" % wenv.get("KEYRYX_WITNESS_RECORDS"))
wv = [v for v in witness.get("volumes") or [] if isinstance(v, dict) and v.get("target") == "/var/lib/stack/records"]
if not wv or not wv[0].get("read_only"):
    problems.append("A. the witness does not mount the records read only at /var/lib/stack/records")
if witness.get("network_mode") != "none":
    problems.append("A. the witness has a network: it must stay network_mode none (invariant 43)")
for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
PY
  else
    fail "A. docker compose config --profile record failed: $(head -2 "$cdir/err" | tr '\n' ' ')"
  fi
fi

# ---- B. install.sh, static ---------------------------------------------------------
BLOCK="$(sed -n '/^# record-signer: begin$/,/^# record-signer: end$/p' install.sh)"
if [ -z "$BLOCK" ]; then
  fail "B. install.sh has no '# record-signer: begin' .. '# record-signer: end' block, so the seal's credential was not measured"
else
  printf '%s\n' "$BLOCK" | grep -q '^record_seal_key_prepare()' || fail "B. the record-signer block defines no record_seal_key_prepare"
  CODE="$(printf '%s\n' "$BLOCK" | grep -v '^[[:space:]]*#')"
  printf '%s\n' "$CODE" | grep -q 'printf .%s. ' || fail "B. the credential is not written with printf %s (a trailing newline would fail every signature)"
  printf '%s\n' "$CODE" | grep -q 'chmod 0400' || fail "B. the credential is not set mode 0400"
  printf '%s\n' "$CODE" | grep -q 'chown 10001:10001' || fail "B. the credential is not given to the seal's uid 10001"
  printf '%s\n' "$CODE" | grep -q '__RECORD_SEAL_DIGEST__' || fail "B. the block does not fill the policy's digest placeholder"
  if printf '%s\n' "$CODE" | grep -q 'echo\|note \|say \|die '; then
    if printf '%s\n' "$CODE" | grep -E 'echo|note |say |die ' | grep -q 'secret\|cat '; then
      fail "B. the block prints the credential or reads it to a message"
    fi
  fi
fi

# ---- C. install.sh, behaviour -------------------------------------------------------
if [ -n "$BLOCK" ] && printf '%s\n' "$BLOCK" | grep -q '^record_seal_key_prepare()'; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch" "${cdir:-}"' EXIT
  mkdir -p "$scratch/bin" "$scratch/kd"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/bin/chown"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/bin/chmod-owner-stub"
  chmod +x "$scratch/bin"/*
  # The installer's own policy text, not a copy: a change to its record-seal line must reach this test.
  sed -n "/<<'POLICY' ) || die/,/^POLICY\$/p" install.sh | sed '1d;$d' >"$scratch/kd/policy.json"
  grep -q '"name": "record-seal", "auth": {"key_digest": "__RECORD_SEAL_DIGEST__"}' "$scratch/kd/policy.json" \
    || fail "C. the installer's keyryx policy does not give record-seal a key_digest placeholder"
  GENBLOCK="$(sed -n '/^gen() {/,/^}/p' install.sh)"
  run_prep() {
    env -i PATH="$scratch/bin:$PATH" HOME="$scratch" KD="$scratch/kd" BLOCK="$BLOCK" GENBLOCK="$GENBLOCK" bash -c '
      set -uo pipefail
      die() { printf "die: %s\n" "$*"; exit 1; }
      note() { :; }
      eval "$GENBLOCK"
      eval "$BLOCK"
      STACK_DIR="$KD/.."; export STACK_DIR
      mkdir -p "$STACK_DIR/keyryx"
      record_seal_key_prepare "$KD/policy.json"' 2>&1
  }
  out1="$(run_prep)"
  secret="$scratch/kd/record-seal.key"
  if [ ! -s "$secret" ]; then
    fail "C. no credential was written at keyryx/record-seal.key: $out1"
  else
    want_digest="sha256:$(openssl dgst -sha256 -hex <"$secret" | sed 's/^.*= //')"
    grep -q "$want_digest" "$scratch/kd/policy.json" || fail "C. the policy's digest is not the sha256 of the credential"
    grep -q '__RECORD_SEAL_DIGEST__' "$scratch/kd/policy.json" && fail "C. the policy still holds the placeholder"
    [ "$(tail -c 1 "$secret" | wc -l | tr -d ' ')" = 0 ] || fail "C. the credential ends in a newline, which the seal would send as part of the bearer"
  fi
  before="$(cat "$secret" 2>/dev/null)"
  out2="$(run_prep)"
  [ "$(cat "$secret" 2>/dev/null)" = "$before" ] || fail "C. a re-run replaced the record seal's credential"
  if [ -n "$before" ] && printf '%s' "$out1$out2" | grep -qF -- "$before"; then
    fail "C. the run printed the credential"
  fi
fi

# ---- D. the root pin and the attestation mode stay TODOs -----------------------------
grep -q 'TODO(keyryx-attest-mode)' compose.yaml || fail "D. compose.yaml names no TODO(keyryx-attest-mode), so the attestation hold is not recorded where it belongs"
grep -qE '^[[:space:]]+TRAILRYX_KEYRYX_KID:' compose.yaml && fail "D. compose.yaml sets TRAILRYX_KEYRYX_KID as a variable: the pin is not released (trailryx#112)"
grep -q 'TODO.*TRAILRYX_KEYRYX_KID' compose.yaml || fail "D. compose.yaml names no TODO for TRAILRYX_KEYRYX_KID, so the waiting pin is not recorded where it belongs"

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 59."
  exit 1
fi
echo "OK: the record seal signs through the box's keyryx with a credential the custody holds only as a digest, the witness attests to the records, the root pin and the attestation read are named TODOs (invariant 59)."
