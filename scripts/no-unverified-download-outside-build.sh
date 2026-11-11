#!/usr/bin/env bash
#
# Enforces invariant 76 of CLAUDE.md: outside the BUILD_FROM_SOURCE branch, install.sh downloads
# nothing from the network that it unpacks, executes or keeps as a file without a check of a hash or
# a signature, bar two named exceptions; and nothing outside that branch reads the stack-k8s tree.
#
# WHY
#
# install.sh used to fetch the tarball of stack-k8s's main branch on EVERY run and unpack it as root
# into $SRC_DIR/stack-k8s: no pin, no check of what came. Every image the stack runs is pulled by
# digest and cosign-verified, so the tree was needed only by the BUILD_FROM_SOURCE path (docker build
# -f stack-k8s/images/...). A moving branch of another repository, unpacked as root on an operator's
# box on each run, for a path that run does not take, is attack surface that buys nothing.
#
# WHAT THIS CHECKS, on the statements of install.sh outside the `if [ -n "$BUILD_FROM_SOURCE" ]; then`
# blocks (a block ends at the next `fi` in column 0):
#
#   A. NO DOWNLOAD THAT IS UNPACKED OR EXECUTED: a curl or wget piped into tar, an interpreter or a
#      decompressor; or written to a file (-o, -O, a redirect) other than /dev/null; or a git clone,
#      pull or fetch. The output of a curl read into a variable (the box's public address) is data
#      the installer reads, not bytes it unpacks or runs, and is not a download in this sense; nor is
#      a probe from a throwaway container on the stack's own network to a service of the stack by name.
#      Exceptions, each with its reason, and each required to MATCH something, so an exception
#      that no longer matches is reported as measuring nothing:
#        1. cosign: the file is written to `$dest.download` and `sha256sum -c` against the pinned
#           SHA-256 must run on that name, and the file must be moved into place only after it.
#        2. the files of THIS repository in a piped install (compose.yaml and the files it names
#           beside itself), fetched from ${REPO_SINGLE_RAW:-...stack-single/main} into $STACK_DIR:
#           configuration that compose and Docker read, version-checked before it is put in place,
#           and never unpacked or run by the installer. `curl | bash` itself is the owner's
#           decision about the channel, and this gate does not judge it.
#   B. NO READ OF THE STACK-K8S TREE: no statement outside the branch names $SRC_DIR/stack-k8s or a
#      stack-k8s/images path, so the ordinary path cannot depend on a tree it no longer fetches.
#   C. NO REPO_RAW: the variable that named stack-k8s's raw URL has no reader, and a variable nobody
#      reads is a pointer at a moving branch waiting for one.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no install.sh, no BUILD_FROM_SOURCE block, no download
# statement at all, or an exception that matches nothing, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

[ -f install.sh ] || { echo "FAIL: install.sh is not there, so this gate measured NOTHING"; exit 1; }

python3 - <<'PY'
import re
import sys

lines = open("install.sh").read().split("\n")
n = len(lines)
bad = []

# the BUILD_FROM_SOURCE blocks: from `if [ -n "$BUILD_FROM_SOURCE" ]; then` in column 0 to the next `fi` in column 0
in_build = [False] * n
blocks = 0
i = 0
while i < n:
    if lines[i] == 'if [ -n "$BUILD_FROM_SOURCE" ]; then':
        blocks += 1
        j = i
        while j < n and lines[j] != "fi":
            in_build[j] = True
            j += 1
        in_build[j if j < n else n - 1] = True
        i = j
    i += 1
if blocks == 0:
    print('FAIL: install.sh has no `if [ -n "$BUILD_FROM_SOURCE" ]; then` block in column 0, so this gate measured NOTHING')
    sys.exit(1)

# logical statements outside the blocks: continuation lines joined, comment-only lines dropped
stmts = []  # (first line number, text, last line number)
i = 0
while i < n:
    if in_build[i] or re.match(r"^\s*#", lines[i]) or not lines[i].strip():
        i += 1
        continue
    start = i
    text = lines[i]
    while text.rstrip().endswith("\\") and i + 1 < n and not in_build[i + 1]:
        i += 1
        text = text.rstrip()[:-1] + " " + lines[i].strip()
    stmts.append((start + 1, text, i + 1))
    i += 1

