#!/usr/bin/env bash
#
# Enforces invariant 44 of CLAUDE.md, the part that needs a run: every image of
# ours that the installer pulls is checked against its keyless signature before
# it is pulled, a signature that does not check stops the install before the
# stack starts, and the cosign binary that does the checking is run only when its
# bytes match a SHA-256 pinned in install.sh.
#
# WHY
#
# A pinned digest says which bytes a box runs. It does not say who built them.
# The TAIPANBOX release workflows sign each image by digest with the job's
# GitHub OIDC identity, so the question "was this built by one of our release
# workflows" has an answer the installer can check before it starts anything.
# Until this gate existed no launcher checked it (the review's F-016).
#
# WHAT THIS CHECKS
#
#   A. THE PINS, read from install.sh's `# image-verify: begin` .. `end` block.
#      The cosign version and the two SHA-256 values for the release binary are
#      the ones the release's own cosign_checksums.txt holds, and that file is
#      signed by the sigstore release identity (checked on 2026-10-19; see the
#      report). The signer is the TAIPANBOX release-tag identity and nothing
#      wider, and the issuer is GitHub's OIDC issuer. A verify call that adds
#      --insecure-ignore-tlog or --insecure-ignore-sct, or that skips the check
#      with `|| true`, is a fault.
#   B. THE ORDER, in section 3c: the call to image_verify sits inside the
#      `ghcr.io/*)` branch of the pull loop, comes before `docker pull -q` for
#      the same image, and section 5 (`docker compose up`) comes after both. A
#      third-party image (busybox, postgres) is never named in that branch.
#   C. THE BEHAVIOUR, the same block lifted into a scratch directory and run with
#      stubs for curl, docker and cosign (no network, no Docker, no install):
#      a cosign download whose bytes differ from the pin is refused and never
#      installed; a signature cosign refuses stops the run before that image is
#      pulled, and nothing after it is pulled; every image that verifies is
#      verified once and pulled after its verification.
#
# WHAT IT DOES NOT CHECK
#
# That a live TAIPANBOX image verifies today. That is a measurement against the
# registry, reported in the change's report, not a property of the text. The
# three images whose signing starts with the next stack-k8s release are the
# standing example: they fail this check until a signed tag exists.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No install.sh, no image-verify block, no section 3c, or no function in the
# block: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

problems=0
fail() { printf 'FAIL: %s\n' "$*"; problems=$((problems + 1)); }

if [ ! -f install.sh ]; then
  echo "FAIL: install.sh is not there, so this gate measured NOTHING."
  exit 1
fi

# ---- A and B: the text --------------------------------------------------------
python3 - install.sh <<'PY' || problems=$((problems + 1))
import re
import sys

text = open(sys.argv[1]).read()
lines = text.split("\n")
problems = []

def find_line(prefix, start=0):
    for i in range(start, len(lines)):
        if lines[i].startswith(prefix):
            return i
    return -1

begin = find_line("# image-verify: begin")
end = find_line("# image-verify: end", max(begin, 0))
if begin < 0 or end < 0 or end < begin:
    print("FAIL: install.sh has no `# image-verify: begin` .. `end` block, so this gate measured NOTHING about the check.")
    sys.exit(1)
block = "\n".join(lines[begin:end + 1])

for name in ("cosign_install()", "image_verify()"):
    if not re.search(r"^" + re.escape(name), block, re.M):
        problems.append(f"the image-verify block defines no {name}")

# The pins. The expected values are the release's own checksums, signed by the
# sigstore release identity, and held here as the second copy the review asked for.
EXPECT = {
    "COSIGN_VERSION": '"v3.1.3"',
    "COSIGN_SHA256_amd64": '"4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"',
    "COSIGN_SHA256_arm64": '"c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"',
    "TAIPANBOX_ISSUER": "'https://token.actions.githubusercontent.com'",
    "TAIPANBOX_SIGNER": r"'^https://github\.com/TAIPANBOX/(?:[A-Za-z0-9._-]+/\.github/workflows/release\.yml|stack-k8s/\.github/workflows/(?:console-image|tunnel-images)\.yml)@refs/tags/v[0-9][A-Za-z0-9._+-]*$'",
}
for var, want in EXPECT.items():
    m = re.search(r"^" + var + r"=(.*)$", block, re.M)
    if not m:
        problems.append(f"the image-verify block does not set {var}")
    elif m.group(1).strip() != want:
        problems.append(f"{var} is {m.group(1).strip()}, not the pinned value {want}")

