#!/usr/bin/env bash
#
# Enforces: components.json says what this launcher actually installs.
#
# WHY A LAUNCHER HAS A MANIFEST AT ALL
#
# Sixteen repositories in this estate declare what they BUILD, and a check in
# each proves that declaration against its own toolchain. A launcher builds
# nothing of its own. What it can say, and nothing else can, is what it
# INSTALLS.
#
# AND THERE IS ALREADY A SECOND OPINION
#
# estate-gates' C5 reads all three launchers from one central file: `register
# <name>` out of a shell script in stack-up, compose service keys here,
# Kubernetes kinds in stack-k8s. Three grammars, one parser, none of it living
# where the fact lives. This is the other statement of the same fact, made where
# it does, so the two can catch each other drifting.
#
# WHAT IT CHECKS, AND WHY EACH ONE IS SEPARATE
#
#   installs_services   the compose service keys, which is what `up` starts
#   schedules_routines  empty here, and checked as empty rather than omitted
#   profiles            the opt-in sets, from `profiles: ["name"]`
#   builds_images       the `stack/*:dev` tags install.sh builds, from BOTH the
#                       explicit `-t` lines and the `<service>:<repo>` loop
#
# The loop is the reason the image check exists in this shape. An image added
# there is invisible to a reader that only knows the explicit lines, in exactly
# the way an undeclared component is invisible to a central registry.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# Every observed list is checked for being empty first, except the one the
# manifest declares empty on purpose. A compose file that stops having service
# keys must read as "measured nothing", not as agreement.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - components.json compose.yaml install.sh <<'PY'
import json
import re
import sys

manifest_path, compose_path, install_path = sys.argv[1:4]

manifest = json.load(open(manifest_path))
compose = open(compose_path).read()
install = open(install_path).read()

components = manifest.get("components") or []
if not components:
    print("FAIL: components.json declares no component, so this measured NOTHING.")
    sys.exit(1)
checked = components[0]["checked"]

problems = 0


def compare(label, declared, observed, empty_means, allow_empty=False):
    global problems
    if not observed and not allow_empty:
        print(f"FAIL: {empty_means}")
        print("      This check measured NOTHING about that list, which is not the")
        print("      same as the list being empty.")
        problems += 1
        return
    for name in sorted(set(observed) - set(declared)):
        print(f"FAIL: this launcher installs {name!r} ({label}) and components.json does not say so")
        problems += 1
    for name in sorted(set(declared) - set(observed)):
        print(f"FAIL: components.json says this launcher installs {name!r} ({label}) and it does not")
        problems += 1


# The service keys, which are the two-space-indented names ABOVE the volumes
# block. Anything after it is a volume and not a service.
end = compose.find("\nvolumes:")
if end < 0:
    print("FAIL: compose.yaml has no `volumes:` block, so the service keys cannot be")
    print("      told from the volume names. This measured NOTHING.")
    sys.exit(1)
services = [
    m.group(1)
    for m in re.finditer(r"^  ([a-z][a-z0-9-]*):\s*$", compose, re.M)
    if m.start() < end
]
compare(
    "a compose service",
    checked.get("installs_services", []),
    services,
    "no two-space-indented service key in compose.yaml",
)

compare(
    "an opt-in profile",
    checked.get("profiles", []),
    sorted(set(re.findall(r'profiles:\s*\["([a-z-]+)"\]', compose))),
    "no `profiles: [\"name\"]` in compose.yaml",
)

# Both forms, because an image added to the loop is invisible to a reader that
# only knows the explicit lines.
images = set(re.findall(r"-t (stack/[a-z-]+:dev)", install))
loop = re.search(r"for pair in ([a-z:. -]+);", install)
if loop:
    images |= {"stack/" + p.split(":")[0] + ":dev" for p in loop.group(1).split()}
compare(
    "an image it builds",
    checked.get("builds_images", []),
    sorted(images),
    "no `-t stack/<name>:dev` and no build loop in install.sh",
)

# The one the manifest declares empty, compared anyway: the day this launcher
# gains a scheduler, the emptiness stops being true and has to be rewritten
# rather than staying quietly correct.
#
# It looks for the estate's ROUTINE NAMES rather than for the word "cron". The
# first draft sniffed for cron/systemd/OnCalendar and fired on a COMMENT in
# compose.yaml saying this launcher has no cron, which is a check failing on
# correct copy: the kind everybody learns to skip. The names are the honest
# subject, they are the same six the other two launchers schedule, and
# `record-seal` is deliberately not among them because it is a service here and
# a CronJob there.
ROUTINES = ["focus-export", "qryx-trend", "verdryx-drift", "idryx-detect",
            "mockryx-drill", "trailryx-seal"]
uncommented = "\n".join(
    line.split("#", 1)[0] for line in (install + "\n" + compose).split("\n")
)
scheduled = sorted({r for r in ROUTINES if r in uncommented})
declared_routines = sorted(checked.get("schedules_routines", []))
if declared_routines != scheduled:
    print(f"FAIL: components.json says this launcher schedules {declared_routines} and")
    print(f"      its files, comments stripped, name {scheduled}.")
    if not declared_routines:
        print("      If a scheduler arrived, this file has to say what it runs.")
    problems += 1

if problems:
    print()
    print(f"{problems} problem(s). components.json and this launcher disagree.")
    sys.exit(1)

print(f"OK: {len(services)} compose service(s), {len(checked.get('profiles', []))} profile(s) "
      f"and {len(images)} image(s) it builds, each compared with compose.yaml and")
print("    install.sh both ways; and it schedules nothing, which is checked rather than")
print("    assumed.")
PY
