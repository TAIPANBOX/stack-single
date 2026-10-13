#!/usr/bin/env bash
#
# Enforces invariant 31 of CLAUDE.md: a secret is minted from a bounded read of
# /dev/urandom, so minting one ends on its own whatever SIGPIPE is set to.
#
# WHAT THIS IS ABOUT
#
# `LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c N` reads a stream that
# never ends, and only the pipe head closes stops tr. With SIGPIPE at its
# default, tr dies of it. With SIGPIPE IGNORED, which is how git runs a hook,
# tr's next write just fails: GNU tr then exits and prints "write error: Broken
# pipe", and macOS's tr never exits at all. @measured 2026-10-14 on macOS:
# `perl -e '$SIG{PIPE}="IGNORE"; alarm 5; exec @ARGV' bash -c 'LC_ALL=C tr -dc
# A-Za-z0-9 </dev/urandom | head -c 5'` was killed by the alarm after 5 s (exit
# 142), and the pre-push hook hung in delegation-key-reused-on-rerun.sh, whose
# copy of the generator was that line; in debian:12-slim (GNU coreutils 9.1)
# install.sh's gen under `trap '' PIPE` returned 40 characters and printed
# "tr: write error: Broken pipe", three runs of three. install.sh itself runs
# on Linux, so the product was not stuck; the gates and the hook on a Mac were.
#
# WHAT THIS CHECKS
#
#   A. NO UNBOUNDED READ. In install.sh, .githooks/* and scripts/*.sh, outside a
#      comment or a message (a double-quoted string with no $( ) in it),
#      /dev/urandom is only ever the file operand of `head -c <count>`.
#      Not a redirect into tr, not `cat`, not any other reader that would take
#      it to the end of a stream that has none. This half is what holds on a
#      runner whose tr happens to exit.
#   B. THE CONTROL. The unbounded line above is run the way the generators are
#      run below, under ignored SIGPIPE with a time bound: it has to either not
#      end within the bound or write to stderr. If it did neither, this harness
#      is not reproducing the fault and its verdicts on the generators below
#      would mean nothing.
#   C. EVERY GENERATOR, RUN. Every `gen()` defined in those files is lifted and
#      run under `set -euo pipefail` with SIGPIPE ignored and a time bound, for
#      every N install.sh asks it for, several times each. Each run has to end
#      within the bound, exit 0, print exactly N characters of A-Za-z0-9 and
#      nothing on stderr; and no two runs may print the same value.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# install.sh defines no gen, or asks it for no length, or no file here reads
# /dev/urandom at all, or the control did not reproduce the fault: each is
# reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import glob
import os
import re
import signal
import subprocess
import sys

BOUND = 10  # seconds a generator gets; a bounded one ends in milliseconds
CONTROL_BOUND = 3
RUNS = 20
UNBOUNDED = "LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 5"

problems = []
files = ["install.sh"] + sorted(glob.glob(".githooks/*")) + sorted(
    f for f in glob.glob("scripts/*.sh")
    if os.path.basename(f) not in ("gen-is-bounded.sh", "gates-have-teeth.sh")
)
files = [f for f in files if os.path.isfile(f)]
texts = {f: open(f).read().split("\n") for f in files}

def code_positions(line):
    """Which characters of a line are shell code rather than text.

    Text is a comment, or the inside of a double-quoted string outside any
    $( ... ) in it: a message such as die "... /dev/urandom is not readable"
    names the file and reads nothing. A single-quoted string counts as code,
    because `bash -c '...'` runs one. Line by line, which is what the scripts
    here need; a string that spans lines is read as code, the strict side.
    """
    code = [True] * len(line)
    stack = ["code"]
    i = 0
    while i < len(line):
        ch = line[i]
        top = stack[-1]
        if ch == "\\":
            if top == "dq":
                code[i] = code[min(i + 1, len(line) - 1)] = False
            i += 2
            continue
        if top == "dq":
            if ch == '"':
                stack.pop()
            elif line.startswith("$(", i):
                stack.append("subst")
                i += 2
                continue
            else:
                code[i] = False
            i += 1
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t;"):
            for j in range(i, len(line)):
                code[j] = False
            break
        if ch == "'":
            j = line.find("'", i + 1)
            i = len(line) if j < 0 else j + 1
            continue
        if ch == '"':
            stack.append("dq")
        elif line.startswith("$(", i):
            stack.append("subst")
            i += 2
            continue
        elif ch == ")" and top == "subst":
            stack.pop()
        i += 1
    return code


# A. Every read of /dev/urandom in code is `head -c <count> /dev/urandom`.
reads = 0
for f, lines in texts.items():
    for n, line in enumerate(lines, 1):
        if "/dev/urandom" not in line:
            continue
        code = code_positions(line)
        for m in re.finditer(r"/dev/urandom", line):
            if not code[m.start()]:
                continue
            reads += 1
            before = line[: m.start()]
            if not re.search(r"\bhead\s+-c\s*\S+\s+$", before):
                problems.append(
                    f"{f}:{n}: reads /dev/urandom with no bound, not as `head -c <count> /dev/urandom`:\n"
                    f"      {line.strip()}\n"
                    f"      with SIGPIPE ignored (as under a git hook) the reader never reaches an end"
                )