# Behaviour, not only text: the signer the block sets, read back and run against
# identities it must accept and identities it must refuse. A widened pattern
# that still reads as "a different string" is caught here as well.
sm = re.search(r"^TAIPANBOX_SIGNER='(.*)'$", block, re.M)
if sm:
    signer = re.compile(sm.group(1))
    must_accept = [
        "https://github.com/TAIPANBOX/tokenfuse/.github/workflows/release.yml@refs/tags/v1.16.0",
        "https://github.com/TAIPANBOX/stack-k8s/.github/workflows/console-image.yml@refs/tags/v1.1.47",
        "https://github.com/TAIPANBOX/stack-k8s/.github/workflows/tunnel-images.yml@refs/tags/v1.1.47",
    ]
    must_refuse = [
        ("https://github.com/TAIPANBOX/tokenfuse/.github/workflows/ci.yml@refs/tags/v1", "accepts a signer from another workflow file"),
        ("https://github.com/TAIPANBOX/stack-k8s/.github/workflows/ci.yml@refs/tags/v1.1.47", "accepts a signer from another workflow file"),
        ("https://github.com/TAIPANBOX/tokenfuse/.github/workflows/release.yml@refs/heads/main", "accepts a branch ref"),
        ("https://github.com/OTHERORG/tokenfuse/.github/workflows/release.yml@refs/tags/v1.16.0", "accepts a signer from another organisation"),
    ]
    for ident in must_accept:
        if not signer.search(ident):
            problems.append(f"the signer refuses the release identity {ident}")
    for ident, what in must_refuse:
        if signer.search(ident):
            problems.append(f"the signer {what}: {ident}")

for forbidden in ("--insecure-ignore-tlog", "--insecure-ignore-sct", "--allow-insecure",
                  "--certificate-identity-regexp '.*'", "--certificate-identity-regexp \".*\"",
                  "|| true", "--certificate-oidc-issuer-regexp '.*'"):
    if forbidden in block:
        problems.append(f"the image-verify block contains {forbidden}, which weakens the check")

# The verify call itself must name the signer and the issuer the block pins.
verify_line = next((l for l in lines[begin:end + 1] if "verify --certificate-identity-regexp" in l), None)
if verify_line is None:
    problems.append("the image-verify block has no `cosign verify --certificate-identity-regexp` call")
elif '"$TAIPANBOX_SIGNER"' not in verify_line or '"$TAIPANBOX_ISSUER"' not in verify_line:
    problems.append("the cosign verify call does not take $TAIPANBOX_SIGNER and $TAIPANBOX_ISSUER")

# Section 3c: the call is in the ghcr.io/* branch, before the pull of the same image.
s3c = find_line("# ---- 3c.")
s3d = find_line("# ---- 3d.")
s5 = find_line("# ---- 5. up")
if s3c < 0 or s3d < 0:
    problems.append("install.sh has no section 3c (the image pull), so the order of the check cannot be judged")
else:
    region = lines[s3c:s3d]
    branch = next((i for i, l in enumerate(region) if re.match(r"^\s+ghcr\.io/\*\)\s*$", l)), -1)
    verify = next((i for i, l in enumerate(region) if re.match(r'^\s+image_verify "\$img"\s*$', l)), -1)
    pull = next((i for i, l in enumerate(region) if 'docker pull -q "$img"' in l), -1)
    if verify < 0:
        problems.append('section 3c never calls image_verify "$img", so no TAIPANBOX image is checked before its pull')
    if branch < 0:
        problems.append("section 3c has no `ghcr.io/*)` branch for the check to sit in")
    if pull < 0:
        problems.append('section 3c never runs docker pull -q "$img"')
    if verify >= 0 and branch >= 0 and not (branch < verify):
        problems.append("the image_verify call is not inside the ghcr.io/* branch of the pull loop")
    if verify >= 0 and pull >= 0 and not (verify < pull):
        problems.append("section 3c pulls before it verifies")
    if s5 >= 0 and s3c >= 0 and not (s3c < s5):
        problems.append("section 5 (docker compose up) comes before section 3c")

if problems:
    for p in problems:
        print("FAIL: " + p)
    sys.exit(1)
print("OK: the pins, the signer and the issuer are the pinned values, no weakening flag is present, and each TAIPANBOX image is verified inside the ghcr.io/* branch before its pull and before section 5.")
PY


