#!/usr/bin/env bash
# Enforces invariant 5 of CLAUDE.md: fail before doing half the job.
#
# This is a curl-pipe-bash installer running as root on somebody else's machine.
# The failure that matters is not an error, it is a HALF-INSTALL: packages on,
# a service enabled, a directory made, and then a fetch that quietly returned
# nothing. The operator is left with a box that is neither installed nor clean,
# and no way to tell which step stopped.
#
# Two things are checked, and both are already true. This is a ratchet.
#
#   1. Every refusal comes before the first side effect. The root check, the
#      /etc/os-release check and the distro check must all precede the first
#      apt-get, systemctl, mkdir, curl -o or git clone. A preflight that runs
#      after the first package install is not a preflight.
#
#   2. Every fetch, clone and service start carries `|| die`. A `curl -o` whose
#      failure is swallowed writes an empty file, and the next step reads it.
#
# ON INVARIANT 4, "never assume GNU". The debt note asked for a grep for `df -T`
# and friends. Reading the script first showed the premise is weaker than it
# sounds: this installer refuses anything that is not Debian or Ubuntu, in the
# preflight, before it touches the machine. It does not need to be portable
# because it will not run where it would not be. The one `sed -i` in the file is
# inside a message telling the operator how to widen the bind, not a command
# this script runs. So the useful check is this one, not that one.
#
# This file is the ONE copy of this check.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

src = pathlib.Path("install.sh").read_text()
lines = src.splitlines()
problems = []


def first_line(pattern, skip_comment=True):
    for i, l in enumerate(lines, 1):
        if skip_comment and l.lstrip().startswith("#"):
            continue
        if re.search(pattern, l):
            return i
    return None


# ---------------------------------------------------------------- 1. preflight
GUARDS = {
    "the root check": r'id -u.*\|\|\s*die',
    "the os-release check": r'/etc/os-release.*\|\|\s*die',
    "the distro check": r'die "this expects Debian or Ubuntu',
}
SIDE_EFFECTS = {
    "apt-get": r'^\s*apt-get\s',
    "systemctl": r'^\s*systemctl\s',
    "mkdir": r'^\s*mkdir\s',
    "a download": r'^\s*curl\s[^|]*-o\s',
    "a clone": r'^\s*git clone',
}

guard_lines = {}
for name, pat in GUARDS.items():
    n = first_line(pat)
    if n is None:
        problems.append(
            f"{name} is gone from install.sh. It refuses to run on a machine it "
            f"would half-install; removing it is not a simplification."
        )
    else:
        guard_lines[name] = n

if guard_lines:
    last_guard = max(guard_lines.values())
    for name, pat in SIDE_EFFECTS.items():
        n = first_line(pat)
        if n is not None and n < last_guard:
            late = [g for g, l in guard_lines.items() if l > n]
            problems.append(
                f"install.sh:{n} runs {name} before {', '.join(late)} at line "
                f"{last_guard}. A preflight that runs after the first side effect "
                f"is not a preflight: the machine is already changed."
            )

# ----------------------------------------------------------- 2. no silent step
#
# Commands here are frequently continued across lines with a trailing backslash,
# and the guard sits at the end of the whole command. The first version of this
# check looked at the line a command STARTS on plus a fixed window, and missed
# the multi-line `curl -fsSL ... \` whose `-o` and `|| die` are on the next
# line: removing that guard was not caught. A check that cannot see a whole
# command should not be judging it.
def commands(lines):
    """Yield (starting line number, whole logical command)."""
    i = 0
    while i < len(lines):
        raw = lines[i]
        if raw.lstrip().startswith("#"):
            i += 1
            continue
        start = i + 1
        parts = [raw]
        while parts[-1].rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            parts.append(lines[i])
        yield start, " ".join(p.strip().rstrip("\\").strip() for p in parts)
        i += 1


# The command is looked for ANYWHERE in the logical command, not only at its
# start. The second version of this check anchored to the start and missed
# `else git clone ... || die ...; fi`, a one-line if whose command begins with
# `else`. Removing that guard was not caught either.
FETCH = re.compile(r'(^|[;&|]\s*|\b(?:then|else|do)\s+)(curl\s|git clone\b|systemctl enable\b)')
# Prose is not a command: a message telling the operator what to run mentions
# these words without executing them.
PROSE = re.compile(r'^\s*(echo|printf|say|note|die|[A-Z_]+=)')
for lineno, cmd in commands(lines):
    if PROSE.match(cmd):
        continue
    if not FETCH.search(cmd):
        continue
    if "|| die" in cmd or "||die" in cmd:
        continue
    # `|| true` is a deliberate, visible decision to ignore a failure.
    if "|| true" in cmd:
        continue
    problems.append(
        f"install.sh:{lineno} {cmd[:70]!r} has no `|| die`. A fetch whose failure "
        f"is swallowed writes an empty file, and the next step reads it."
    )

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("A half-install leaves a box that is neither installed nor clean, and")
    print("nothing tells the operator which step stopped. See CLAUDE.md invariant 5.")
    sys.exit(1)

print("OK: every refusal precedes the first side effect, and every fetch, clone")
print("    and service start fails loudly.")
PY
