#!/usr/bin/env bash
# CLAUDE.md invariant 84: a piped install installs the latest release, from one tarball whose cosign bundle checks
# against this repository's release workflow on that tag, and nothing from main unless INSTALL_FROM_MAIN=1.
#
# WHAT THIS CHECKS
#
#   A. the `# tree-bootstrap:` block, lifted out of install.sh and run in a scratch directory against a stub
#      `curl` (serving fixture releases, a 302 for /releases/latest, a 404 for anything else), a stub cosign
#      (it accepts a bundle that says GOOD, and records the identity and issuer it was asked for) and fixture
#      trees whose install.sh only says it ran:
#        the latest release, signed              -> its tree runs, told STACK_TREE_VERIFIED=<tag>; cosign was asked
#                                                   for exactly this repository's release.yml on that tag, and
#                                                   GitHub's issuer
#        a bad signature, no bundle, a tree of another version, a tarball naming ../, a tag that is not vX.Y.Z
#                                                -> refused, the tree never runs, main is never fetched, the
#                                                   temporary directory is gone and STACK_DIR was not created
#        STACK_TAG=vX.Y.Z                         -> that release, checked the same way, even an older one
#        /releases/latest naming a release older than the script -> refused (a mirror cannot roll a box back)
#        INSTALL_FROM_MAIN=1                      -> main's tree runs, told main-unsigned, the run says UNSIGNED,
#                                                   and cosign is not asked to bless it
#        INSTALL_FROM_MAIN=1 with STACK_TAG       -> refused
#        a tree beside the script, or STACK_TREE_VERIFIED already set -> nothing is fetched
#        a tree that runs and fails                -> its status is the run's, and the temporary tree is gone
#        a file named `main` beside compose.yaml and install.sh in the current directory, the script piped
#                                                 -> still a piped install (BASH_SOURCE inside a function)
#   B. static: the identity is exactly this repository's release.yml on refs/tags/; release.yml exists, runs on v*
#      tags, signs the asset install.sh fetches with --bundle and uploads it; install.sh fetches nothing from
#      raw.githubusercontent.com/.../stack-single/main; section 1 refuses when no tree is beside it; the README's
#      install line is the latest release's install.sh.
#
# It refuses to report OK when it measured nothing: no block, no function, no release workflow.
#
# Scenarios: features/a-piped-install-takes-a-signed-release.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "piped-tree".
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/piped-tree.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail=0
bad() { printf 'FAIL piped-tree: %s\n' "$*"; fail=1; }

block="$(sed -n '/^# tree-bootstrap: begin$/,/^# tree-bootstrap: end$/p' install.sh)"
if [ -z "$block" ] || ! grep -q '^tree_bootstrap() {' <<<"$block"; then
	echo "FAIL piped-tree: install.sh has no '# tree-bootstrap:' block with tree_bootstrap(); measured nothing"
	exit 1
fi
[ -f .github/workflows/release.yml ] || { echo "FAIL piped-tree: no .github/workflows/release.yml; measured nothing"; exit 1; }

# ---- fixtures ------------------------------------------------------------------------------------
fx="$work/fx"
mkdir -p "$fx/bin"
mktree() { # DIR VERSION: a tree whose install.sh says it ran, and with what
	mkdir -p "$1"
	printf 'services: {}\n' >"$1/compose.yaml"
	cat >"$1/install.sh" <<EOF
#!/usr/bin/env bash
STACK_VERSION="$2"
echo "TREE RAN verified=\${STACK_TREE_VERIFIED:-} tmp=\${STACK_TREE_TMP:-}"
EOF
}
release() { # TAG VERSION BUNDLE(GOOD|BAD|none) [evil]
	local tag="$1" ver="$2" bundle="$3" evil="${4:-}" d="$fx/releases/download/$1"
	mkdir -p "$d" "$work/build-$tag"
	mktree "$work/build-$tag/stack-single" "$ver"
	if [ "$evil" = evil ]; then
		# the tree, and one member that climbs out of it
		python3 - "$work/build-$tag" "$d/stack-single.tar.gz" <<'PYT'
import io, os, sys, tarfile
src, out = sys.argv[1:3]
with tarfile.open(out, "w:gz") as t:
    t.add(os.path.join(src, "stack-single"), arcname="stack-single")
    data = b"escaped\n"
    ti = tarfile.TarInfo("stack-single/../escaped")
    ti.size = len(data)
    t.addfile(ti, io.BytesIO(data))
PYT
	else
		(cd "$work/build-$tag" && tar -czf "$d/stack-single.tar.gz" stack-single)
	fi
	[ "$bundle" = none ] || printf '%s\n' "$bundle" >"$d/stack-single.tar.gz.sigstore.json"
}
release v9.9.9 9.9.9 GOOD
release v9.9.8 9.9.8 GOOD
release v8.0.0 8.0.0 BAD
release v7.0.0 7.0.0 none
release v6.0.0 6.0.1 GOOD
release v5.0.0 5.0.0 GOOD evil
mkdir -p "$work/build-main"
mktree "$work/build-main/stack-single-main" "0.0.0-main"
(cd "$work/build-main" && tar -czf "$fx/main.tar.gz" stack-single-main)

