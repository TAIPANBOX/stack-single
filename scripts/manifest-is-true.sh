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
#   schedules_routines  the loops this launcher runs, mapped to estate names
#   manual_jobs         services a PERSON runs, never started by an install,
#                       and the check that holds it is below
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
# A manual job is a compose SERVICE too, so it belongs in the declared set the
# service comparison uses. It is listed apart because what it is, is the whole
# point: `installs_services` is what `up` starts, and this is the one thing here
# that `up` must never start.
manual = checked.get("manual_jobs", {})
if not isinstance(manual, dict):
    print("FAIL: components.json's manual_jobs is not a map of service name to reason,")
    print("      so this measured NOTHING about what a person is expected to run.")
    problems += 1
    manual = {}

compare(
    "a compose service",
    list(checked.get("installs_services", [])) + sorted(manual),
    services,
    "no two-space-indented service key in compose.yaml",
)

# WHAT HOLDS THE CATEGORY, AND WHY IT IS THIS
#
# stack-k8s checks that a job it calls manual actually sets `suspend: true`.
# Compose has no suspend, so the equivalent property is that no install can
# start it: the service sits behind a profile, and install.sh never passes that
# profile. Both halves are checked, because either one alone is satisfiable
# while the job still comes up on somebody's box.
#
# Calling a job manual and leaving it startable is the failure this refuses.
# The one here cannot even run as a loop: idryx's image is distroless, so a
# shell loop in it never starts, which is how a service nothing could launch sat
# in this file unnoticed behind a profile install.sh never enabled.
for name, reason in sorted(manual.items()):
    if not str(reason).strip():
        print(f"FAIL: components.json calls {name!r} a manual job and gives no reason.")
        print("      A category with no reason beside it is a label.")
        problems += 1
    block = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)",
                      compose, re.M | re.S)
    if not block:
        print(f"FAIL: components.json calls {name!r} a manual job and compose.yaml")
        print("      has no such service, so this measured NOTHING about it.")
        problems += 1
        continue
    prof = re.search(r'profiles:\s*\["([a-z-]+)"\]', block.group(1))
    if not prof:
        print(f"FAIL: {name!r} is declared a manual job and sits behind no profile,")
        print("      so `docker compose up` starts it like any other service.")
        problems += 1
        continue
    if f"--profile {prof.group(1)}" in install:
        print(f"FAIL: {name!r} is declared a manual job behind the {prof.group(1)!r}")
        print(f"      profile, and install.sh passes --profile {prof.group(1)}, so an")
        print("      install starts it. A manual job an install starts is not one.")
        problems += 1

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

# What it PULLS, which since 2026-09-01 is most of the stack and is the whole
# reason a fresh install no longer waits on a compiler. Derived from the image
# lines in compose.yaml rather than from a list here, so a tag bumped in one
# place cannot leave this saying the other.
#
# The default half of a `${VAR:-default}` is what is taken: that is what an
# operator who sets nothing actually runs, and the override exists precisely so
# a box CAN run something else. A manifest that recorded the override would be
# recording a hypothetical.
pulls = sorted(set(re.findall(r"^\s+image: \$\{[A-Z_]+:-(ghcr\.io/[^}]+)\}", compose, re.M)))
compare(
    "an image it pulls",
    checked.get("pulls_images", []),
    pulls,
    "no `image: ${VAR:-ghcr.io/...}` line in compose.yaml",
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
# A map from THIS deployment's own name for a thing to the routine the estate
# means, the same shape stack-k8s uses for its five CronJobs. It is a map rather
# than a list because the names differ: the `record` profile's service is called
# `record-seal` here and `trailryx-seal` everywhere else, and a list would have
# to choose one vocabulary and be wrong in the other.
ROUTINES = {"focus-export", "qryx-trend", "verdryx-drift", "idryx-detect",
            "mockryx-drill", "trailryx-seal"}
schedules = checked.get("schedules_routines", {})
if not isinstance(schedules, dict):
    print("FAIL: components.json's schedules_routines is not a map of local name to")
    print("      routine, so this measured NOTHING about what runs here.")
    problems += 1
    schedules = {}

for local, routine in sorted(schedules.items()):
    if routine not in ROUTINES:
        print(f"FAIL: components.json maps {local!r} to {routine!r}, which is not one of")
        print(f"      the estate's routines: {sorted(ROUTINES)}")
        problems += 1
    if local not in services:
        print(f"FAIL: components.json says {routine!r} runs here as {local!r} and compose")
        print(f"      starts no such service.")
        problems += 1
if len(set(schedules.values())) != len(schedules):
    print("FAIL: two services are mapped to the same routine. One routine runs once per")
    print("      deployment, so this map cannot be right.")
    problems += 1

# And the other direction, which is what catches a routine arriving without the
# manifest saying so: a routine NAME appearing in the files, comments stripped,
# that nothing here claims.
uncommented = "\n".join(
    line.split("#", 1)[0] for line in (install + "\n" + compose).split("\n")
)
declared_routines = sorted(schedules.values())
# A routine name may be accounted for two ways, and the difference is the point.
# `schedules_routines` says this launcher RUNS it on a loop. `manual_jobs` says
# the work is here and a person starts it. Both are answers; neither is silence.
# Only an unaccounted name is a finding, which is the case where the work sits
# in the files and the manifest says nothing at all about it.
accounted = set(declared_routines) | set(manual)
for r in sorted(ROUTINES):
    if r in uncommented and r not in accounted:
        print(f"FAIL: {r!r} appears in this launcher's files and components.json does not")
        print(f"      say it runs here, on a loop or by hand.")
        problems += 1

if problems:
    print()
    print(f"{problems} problem(s). components.json and this launcher disagree.")
    sys.exit(1)

print(f"OK: {len(services)} compose service(s), {len(checked.get('profiles', []))} profile(s) "
      f"and {len(images)} image(s) it builds and {len(pulls)} it pulls, each")
print("    compared with compose.yaml and install.sh, both ways.")
if declared_routines:
    print(f"    Runs as a loop rather than a timer: {', '.join(declared_routines)}.")
else:
    print("    It schedules nothing, which is checked rather than assumed.")
if manual:
    print(f"    Started by a person, never by an install: {', '.join(sorted(manual))}.")
not_here = sorted(set(ROUTINES) - set(declared_routines) - set(manual))
if not_here:
    print(f"    Not run here: {', '.join(not_here)}. estate-gates is where that is judged.")
PY