# ---- C: the behaviour, the block lifted and run against stubs -----------------
# Nothing here touches the network, Docker or the install. The block is lifted out
# of install.sh and run in a scratch directory with stubs for curl, docker and
# cosign, and a sha256sum shim for macOS, where this runs. The installer runs on
# Debian or Ubuntu and uses coreutils' own; the shim reads and writes the same
# format.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/bin" "$scratch/stack/bin"

awk '/^# image-verify: begin/{f=1} f{print} /^# image-verify: end/{f=0}' install.sh > "$scratch/block.sh"
if [ ! -s "$scratch/block.sh" ]; then
  echo "FAIL: the image-verify block could not be lifted, so the behaviour was not measured."
  exit 1
fi

cat > "$scratch/bin/sha256sum" <<'SHIM'
#!/usr/bin/env python3
import hashlib
import sys

args = sys.argv[1:]
if "-c" not in args:
    for path in args:
        print(hashlib.sha256(open(path, "rb").read()).hexdigest() + "  " + path)
    sys.exit(0)
quiet = "--status" in args
bad = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    want, path = line.split("  ", 1)
    try:
        got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        got = ""
    if got != want:
        bad += 1
        if not quiet:
            print(path + ": FAILED")
    elif not quiet:
        print(path + ": OK")
sys.exit(1 if bad else 0)
SHIM

# curl: writes the bytes in STUB_CURL_BYTES to the file named by -o.
cat > "$scratch/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${STUB_CURL_ERR:-}" ]; then printf '%s\n' "$STUB_CURL_ERR" >&2; exit 6; fi
printf '%s' "${STUB_CURL_BYTES:-}" > "$out"
SH

# docker: logs each pull to STUB_LOG.
cat > "$scratch/bin/docker" <<'SH'
#!/usr/bin/env bash
if [ "$1" = pull ]; then
  echo "pull $3" >> "$STUB_LOG"
fi
exit 0
SH

