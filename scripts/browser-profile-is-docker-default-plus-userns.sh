#!/usr/bin/env bash
# Enforces that apparmor/scopyx-browser is Docker's default profile plus one rule, `userns,`, and
# that the installer and compose.yaml name the same file and the same profile.
#
# WHY
#
# A profile is a list of rules, and the way one goes wrong is a rule added "to make it work": a
# `mount,` or a `/proc/** w,` written after the first denial. Nothing fails then, Chrome starts,
# and the container has lost the denials that were the reason to have a profile of our own over
# apparmor=unconfined. So the file is compared with docker-default's rules (Docker 26.1.5,
# profiles/apparmor/template.go, with the profile's own name in them), and the only difference
# allowed is `userns,`. A rule that is missing fails as well: a profile that lost
# `deny mount,` is wider than docker-default and looks the same on a page that renders.
#
# Compose hashes the line that names a profile and never the profile, and a loaded profile
# changes under a running container, so a rule that changes is a new name, and the name is the
# one fixed here.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No profile file, no rule in it, or no install.sh to compare the name with: measured nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "browser-profile-is-docker-default-plus-userns: ...";
#  scenarios: features/the-browser-has-a-profile-of-its-own.feature)
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
import sys

problems = []
PROFILE = "scopyx-browser"
try:
    text = open("apparmor/scopyx-browser").read()
except OSError:
    print("FAIL: apparmor/scopyx-browser is not there, so the profile measured NOTHING.")
    sys.exit(1)

# docker-default of Docker 26.1.5, rule by rule, whitespace squeezed, comments off.
DOCKER_DEFAULT = """
network,
capability,
file,
umount,
signal (receive) peer=unconfined,
signal (receive) peer=runc,
signal (receive) peer=crun,
signal (send,receive) peer=NAME,
deny @{PROC}/* w,
deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9/]*}/** w,
deny @{PROC}/sys/[^k]** w,
deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,
deny @{PROC}/sysrq-trigger rwklx,
deny @{PROC}/kcore rwklx,
deny mount,
deny /sys/[^f]*/** wklx,
deny /sys/f[^s]*/** wklx,
deny /sys/fs/[^c]*/** wklx,
deny /sys/fs/c[^g]*/** wklx,
deny /sys/fs/cg[^r]*/** wklx,
deny /sys/firmware/** rwklx,
deny /sys/devices/virtual/powercap/** rwklx,
deny /sys/kernel/security/** rwklx,
ptrace (trace,read,tracedby,readby) peer=NAME,
""".replace("NAME", PROFILE).split("\n")
want = {l.strip() for l in DOCKER_DEFAULT if l.strip()}
ADDED = {"userns,"}

includes, rules, header = [], [], None
for raw in text.split("\n"):
    line = raw.strip()
    if not line:
        continue
    if line.startswith("#include"):
        includes.append(line)
        continue
    if line.startswith("#"):
        continue
    line = re.sub(r"\s+#.*$", "", line).strip()
    if line.startswith("profile "):
        header = line
        continue
    if line == "}":
        continue
    rules.append(re.sub(r"\s+", " ", line))

if not rules:
    print("FAIL: apparmor/scopyx-browser holds no rule, so the profile measured NOTHING.")
    sys.exit(1)
if header != f"profile {PROFILE} flags=(attach_disconnected,mediate_deleted) {{":
    problems.append(f"the profile is not named {PROFILE} with docker-default's flags: {header}")
if sorted(includes) != ["#include <abstractions/base>", "#include <tunables/global>"]:
    problems.append(f"the includes are not docker-default's two (tunables/global and abstractions/base): {includes}")
have = set(rules)
if len(rules) != len(have):
    problems.append("a rule is written twice")
for r in sorted(have - want - ADDED):
    problems.append(f"a rule docker-default does not have: {r}")
for r in sorted(want - have):
    problems.append(f"docker-default's rule is gone: {r}")
for r in sorted(ADDED - have):
    problems.append(f"the one rule this profile exists for is missing: {r}")

# The installer and compose.yaml say the same name.
try:
    install = open("install.sh").read()
except OSError:
    print("FAIL: install.sh is not there, so the name measured NOTHING.")
    sys.exit(1)
if not re.search(r"^BROWSER_AA_FILE=apparmor/scopyx-browser$", install, re.M):
    problems.append("install.sh does not load apparmor/scopyx-browser")
if 'order="scopyx-browser $order"' not in install:
    problems.append("install.sh does not offer scopyx-browser first")
if 'dst="${BROWSER_AA_DIR:-/etc/apparmor.d}/scopyx-browser"' not in install:
    problems.append("install.sh keeps the profile nowhere the host loads at boot")
compose = open("compose.yaml").read()
if "- apparmor=${SCOPYX_BROWSER_APPARMOR:-docker-default}\n" not in compose:
    problems.append("compose.yaml does not read the browser's AppArmor line from SCOPYX_BROWSER_APPARMOR")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print(f"{len(problems)} problem(s) with the browser's profile.")
    sys.exit(1)
print(f"OK: {len(rules)} rules, docker-default's {len(want)} and `userns,`, one name in the profile and in install.sh.")
PY
