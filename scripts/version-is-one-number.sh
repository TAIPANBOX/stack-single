#!/usr/bin/env bash
# Enforces that the tree says what it is, in one number, in every place that says it.
#
# WHY
#
# Until the install journal the tree named no version at all: install.sh had no constant,
# components.json had none, and a release existed only as a tag and a notes file. A piped
# install fetches install.sh and compose.yaml in two requests, so the two can come from
# different commits, and nothing could tell. The journal records a version, and a version
# that drifts from the notes is a line in that journal that is simply wrong.
#
# WHAT IT HOLDS
#
#   1. install.sh has exactly one `STACK_VERSION="X.Y.Z"` and compose.yaml exactly one
#      `x-stack-version: "X.Y.Z"`, and they are the same number;
#   2. the newest docs/releases/vX.Y.Z.md is that number too: a notes file is what starts a
#      release, so the PR that adds one moves both lines;
#   3. on a tag, the tag is that number.
#
# This compares versions here, in a gate, and nowhere else: the installer's own decision
# reads the rollback index, a plain integer (scripts/rollback-floor.sh).
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No constant, no compose line or no notes file is reported as measuring nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "version-is-one-number: ...")
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob
import os
import re
import subprocess
import sys

try:
    install = open("install.sh").read()
    compose = open("compose.yaml").read()
except OSError:
    print("FAIL: install.sh or compose.yaml is not there, so the version measured NOTHING.")
    sys.exit(1)

in_script = re.findall(r'^STACK_VERSION="(\d+\.\d+\.\d+)"$', install, re.M)
in_compose = re.findall(r'^x-stack-version: "(\d+\.\d+\.\d+)"$', compose, re.M)
if not in_script:
    print('FAIL: install.sh has no STACK_VERSION="X.Y.Z" line, so the version measured NOTHING.')
    sys.exit(1)
if not in_compose:
    print('FAIL: compose.yaml has no x-stack-version: "X.Y.Z" line, so the version measured NOTHING.')
    sys.exit(1)
notes = []
for path in glob.glob("docs/releases/v*.md"):
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)\.md", os.path.basename(path))
    if m:
        notes.append(tuple(int(x) for x in m.groups()))
if not notes:
    print("FAIL: docs/releases has no vX.Y.Z.md, so the version measured NOTHING.")
    sys.exit(1)

problems = []
if len(in_script) != 1:
    problems.append(f"install.sh sets STACK_VERSION {len(in_script)} times")
if len(in_compose) != 1:
    problems.append(f"compose.yaml sets x-stack-version {len(in_compose)} times")
version = in_script[0]
if in_compose[0] != version:
    problems.append(f"install.sh says {version} and compose.yaml says {in_compose[0]}")
newest = ".".join(str(x) for x in max(notes))
if newest != version:
    problems.append(f"the newest notes are docs/releases/v{newest}.md and install.sh says {version}: the PR that adds a notes file moves STACK_VERSION and x-stack-version with it")

# A tag: from the runner when it is one, otherwise whatever points at this commit.
tags = []
if os.environ.get("GITHUB_REF_TYPE") == "tag":
    tags = [os.environ.get("GITHUB_REF_NAME", "")]
else:
    r = subprocess.run(["git", "tag", "--points-at", "HEAD"], capture_output=True, text=True)
    if r.returncode == 0:
        tags = [t for t in r.stdout.split() if re.fullmatch(r"v\d+\.\d+\.\d+", t)]
for tag in tags:
    if tag != "v" + version:
        problems.append(f"this is tag {tag} and install.sh says {version}")

if problems:
    for p in problems:
        print("FAIL: " + p)
    sys.exit(1)
print(f"OK: install.sh, compose.yaml and the newest release notes all say {version}.")
PY