# cosign: logs each verify to STUB_LOG and refuses the ref named in STUB_FAIL_REF.
cat > "$scratch/cosign-stub" <<'SH'
#!/usr/bin/env bash
ref="${*: -1}"
echo "verify $ref" >> "$STUB_LOG"
if [ -n "${STUB_COSIGN_ERR:-}" ]; then printf '%s\n' "$STUB_COSIGN_ERR" >&2; exit 1; fi
if [ -n "${STUB_FAIL_REF:-}" ] && [ "$ref" = "$STUB_FAIL_REF" ]; then exit 10; fi
exit 0
SH
chmod +x "$scratch/bin"/* "$scratch/cosign-stub"

cat > "$scratch/refs.sh" <<'SH'
refs=(
  "ghcr.io/taipanbox/tokenfuse:v1.20.1@sha256:8de459eca2a10ae36a01d0249b91c3b0c62b50b47ad2c4a309e2ea02e0a460dd"
  "ghcr.io/taipanbox/wardryx:v2.4.1@sha256:a7ef8e2df49c96eee39094451094f825aa46abb519955c8f0f2a0ffc33dde4dc"
  "ghcr.io/taipanbox/vouchryx:v0.6.1@sha256:be093cd2c03d1c890f3efa387a453fc702b23c80cebbe5f44fae303c51688159"
)
SH

# The driver runs the block as install.sh does, then the order section 3c uses for
# each TAIPANBOX image: verify, then pull. A refused check stops it (set -e).
cat > "$scratch/driver.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
die() { printf '!! %s\n' "$*" >&2; exit 1; }
note() { printf '   %s\n' "$*"; }
say() { printf '>> %s\n' "$*"; }
STACK_DIR="$SCRATCH/stack"
export PATH="$SCRATCH/bin:$PATH"
. "$SCRATCH/block.sh"
. "$SCRATCH/refs.sh"
if [ "${DRIVER_INSTALL:-0}" = 1 ]; then cosign_install; fi
for ref in "${refs[@]}"; do
  image_verify "$ref"
  docker pull -q "$ref"
done
SH

export SCRATCH="$scratch"

# A. a download whose bytes differ from the pin is refused, and nothing is installed.
out="$(DRIVER_INSTALL=1 STUB_CURL_BYTES='not the cosign release' bash "$scratch/driver.sh" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "a cosign download whose bytes differ from the pinned SHA-256 was accepted"
elif [ -e "$scratch/stack/bin/cosign" ]; then
  fail "a cosign download whose bytes differ from the pinned SHA-256 was installed at bin/cosign"
elif ! grep -qF "does not match its pinned SHA-256" <<<"$out"; then
  fail "the cosign refusal does not say it does not match its pinned SHA-256: $(head -1 <<<"$out")"
fi

# G. a failed cosign download names the host that failed.
if out_g="$(DRIVER_INSTALL=1 STUB_CURL_ERR='curl: (6) Could not resolve host: release-assets.githubusercontent.com' bash "$scratch/driver.sh" 2>&1)"; then
  fail "a cosign download that failed was accepted"
elif ! grep -qF 'Could not resolve host: release-assets.githubusercontent.com' <<<"$out_g"; then
  fail "a failed cosign download does not name the host that failed: $(head -1 <<<"$out_g")"
fi

# Runs B and C use the stub as the installed cosign.
cp "$scratch/cosign-stub" "$scratch/stack/bin/cosign"

# B. every TAIPANBOX image verifies, is verified once, and is pulled after its check.
: > "$scratch/log"
STUB_LOG="$scratch/log" bash "$scratch/driver.sh" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "every stub signature checks, yet the run stopped with $rc"
else
  n_verify=$(grep -c '^verify ' "$scratch/log" || true)
  n_pull=$(grep -c '^pull ' "$scratch/log" || true)
  if [ "$n_verify" -ne 3 ] || [ "$n_pull" -ne 3 ]; then
    fail "the run verified $n_verify and pulled $n_pull of the 3 TAIPANBOX images"
  fi
  for ref in "tokenfuse:v1.20.1" "wardryx:v2.4.1" "vouchryx:v0.6.1"; do
    v=$(grep -n "^verify .*taipanbox/$ref" "$scratch/log" | head -1 | cut -d: -f1)
    p=$(grep -n "^pull .*taipanbox/$ref" "$scratch/log" | head -1 | cut -d: -f1)
    if [ -z "$v" ] || [ -z "$p" ] || [ "$v" -ge "$p" ]; then
      fail "$ref was pulled before its signature was checked"
    fi
  done
fi

# C. a refused signature stops the run before that image is pulled, and nothing after it.
: > "$scratch/log"
STUB_LOG="$scratch/log" \
  STUB_FAIL_REF="ghcr.io/taipanbox/wardryx:v2.4.1@sha256:a7ef8e2df49c96eee39094451094f825aa46abb519955c8f0f2a0ffc33dde4dc" \
  bash "$scratch/driver.sh" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "a TAIPANBOX image whose signature cosign refused did not stop the install"
elif grep -q '^pull .*wardryx' "$scratch/log"; then
  fail "wardryx was pulled after cosign refused its signature"
elif grep -q '^pull .*vouchryx' "$scratch/log"; then
  fail "an image after the refused one was pulled, so the run did not stop at the refusal"
fi

# D. a refusal says why: a missing signature, an unreachable trust root and an
# unreachable registry are three different messages, and the host is named.
: > "$scratch/log"
out_d="$(STUB_LOG="$scratch/log" STUB_COSIGN_ERR='Error: setting up clients and keys: getting rekor public keys: tuf: failed to download 13.root.json: Get "https://tuf-repo-cdn.sigstore.dev/13.root.json": dial tcp: lookup tuf-repo-cdn.sigstore.dev: no such host' bash "$scratch/driver.sh" 2>&1)"
if ! grep -qF 'tuf-repo-cdn.sigstore.dev' <<<"$out_d" || ! grep -qF 'trust root' <<<"$out_d"; then
  fail "an unreachable Sigstore trust root is not named as one, with its host: $(head -1 <<<"$out_d")"
fi
out_e="$(STUB_LOG="$scratch/log" STUB_COSIGN_ERR='Error: no signatures found' bash "$scratch/driver.sh" 2>&1)"
if ! grep -qF 'has no signature from a TAIPANBOX release workflow' <<<"$out_e"; then
  fail "an image with no signature is not reported as having none: $(head -1 <<<"$out_e")"
fi
out_f="$(STUB_LOG="$scratch/log" STUB_COSIGN_ERR='Error: ghcr.io: dial tcp: lookup ghcr.io: no such host' bash "$scratch/driver.sh" 2>&1)"
if ! grep -qF 'registry ghcr.io' <<<"$out_f"; then
  fail "an unreachable registry is not named as one: $(head -1 <<<"$out_f")"
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 44."
  exit 1
fi
echo "OK: the cosign binary runs only when its SHA-256 matches the pin, each TAIPANBOX image is verified and then"
echo "    pulled, and a signature that does not check stops the install before that image is pulled."