if reads == 0:
    print("FAIL: no line of install.sh, .githooks or scripts reads /dev/urandom in code, so")
    print("      the bounded-read half of this gate measured NOTHING.")
    sys.exit(1)


def run(script, bound):
    """Run bash on script with SIGPIPE ignored, as git runs a hook.

    Python itself ignores SIGPIPE, and restore_signals=False lets the child
    inherit that. A new session so the whole group, tr included, can be killed
    when the bound is hit: killing bash alone would leave tr reading forever.
    """
    p = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        restore_signals=False,
        start_new_session=True,
    )
    try:
        out, err = p.communicate(timeout=bound)
        return p.returncode, out.decode(errors="replace"), err.decode(errors="replace"), False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, "", "", True


# B. The control: the unbounded line, run the same way, does not end cleanly.
rc, out, err, timed_out = run("set -euo pipefail\n" + UNBOUNDED, CONTROL_BOUND)
if not timed_out and not err.strip():
    print("FAIL: the control, the unbounded generator run with SIGPIPE ignored, ended within")
    print(f"      {CONTROL_BOUND} s and wrote nothing to stderr (exit {rc}), so this harness is not")
    print("      reproducing the fault and measured NOTHING about the generators.")
    sys.exit(1)
control = f"did not end within {CONTROL_BOUND} s" if timed_out else f"wrote to stderr: {err.strip().splitlines()[0]}"

# C. Every gen() defined in those files, run for every N install.sh asks for.
def lift_gen(f, lines):
    """Each gen() definition: a one-liner, or the lines up to its closing brace."""
    found = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)gen\(\)\s*\{", line)
        if not m:
            continue
        if re.search(r"\}\s*$", line[m.end():]):
            found.append((i + 1, line.strip()))
            continue
        indent = m.group(1)
        for j in range(i + 1, len(lines)):
            if re.match(r"^" + re.escape(indent) + r"\}\s*$", lines[j]):
                found.append((i + 1, "\n".join(l[len(indent):] for l in lines[i : j + 1])))
                break
        else:
            problems.append(f"{f}:{i + 1}: a gen() with no closing brace at its own indent, so it cannot be lifted")
    return found

gens = []
for f, lines in texts.items():
    for n, body in lift_gen(f, lines):
        gens.append((f, n, body))

if not any(f == "install.sh" for f, _, _ in gens):
    print("FAIL: install.sh defines no gen(), so this gate measured NOTHING: there is no")
    print("      secret generator to run.")
    sys.exit(1)

lengths = sorted({int(n) for n in re.findall(r"\$\(gen ([0-9]+)\)", "\n".join(texts["install.sh"]))})
if not lengths:
    print("FAIL: install.sh never asks gen for a secret of a given length (no \"$(gen N)\"),")
    print("      so this gate measured NOTHING: there is no length to run the generator for.")
    sys.exit(1)

runs = 0
for f, n, body in gens:
    where = f"{f}:{n}"
    seen = {}
    stop = False
    for length in lengths:
        for k in range(RUNS):
            script = (
                "set -euo pipefail\n"
                "die() { printf 'die: %s\\n' \"$*\" >&2; exit 1; }\n"
                + body + "\n"
                + f"gen {length}\n"
            )
            rc, out, err, timed_out = run(script, BOUND)
            runs += 1
            if timed_out:
                problems.append(f"{where}: gen {length} did not end within {BOUND} s with SIGPIPE ignored")
                stop = True
                break
            if rc != 0:
                problems.append(f"{where}: gen {length} exited {rc} with SIGPIPE ignored: {err.strip()[:200]}")
                stop = True
                break
            if err.strip():
                problems.append(f"{where}: gen {length} wrote to stderr with SIGPIPE ignored: {err.strip()[:200]}")
                stop = True
                break
            if not re.fullmatch(r"[A-Za-z0-9]{%d}" % length, out):
                problems.append(
                    f"{where}: gen {length} printed {len(out)} character(s) that are not exactly {length} of A-Za-z0-9: {out[:80]!r}"
                )
                stop = True
                break
            if out in seen:
                problems.append(f"{where}: gen {length} printed the same value twice, which is not a secret")
                stop = True
                break
            seen[out] = True
        if stop:
            break

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 31.")
    sys.exit(1)

names = ", ".join(f"{f}:{n}" for f, n, _ in gens)
print(f"OK: {reads} read(s) of /dev/urandom, each bounded by head -c; {len(gens)} generator(s) ({names})")
print(f"    run {runs} times with SIGPIPE ignored for N in {lengths}, each ended at once with N fresh")
print(f"    characters; the unbounded control {control}.")
PY
