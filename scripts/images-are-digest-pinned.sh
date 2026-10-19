#!/usr/bin/env bash
#
# Enforces invariant 44 of CLAUDE.md, the part that can be read from text: every
# image reference this launcher runs is pinned by digest, in compose.yaml and in
# the places install.sh names an image itself.
#
# WHY
#
# A tag names a moving target. `ghcr.io/taipanbox/wardryx:v2.2.0` is whatever
# the registry holds under that name today, and a registry account that is
# compromised or a tag that is re-pushed changes what a box runs with no change
# in this repository. A digest names the bytes. The tag stays beside it, as a
# reader's clue and as the form every existing pin already uses, and docker
# pulls by the digest, not by the tag.
#
# WHAT THIS CHECKS
#
#   A. COMPOSE. Every `image:` line in compose.yaml, with its `${VAR:-...}`
#      default unwrapped, is `name:tag@sha256:<64 hex>` or, for a third-party
#      image, the same shape. A line with no digest, or a digest that is not a
#      full sha256, is reported by service line.
#   B. THE INSTALLER. Every `ghcr.io/taipanbox/...` reference in install.sh that
#      is not a comment carries a digest, and the digest is the one compose.yaml
#      runs for that same repository and tag. Two pins for one image that differ
#      is a box that starts one build and checks another.
#
# WHAT IT DOES NOT CHECK
#
# That the digest is signed. That is the other half of invariant 44, and
# scripts/images-are-verified.sh judges it. A pinned digest that nobody signed
# is still pinned, and this gate says only that.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No image line in compose.yaml, or no compose.yaml, is reported and fails: a
# gate that found nothing to judge has not judged anything.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import re
import sys

problems = []
DIGEST = re.compile(r"^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$")

try:
    compose = open("compose.yaml").read()
except OSError:
    print("FAIL: compose.yaml is not there, so this gate measured NOTHING.")
    sys.exit(1)

images = []  # (line, reference)
for n, line in enumerate(compose.split("\n"), 1):
    m = re.match(r"^\s+image:\s+(\S+)\s*$", line)
    if not m:
        continue
    value = m.group(1)
    unwrapped = re.match(r"^\$\{[A-Z_]+:-(.+)\}$", value)
    images.append((n, unwrapped.group(1) if unwrapped else value))

if not images:
    print("FAIL: compose.yaml has no image: line, so this gate measured NOTHING.")
    sys.exit(1)

for n, ref in images:
    if not DIGEST.match(ref):
        problems.append(f"compose.yaml:{n}: {ref} is not pinned by a full sha256 digest")

# The digests compose runs, by repository and tag, for the installer check below.
pinned = {}
for _, ref in images:
    m = re.match(r"^([a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+)@(sha256:[0-9a-f]{64})$", ref)
    if m:
        pinned[m.group(1)] = m.group(2)

try:
    install = open("install.sh").read().split("\n")
except OSError:
    print("FAIL: install.sh is not there, so this gate measured NOTHING about the installer.")
    sys.exit(1)

literals = 0
for n, line in enumerate(install, 1):
    if line.lstrip().startswith("#"):
        continue
    for m in re.finditer(r"ghcr\.io/taipanbox/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+(@sha256:[0-9a-f]+)?", line):
        literals += 1
        ref = m.group(0)
        name_tag = ref.split("@", 1)[0]
        if "@sha256:" not in ref:
            problems.append(f"install.sh:{n}: {name_tag} is named by tag only")
            continue
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", ref.split("@", 1)[1]):
            problems.append(f"install.sh:{n}: the digest of {name_tag} is not a full sha256")
            continue
        want = pinned.get(name_tag)
        if want is None:
            problems.append(f"install.sh:{n}: {name_tag} is not one compose.yaml runs, so the two pins can disagree")
        elif want != ref.split("@", 1)[1]:
            problems.append(f"install.sh:{n}: {name_tag} is pinned to a digest compose.yaml does not run")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 44.")
    sys.exit(1)

print(f"OK: all {len(images)} image reference(s) in compose.yaml are pinned by digest, and the "
      f"{literals} ghcr.io/taipanbox reference(s) install.sh names match the digest compose runs.")
PY