cat >"$fx/bin/curl" <<'STUB'
#!/usr/bin/env bash
# fixture curl: -o FILE URL, or -I ... -w '%{redirect_url}' URL for /releases/latest
out="" url="" head=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    -fsSI|-I) head=1; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >>"$FX_LOG"
base="https://stub.invalid/releases"
if [ "$head" = 1 ]; then
  [ "$url" = "$base/latest" ] || exit 22
  printf '%s' "$base/tag/${FX_LATEST}"; exit 0
fi
case "$url" in
  "$base"/download/*) f="$FX/releases/download/${url#"$base"/download/}" ;;
  https://stub.invalid/main.tar.gz) f="$FX/main.tar.gz" ;;
  *) exit 22 ;;
esac
[ -f "$f" ] || exit 22
cp "$f" "$out"
STUB
cat >"$fx/cosign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FX_COSIGN"
bundle="" ; for ((i=1;i<=$#;i++)); do [ "${!i}" = --bundle ] && { j=$((i+1)); bundle="${!j}"; }; done
grep -qx GOOD "$bundle" || { echo "Error: none of the expected identities matched" >&2; exit 1; }
EOF_NOT_USED=1
exit 0
STUB
chmod +x "$fx/bin/curl" "$fx/cosign"

# run NAME [env...]: the block in a harness of its own, as a piped script (no tree beside it)
run() {
	local name="$1"
	shift
	local dir="$work/run-$name"
	mkdir -p "$dir"
	: >"$work/$name.curl"
	: >"$work/$name.cosign"
	cat >"$dir/harness.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SELF="\${BASH_SOURCE[0]:-}"
STACK_VERSION="9.9.9"
say() { printf '>> %s\n' "\$*"; }
note() { printf '   %s\n' "\$*"; }
die() { printf '!! %s\n' "\$*" >&2; exit 1; }
cosign_install() { mkdir -p "\$STACK_DIR/bin"; cp "$fx/cosign" "\$STACK_DIR/bin/cosign"; }
$block
echo "BOOTSTRAP RETURNED"
EOF
	out="$(env -i PATH="$fx/bin:/usr/bin:/bin" HOME="$work" TMPDIR="$dir/tmp" FX="$fx" FX_LOG="$work/$name.curl" \
		FX_COSIGN="$work/$name.cosign" FX_LATEST="${LATEST:-v9.9.9}" STACK_DIR="$dir/box" \
		STACK_RELEASE_BASE=https://stub.invalid/releases STACK_MAIN_TARBALL=https://stub.invalid/main.tar.gz \
		"$@" bash -c 'mkdir -p "$TMPDIR"; exec bash "$0"' "$dir/harness.sh" 2>&1 </dev/null)" && rc=0 || rc=$?
	tmpleft="$(ls -A "$dir/tmp" 2>/dev/null || true)"
	boxmade=0
	if [ -e "$dir/box" ]; then boxmade=1; fi
}
refused() { # NAME WHY
	if [ "$rc" = 0 ] || grep -q 'TREE RAN' <<<"$out"; then bad "$1: it was not refused: $(tail -2 <<<"$out")"; return; fi
	grep -q 'Nothing was changed' <<<"$out" || bad "$1: the refusal does not say nothing was changed"
	if grep -q 'main.tar.gz' "$work/$1.curl"; then bad "$1: a refused release fell back to fetching main"; fi
	[ -z "$tmpleft" ] || bad "$1: the temporary directory was left behind: $tmpleft"
	[ "$boxmade" = 0 ] || bad "$1: STACK_DIR was created before the refusal"
}

# ---- A. behaviour ----------------------------------------------------------------------------------
run latest
grep -q 'TREE RAN verified=v9.9.9 ' <<<"$out" || bad "latest: the signed latest release's tree did not run as v9.9.9: $(tail -3 <<<"$out")"
grep -q -- '--certificate-identity https://github.com/TAIPANBOX/stack-single/.github/workflows/release.yml@refs/tags/v9.9.9 ' "$work/latest.cosign" \
	|| bad "latest: cosign was not asked for exactly this repository's release.yml on refs/tags/v9.9.9: $(cat "$work/latest.cosign")"
grep -q -- '--certificate-oidc-issuer https://token.actions.githubusercontent.com ' "$work/latest.cosign" \
	|| bad "latest: cosign was not asked for GitHub's OIDC issuer"
grep -q 'certificate-identity-regexp' "$work/latest.cosign" && bad "latest: the identity is a regexp, not exact"
[ "$boxmade" = 0 ] || bad "latest: STACK_DIR was created by the bootstrap"
[ -z "$tmpleft" ] || bad "latest: the temporary tree and cosign were left behind after the tree ran: $tmpleft"

run bad-signature STACK_TAG=v8.0.0; refused bad-signature
grep -q 'does not carry a signature' <<<"$out" || bad "bad-signature: the refusal does not say the signature did not check"
run no-bundle STACK_TAG=v7.0.0; refused no-bundle
grep -q 'no signature bundle' <<<"$out" || bad "no-bundle: the refusal does not say there is no bundle"
run other-version STACK_TAG=v6.0.0; refused other-version
grep -q "not 6.0.0" <<<"$out" || bad "other-version: the refusal does not name the version it wanted"
run evil STACK_TAG=v5.0.0; refused evil
# The block's own refusal, not tar's: GNU and BSD tar both skip a `..` member, and a check that leans on that
# is a check of tar.
grep -q 'names a path outside itself' <<<"$out" || bad "evil: a tarball member that climbs out was not refused by the block itself: $(tail -2 <<<"$out")"
run not-a-tag STACK_TAG='v1.2.3;rm'; refused not-a-tag
LATEST='../../x' run bad-latest; refused bad-latest
# the server names an older, genuinely signed release as the latest: refused, unless asked for by name
LATEST=v9.9.8 run older-latest; refused older-latest
grep -q 'older than this script' <<<"$out" || bad "older-latest: the refusal does not say the latest named is older than the script"

run pinned STACK_TAG=v9.9.8
grep -q 'TREE RAN verified=v9.9.8 ' <<<"$out" || bad "pinned: STACK_TAG=v9.9.8 did not run that release"
grep -q 'refs/tags/v9.9.8 ' "$work/pinned.cosign" || bad "pinned: cosign was not asked about v9.9.8"
grep -q '/releases/latest' "$work/pinned.curl" && bad "pinned: STACK_TAG still asked which release is the latest"

run main INSTALL_FROM_MAIN=1
grep -q 'TREE RAN verified=main-unsigned ' <<<"$out" || bad "main: INSTALL_FROM_MAIN=1 did not run main's tree as main-unsigned: $(tail -3 <<<"$out")"
grep -q 'UNSIGNED' <<<"$out" || bad "main: the run does not say main is unsigned"
[ -s "$work/main.cosign" ] && bad "main: cosign was asked to bless main's tree"

run main-and-tag INSTALL_FROM_MAIN=1 STACK_TAG=v9.9.9; refused main-and-tag

release v4.0.0 4.0.0 GOOD
sed -i.bak 's/^echo "TREE RAN/echo "TREE RAN AND FAILS"; exit 7; echo "TREE RAN/' "$work/build-v4.0.0/stack-single/install.sh"
(cd "$work/build-v4.0.0" && tar -czf "$fx/releases/download/v4.0.0/stack-single.tar.gz" stack-single)
run tree-fails STACK_TAG=v4.0.0
[ "$rc" = 7 ] || bad "tree-fails: the run did not end with the tree's own status (7), it ended $rc"
[ -z "$tmpleft" ] || bad "tree-fails: a tree that failed left the temporary tree behind: $tmpleft"

# piped (bash reads the script from stdin), from a directory holding main, compose.yaml and install.sh
pd="$work/run-stdin"
mkdir -p "$pd/tmp"
: >"$work/stdin.curl"; : >"$work/stdin.cosign"
for f in main compose.yaml install.sh; do printf 'x\n' >"$pd/$f"; done
printf '#!/usr/bin/env bash\nset -euo pipefail\nSELF="${BASH_SOURCE[0]:-}"\nSTACK_VERSION=9.9.9\nsay() { :; }; note() { :; }; die() { printf "!! %%s\\n" "$*" >&2; exit 1; }\ncosign_install() { mkdir -p "$STACK_DIR/bin"; cp "%s" "$STACK_DIR/bin/cosign"; }\n' "$fx/cosign" >"$work/stdin-harness.sh"
printf '%s\n' "$block" >>"$work/stdin-harness.sh"
printf 'echo "BOOTSTRAP RETURNED"\n' >>"$work/stdin-harness.sh"
out="$(cd "$pd" && env -i PATH="$fx/bin:/usr/bin:/bin" HOME="$work" TMPDIR="$pd/tmp" FX="$fx" FX_LOG="$work/stdin.curl" \
	FX_COSIGN="$work/stdin.cosign" FX_LATEST=v9.9.9 STACK_DIR="$pd/box" STACK_RELEASE_BASE=https://stub.invalid/releases \
	bash <"$work/stdin-harness.sh" 2>&1)" || true
grep -q 'TREE RAN verified=v9.9.9 ' <<<"$out" || bad "stdin: a piped script in a directory holding main, compose.yaml and install.sh was taken for a tree: $(tail -2 <<<"$out")"

run verified STACK_TREE_VERIFIED=v9.9.9
grep -q 'BOOTSTRAP RETURNED' <<<"$out" || bad "verified: a run already given a verified tree fetched again"
[ -s "$work/verified.curl" ] && bad "verified: a run already given a verified tree fetched something"

mkdir -p "$work/run-beside"
printf 'services: {}\n' >"$work/run-beside/compose.yaml"
printf '#!/usr/bin/env bash\n' >"$work/run-beside/install.sh"
run beside
grep -q 'BOOTSTRAP RETURNED' <<<"$out" || bad "beside: a script with its tree beside it fetched a release"
[ -s "$work/beside.curl" ] && bad "beside: a script with its tree beside it fetched something"

# ---- B. static ---------------------------------------------------------------------------------------
grep -qxF "STACK_TREE_SIGNER_PREFIX='https://github.com/TAIPANBOX/stack-single/.github/workflows/release.yml@refs/tags/'" install.sh \
	|| bad "the identity install.sh requires is not exactly this repository's release.yml on refs/tags/"
grep -qxF "STACK_TREE_ISSUER='https://token.actions.githubusercontent.com'" install.sh || bad "the issuer is not GitHub's OIDC issuer"
asset="$(sed -n "s/^STACK_TREE_ASSET='\([^']*\)'$/\1/p" install.sh)"
rel="$(cat .github/workflows/release.yml)"
grep -qE 'tags: \["v\*"\]' <<<"$rel" || bad "release.yml does not run on v* tags"
grep -q 'id-token: write' <<<"$rel" || bad "release.yml cannot sign keyless (no id-token: write)"
grep -qF "sign-blob --yes --bundle $asset.sigstore.json $asset" <<<"$rel" || bad "release.yml does not sign $asset with a bundle of the name install.sh fetches"
grep -qF "$asset $asset.sigstore.json" <<<"$rel" || bad "release.yml does not upload $asset and its bundle"
code="$(grep -v '^[[:space:]]*#' install.sh)"
grep -q 'raw.githubusercontent.com/TAIPANBOX/stack-single/main' <<<"$code" && bad "install.sh still fetches files from raw.githubusercontent.com/.../stack-single/main"
grep -q 'die "no tree beside this script, and no verified tree was fetched for it' install.sh || bad "section 1 does not refuse when no tree is beside it"
grep -qF 'curl -fsSL https://github.com/TAIPANBOX/stack-single/releases/latest/download/install.sh | bash' README.md \
	|| bad "the README's install line is not the latest release's install.sh"

[ "$fail" = 0 ] || exit 1
echo "OK: piped-tree (invariant 84): a piped install runs the latest release's tree only behind a signature from this repository's release workflow on that tag; every refusal leaves the box as it was, and main runs only by name, unsigned"
