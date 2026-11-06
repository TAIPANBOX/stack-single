#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 62: the record seal signs its sealed roots through the
# box's keyryx custody, with a consumer credential the custody holds only as a digest;
# the keyryx witness reads the records and attests to them; and the seal reads those
# attestations from a volume of their own, read only (keyryx 0.1.2 and later write them 0640, the
# witness runs gid 10001), so nothing else of the witness's is in its reach. The seal pins the kid of custody's trailryx-root key set, taken at install
# (trailryx 1.5.0 refuses to start without it).
#
# WHAT IT CHECKS
#   A. COMPOSE, RESOLVED (--profile record). The seal runs with TRAILRYX_SIGNER=keyryx, the
#      custody URL and the credential file it mounts read only; it reads the attestations from
#      keyryxattest read only and mounts no volume of the witness's own; the witness writes
#      keyryxattest and reads the records as KEYRYX_WITNESS_RECORDS=acme|/var/lib/stack/records, mounts the
#      records read only, and keeps network_mode none.
#   B. STATIC, install.sh. The `# record-signer:` block defines record_seal_key_prepare,
#      which writes the credential with no trailing newline under umask 077, mode 0400,
#      owned by the seal's uid (10001), puts its sha256 digest into keyryx's policy in place
#      of the placeholder, and never prints the credential.
#   C. BEHAVIOUR. The block runs in a scratch directory with a stub chown: the digest in the
#      policy is the sha256 of the credential, the credential survives a re-run, nothing is
#      printed, and no placeholder is left.
#   D. THE TODO. compose.yaml names TRAILRYX_KEYRYX_KID only in a comment, not as a variable.
#   E. A POLICY THAT CHANGED IS READ. Custody reads policy.json at start and `up` compares no
#      mounted file, so an upgrade that moves record-seal to a key_digest would leave custody on
#      the old policy and refuse every signature. keyryx_prepare records the change and keyryx_up
#      restarts custody: run with a stub compose, a change on a running custody restarts it once,
#      no change and a first install do not, and the pin step reaches keyryx_up on every path.
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
if env.get("TRAILRYX_WITNESS_ATTESTATIONS") != "/run/keyryx/attestations":
    problems.append("A. record-seal resolves TRAILRYX_WITNESS_ATTESTATIONS as %r, not /run/keyryx/attestations" % env.get("TRAILRYX_WITNESS_ATTESTATIONS"))
if "TRAILRYX_KEYRYX_KID" not in env:
    problems.append("A. record-seal sets no TRAILRYX_KEYRYX_KID: trailryx 1.5.0 refuses to start with the keyryx signer and no pin")
vols = [v for v in seal.get("volumes") or [] if isinstance(v, dict)]
key_mounts = [v for v in vols if v.get("target") == "/run/keyryx/record-seal.key"]
if not key_mounts or not key_mounts[0].get("read_only"):
    problems.append("A. the credential is not mounted read only at /run/keyryx/record-seal.key")
att = [v for v in vols if v.get("target") == "/run/keyryx/attestations"]
if not att or not att[0].get("read_only") or not str(att[0].get("source", "")).endswith("keyryxattest"):
    problems.append("A. record-seal does not mount keyryxattest read only at /run/keyryx/attestations")
for v in vols:
    if str(v.get("source", "")).endswith("keyryxwitness"):
        problems.append("A. record-seal mounts the witness's own volume: its data and its key would be in the seal's reach")
