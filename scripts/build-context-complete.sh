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

# The exact set install.sh builds with, READ OUT OF install.sh.
#
# This was a hand-written list, with a comment saying that adding an image to
# the installer without adding it here would be visible. It was not visible.
# `scopyx-browser.Dockerfile` had been built by the installer and absent from
# the list for as long as both existed, and this check reported OK across five
# Dockerfiles the whole time. A list of what to check, kept beside the check
# and never compared to reality, is a subject list nothing gates.
#
# Derived now, from the one line that cannot lie about it: the `docker build -f`
# invocations in install.sh. An image the installer stops building drops out on
# its own, and one it starts building is checked the day it is added.
# `|| true` is load-bearing, not defensive noise. Under `set -euo pipefail` a
# grep that matches nothing exits 1, the whole assignment fails, and the script
# dies HERE, silently, before reaching the check below that exists to say so.
# Which means the honest message never printed and the gate looked like a crash
# instead of a finding. Caught by the harness case for exactly this mutation.
DOCKERFILES=$(grep -oE -- '-f stack-k8s/images/[a-z-]+\.Dockerfile' install.sh |
  sed 's|.*images/||' | sort -u || true)

# A derived subject list can derive to nothing: a rename in install.sh, a
# changed quoting style, and this file would sweep an empty set and print OK.
# Saying "measured nothing" is the only honest answer to that.
if [ -z "$DOCKERFILES" ]; then
  echo "FAIL: no 'docker build -f stack-k8s/images/*.Dockerfile' lines in install.sh."
  echo "      This check measured NOTHING. Either the installer stopped building"
  echo "      images, or its invocations changed shape and this pattern missed them."
  exit 1
fi

n_dockerfiles=$(printf '%s\n' "$DOCKERFILES" | grep -c .)
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

# Zero paths checked is not a clean bill of health, it is a check that found
# nothing to check. Until 2026-08-09 this printed "OK: 0 build-context path(s)
# across 5 Dockerfiles, every one present" and exited 0, a sentence asserting
# the opposite of what had happened.
#
# It is one Dockerfile refactor away, and the count is already only 1: every
# COPY here is matched by the `images/` prefix, so rewriting those paths to any
# other prefix in stack-k8s empties this check without touching this repo. That
# seam, between two repositories neither of which knows the other exists, is
# the exact thing this gate was written for.
if [ "$checked" -eq 0 ]; then
  echo "FAIL: no build-context path was checked, so this measured nothing."
  echo "      Every COPY/ADD source under images/ is what this reads;"
  echo "      if the Dockerfiles stopped using that prefix, this check has to"
  echo "      move with them. Silence here is not health."
  exit 1
fi

# Both numbers are counted, not typed. The 5 here was a literal, and it kept
# saying 5 while the set it described was 7.
echo "OK: $checked build-context path(s) across $n_dockerfiles Dockerfile(s), every one present."
