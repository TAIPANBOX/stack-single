#!/usr/bin/env bash
#
# Every file an image copies is a file this installer must have fetched.
#
# The Dockerfiles this installer builds with live in ANOTHER repository
# (`TAIPANBOX/stack-k8s`). That repository does not know this consumer exists,
# so a change there can break an install here without a single character
# changing in this repo, and neither side's CI would see it.
#
# It happened: `wg.Dockerfile` grew a `COPY images/uapi-proxy`, which is a
# DIRECTORY beside the Dockerfile. This installer was fetching exactly five
# `.Dockerfile` files by raw URL, so the directory was never there, and a clean
# `curl | bash` died ten minutes in with
#
#   failed to compute cache key: "/images/uapi-proxy": not found
#
# The fetch is a whole tarball now, which cannot drift file by file. This check
# is the ratchet on top: it reads every COPY and ADD source out of the
# Dockerfiles and fails if one of them is not in the context the installer
# builds with. It catches the NEXT thing added, not the one already fixed.
#
#   ./scripts/build-context-complete.sh              # fetches stack-k8s
#   SRC=~/Development/stack-k8s ./scripts/build-context-complete.sh   # local
#
# This file is the ONE copy of this check: `.github/workflows/gates.yml` and
# `.githooks/pre-push` both call it.
#
# What it does NOT check, stated so nobody mistakes it for more: build ARGs
# resolved at build time, glob patterns, and the sibling repositories the
# installer clones on its own. It judges one thing, the thing that broke:
# files that live beside a Dockerfile inside stack-k8s.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${SRC:-}"
TARBALL="${REPO_TARBALL:-https://api.github.com/repos/TAIPANBOX/stack-k8s/tarball/main}"
TMP=""

if [ -z "$SRC" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "fetching the image definitions from stack-k8s ..."
  curl -fsSL "$TARBALL" | tar -xz -C "$TMP" --strip-components=1 \
    || { echo "FAIL: could not fetch $TARBALL"; exit 1; }
  SRC="$TMP"
fi

[ -d "$SRC/images" ] || { echo "FAIL: $SRC has no images/ directory"; exit 1; }

# The exact set install.sh builds with. Kept here rather than derived, so that
# adding an image to the installer without adding it here is visible.
DOCKERFILES="go-service.Dockerfile tokenfuse.Dockerfile console.Dockerfile wg.Dockerfile caddy.Dockerfile"

fail=0
checked=0

for f in $DOCKERFILES; do
  path="$SRC/images/$f"
  if [ ! -f "$path" ]; then
    echo "FAIL: images/$f is missing from stack-k8s; install.sh builds with it"
    fail=1
    continue
  fi

  # COPY/ADD sources, minus the destination (last field) and minus --flags.
  # `COPY --from=build ...` copies from an earlier STAGE, not from the context,
  # so it is skipped: there is no file on disk to check.
  while IFS= read -r line; do
    case "$line" in *--from=*) continue ;; esac
    # Strip the instruction and the destination, leaving the sources.
    args="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(COPY|ADD)[[:space:]]+//I')"
    set -- $args
    [ "$#" -ge 2 ] || continue
    n="$#"
    i=0
    for src in "$@"; do
      i=$((i + 1))
      [ "$i" -lt "$n" ] || break          # the last argument is the destination
      # ONLY paths under `images/`, and the narrowness is the point.
      #
      # The other sources in these Dockerfiles are things this check cannot
      # judge and must not pretend to: `${SRC}/go.mod` is a build ARG resolved
      # at build time, `go.su[m]` is the glob trick for an optional file, and
      # `qryx/`, `engram/`, `genaryx-a360/` name sibling REPOSITORIES the
      # installer clones separately, which are not in stack-k8s at all.
      #
      # The first draft checked all of them and reported eleven failures on a
      # tree that builds perfectly. A check that cries wolf gets disabled, and
      # then the one real thing it would have caught goes through. `images/` is
      # exactly the class that broke here: a file that lives beside the
      # Dockerfile and travels only if somebody remembered to fetch it.
      case "$src" in
        images/*) ;;
        *) continue ;;
      esac
      checked=$((checked + 1))
      if [ ! -e "$SRC/$src" ]; then
        echo "FAIL: images/$f copies '$src', which is not in the stack-k8s tarball"
        fail=1
      fi
    done
  done < <(grep -iE '^[[:space:]]*(COPY|ADD)[[:space:]]' "$path" || true)
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "An image needs a file this installer does not have. The Dockerfiles come"
  echo "from another repository that does not know this one exists, so this is"
  echo "the seam where a clean install breaks with nothing here having changed."
  exit 1
fi

echo "OK: $checked build-context path(s) across 5 Dockerfiles, every one present."