wattest = [v for v in witness.get("volumes") or [] if isinstance(v, dict) and v.get("target") == "/var/lib/keyryx-witness/attestations"]
if not wattest or wattest[0].get("read_only") or not str(wattest[0].get("source", "")).endswith("keyryxattest"):
    problems.append("A. the witness does not write its attestations to keyryxattest at /var/lib/keyryx-witness/attestations")
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
  grep -q '^record_seal_key_prepare()' <<<"$BLOCK" || fail "B. the record-signer block defines no record_seal_key_prepare"
  CODE="$(printf '%s\n' "$BLOCK" | grep -v '^[[:space:]]*#')"
  grep -q 'printf .%s. ' <<<"$CODE" || fail "B. the credential is not written with printf %s (a trailing newline would fail every signature)"
  grep -q 'chmod 0400' <<<"$CODE" || fail "B. the credential is not set mode 0400"
  grep -q 'chown 10001:10001' <<<"$CODE" || fail "B. the credential is not given to the seal's uid 10001"
  grep -q '__RECORD_SEAL_DIGEST__' <<<"$CODE" || fail "B. the block does not fill the policy's digest placeholder"
  if grep -q 'echo\|note \|say \|die ' <<<"$CODE"; then
    if grep -q 'secret\|cat ' <<<"$(printf '%s\n' "$CODE" | grep -E 'echo|note |say |die ')"; then
      fail "B. the block prints the credential or reads it to a message"
    fi
  fi
fi

# ---- C. install.sh, behaviour -------------------------------------------------------
if [ -n "$BLOCK" ] && grep -q '^record_seal_key_prepare()' <<<"$BLOCK"; then
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
  if [ -n "$before" ] && grep -qF -- "$before" <<<"$out1$out2"; then
    fail "C. the run printed the credential"
  fi
fi

# ---- D. the root pin and the attestation mode stay TODOs -----------------------------
grep -q 'TODO(keyryx-attest-mode)' compose.yaml && fail "D. compose.yaml still names TODO(keyryx-attest-mode): the attestation read is wired"
grep -q 'TODO(trailryx#112)' compose.yaml && fail "D. compose.yaml still names TODO(trailryx#112): the root pin is wired"
grep -qE '^[[:space:]]+TRAILRYX_KEYRYX_KID:' compose.yaml || fail "D. compose.yaml does not set TRAILRYX_KEYRYX_KID from .env"

# ---- E. a policy that changed is read ---------------------------------------------------
UPBLOCK="$(sed -n '/^# keyryx-up: begin$/,/^# keyryx-up: end$/p' install.sh)"
if [ -z "$UPBLOCK" ]; then
  fail "E. install.sh has no '# keyryx-up:' block, so a changed policy was not measured"
else
  escratch="$(mktemp -d)"
  trap 'rm -rf "${escratch:-}" "${scratch:-}" "${cdir:-}"' EXIT
  cat >"$escratch/compose" <<'EOSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in "ps -q keyryx") [ "${RUNNING:-0}" = 1 ] && echo abc ;; esac
exit 0
EOSTUB
  chmod +x "$escratch/compose"
  run_up() { # RUNNING CHANGED: prints the compose calls keyryx_up made
    : >"$escratch/calls"
    env -i PATH="$PATH" CALLS="$escratch/calls" RUNNING="$1" CHANGED="$2" STUB="$escratch/compose" UPBLOCK="$UPBLOCK" bash -c '
      set -uo pipefail
      note() { :; }
      COMPOSE=("$STUB")
      KEYRYX_POLICY_CHANGED="$CHANGED"
      eval "$UPBLOCK"
      keyryx_up && keyryx_up'
    cat "$escratch/calls"
  }
  [ "$(run_up 1 1 | grep -c '^restart keyryx$')" = 1 ] || fail "E. a changed policy on a running custody is not restarted exactly once, so custody keeps the old policy"
  [ "$(run_up 1 0 | grep -c '^restart keyryx$')" = 0 ] || fail "E. custody is restarted with no change in its policy"
  [ "$(run_up 0 1 | grep -c '^restart keyryx$')" = 0 ] || fail "E. a custody this run started is restarted"
  grep -q '|| KEYRYX_POLICY_CHANGED=1$' install.sh || fail "E. keyryx_prepare never records that the policy changed"
  PIN="$(sed -n '/^trailryx_pin_apply() {/,/^}$/p' install.sh)"
  [ "$(printf '%s\n' "$PIN" | grep -c 'keyryx_up')" -ge 3 ] || fail "E. a path through trailryx_pin_apply reaches 'up' without keyryx_up, so a changed policy stays unread"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 62."
  exit 1
fi
echo "OK: the record seal signs through the box's keyryx with a credential the custody holds only as a digest, the witness attests to the records, the seal reads the attestations volume read only, and pins its root kid (invariants 62 and 63)."