NET = re.compile(r"(?<![A-Za-z0-9_-])(curl|wget)(?![A-Za-z0-9_-])")
PIPE_TO = re.compile(r"(curl|wget)[^|;&]*\|\s*(sudo\s+)?(tar|sh|bash|zsh|dash|unzip|gunzip|gzip|zcat|bzcat|xzcat|python3?|perl|ruby|xargs)\b")
OUTFILE = re.compile(r"(\s-o\s+\S+|\s--output\s+\S+|\s-O(\s+\S+)?(\s|$)|>\s*\S+)")
GIT = re.compile(r"\bgit\s+(clone|pull|fetch)\b")

matched = {"cosign": 0, "piped": 0}
for lineno, text, last in stmts:
    if text.lstrip().startswith("apt-get ") or text.lstrip().startswith("note ") or text.lstrip().startswith("say "):
        continue
    if re.search(r"\bgit\s+(clone|pull|fetch)\b", text):
        bad.append((lineno, text, "a git clone, pull or fetch outside BUILD_FROM_SOURCE: nothing checks what it brings"))
        continue
    if not NET.search(text):
        continue
    if "docker run" in text and "--network" in text:
        # a throwaway container on the stack's own network asking a service of the stack by name: not the internet
        continue
    if PIPE_TO.search(text):
        bad.append((lineno, text, "a download piped into an archiver or an interpreter, unpacked or run with no check of a hash or a signature"))
        continue
    # an output to a file: -o FILE, -O, or a redirect, other than /dev/null and stdout
    outs = []
    for m in re.finditer(r"(?:\s-o\s+(\S+)|\s--output\s+(\S+)|\s-O\s+(\S+)|>\s*(\S+))", text):
        target = next(g for g in m.groups() if g)
        if target in ("/dev/null", "-", "&1", "&2") or target.startswith("&"):
            continue
        outs.append(target.strip('"').strip("'"))
    if not outs:
        continue
    # exception 1: cosign
    if '"$dest.download"' in " ".join(outs) or "$dest.download" in " ".join(outs):
        window = "\n".join(lines[last:last + 16])
        k = window.find("sha256sum -c")
        m = window.find('mv -f "$dest.download"')
        if k == -1 or "$dest.download" not in window[:m if m != -1 else len(window)] or m == -1 or k > m:
            bad.append((lineno, text, "the cosign download is not checked with sha256sum -c against its pin before it is moved into place"))
        else:
            matched["cosign"] += 1
        continue
    # exception 2: this repository's own files in a piped install
    if "${REPO_SINGLE_RAW:-https://raw.githubusercontent.com/TAIPANBOX/stack-single/main}" in text and all(o.startswith("$STACK_DIR/") for o in outs):
        matched["piped"] += 1
        continue
    bad.append((lineno, text, "a download written to a file with no check of a hash or a signature, and not one of the two named exceptions"))

# B. the stack-k8s tree outside the branch
for lineno, text, last in stmts:
    if re.search(r"\$SRC_DIR/stack-k8s|\$\{SRC_DIR\}/stack-k8s|(^|[\s\"'=])stack-k8s/images/", text):
        bad.append((lineno, text, "reads the stack-k8s tree outside BUILD_FROM_SOURCE, which no longer fetches it"))

# C. REPO_RAW
for k, l in enumerate(lines):
    if re.match(r"^\s*#", l):
        continue
    if re.search(r"\bREPO_RAW\b", l):
        bad.append((k + 1, l.strip(), "REPO_RAW, the raw URL of stack-k8s's main branch, which nothing reads"))

nothing = [name for name, count in matched.items() if count == 0]
for lineno, text, why in bad:
    print(f"FAIL: install.sh:{lineno}: {why}")
    print(f"      {text.strip()[:160]}")
for name in nothing:
    print(f"FAIL: the named exception '{name}' matched nothing in install.sh, so this gate measured NOTHING about it")
if bad or nothing:
    print(f"{len(bad) + len(nothing)} problem(s).")
    sys.exit(1)
print(f"OK: outside the {blocks} BUILD_FROM_SOURCE block(s) install.sh unpacks and runs nothing it downloaded, "
      f"keeps a file only after cosign's SHA-256 check ({matched['cosign']}) or from this repository in a piped install ({matched['piped']}), and reads no stack-k8s tree.")
PY
