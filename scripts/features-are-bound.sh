#!/usr/bin/env bash
#
# Enforces: every Gherkin scenario under features/ is bound to a named case in
# scripts/gates-have-teeth.sh, and every binding names a case that exists.
#
# WHY
#
# `features/*.feature` is what a person reads instead of the diff: Given, When,
# Then, in plain words, for a decision somebody made. It is worth that only
# while each scenario is backed by something that runs. This repository has no
# BDD runner on purpose (a runner is a second step-definition language beside
# the shell gates), so the backing is a case in the teeth harness, named in a
# comment under the scenario:
#
#     # -> gates-have-teeth.sh "run-budget-ceiling: the gateway loses its ceiling"
#
# The binding was by eye until now. By eye is how a scenario outlives the test
# it names: someone renames a case, the scenario still reads true, nothing runs.
#
# THE TWO DIRECTIONS
#
#   1. No scenario without a test: every `Scenario:` has at least one binding
#      line before the next scenario (or the end of the file).
#   2. No binding pointing at nothing: every bound name is the exact text of a
#      `run_case "<name>"` in scripts/gates-have-teeth.sh.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No feature file, no scenario, no binding, or no teeth harness to resolve them
# against: each is reported and fails.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob
import re
import sys

features = sorted(glob.glob("features/*.feature"))
if not features:
    print("FAIL: there is no features/*.feature, so this gate measured NOTHING.")
    sys.exit(1)
try:
    teeth = open("scripts/gates-have-teeth.sh").read()
except OSError:
    print("FAIL: scripts/gates-have-teeth.sh is not there, so no binding can be resolved.")
    sys.exit(1)
cases = set(re.findall(r'^\s*run_case\s+"([^"]+)"', teeth, re.M))
if not cases:
    print("FAIL: scripts/gates-have-teeth.sh has no run_case, so no binding can be resolved.")
    sys.exit(1)

problems = []
scenarios = bindings = 0
for f in features:
    current = None
    bound = {}
    lines = open(f).read().split("\n")
    for n, line in enumerate(lines, 1):
        m = re.match(r"^\s*Scenario(?: Outline)?:\s*(.+?)\s*$", line)
        if m:
            current = (n, m.group(1))
            bound[current] = 0
            scenarios += 1
            continue
        b = re.match(r'^\s*#\s*->\s*gates-have-teeth\.sh\s+"([^"]+)"\s*$', line)
        if b:
            if current is None:
                problems.append(f"{f}:{n}: a binding with no scenario above it")
                continue
            bindings += 1
            bound[current] += 1
            if b.group(1) not in cases:
                problems.append(f'{f}:{n}: bound to "{b.group(1)}", and gates-have-teeth.sh has no such run_case: the scenario names a test that is gone')
    for (n, title), count in bound.items():
        if count == 0:
            problems.append(f"{f}:{n}: scenario \"{title}\" is bound to no test")

if scenarios == 0:
    print("FAIL: no Scenario: in features/, so this gate measured NOTHING.")
    sys.exit(1)
if bindings == 0:
    print("FAIL: no `# -> gates-have-teeth.sh \"...\"` binding anywhere, so this gate measured NOTHING.")
    sys.exit(1)
if problems:
    for p in problems:
        print("FAIL: " + p)
    print(f"{len(problems)} problem(s).")
    sys.exit(1)
print(f"OK: {scenarios} scenario(s) in {len(features)} feature file(s), every one bound to a teeth case that exists ({bindings} binding(s)).")
PY
