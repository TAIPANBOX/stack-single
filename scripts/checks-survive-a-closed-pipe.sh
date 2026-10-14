#!/usr/bin/env bash
#
# Enforces invariant 30 of CLAUDE.md: an install reports a healthy box as
# healthy and never reports a refused condition as fine, whatever order a
# producer and its reader happen to finish in.
#
# WHAT THIS IS ABOUT
#
# install.sh runs with `set -o pipefail`, and several of its verification checks
# read a container's log through a pipe: `docker compose logs <service> 2>&1 |
# grep -q <line>`. `grep -q` exits at its first match; `docker compose logs` is
# still writing, hits the closed pipe and exits 255; and pipefail makes the
# pipeline fail although the line WAS in the log. Measured 2026-10-13 on Debian 13
# (Docker 26.1.5, Compose 2.26.1): `set -o pipefail; docker compose logs
# tokenfuse-gateway 2>&1 | grep -qF 'client auth: ON (3 key(s))'`, five times,
# returned 0 255 255 0 255; the same without -q, where grep reads everything, 0
# five times. Two installs on that box reported `FAIL client keys: the gateway
# holds 3` and `FAIL identity map: the gateway reads it` on a healthy gateway,
# while CI on GitHub's runners happened to pass: the outcome depends on which of
# two processes finishes first.
#
# The same race has a worse face. A check written the negative way, `! docker
# compose logs <service> | grep -qE '<a bad line>'`, reads ok when the 255 fails
# the pipeline and `!` turns it into a pass: the install says "every key is bound"
# while the log says one is not. A healthy box reported as broken costs an
# operator an hour; a refused condition reported as fine costs them the thing the
# check exists for.
#
# WHAT THIS CHECKS
#
#   A. THE HELPERS, run. The `# check-helpers:` block (check and check_log) and
#      the `# compose-has:` block are lifted out of install.sh and run under the
#      same `set -euo pipefail` the installer has, against a STUB `docker` on PATH.
#      The stub needs no Docker: it prints a log whose first lines are the ones the
#      check looks for, then four megabytes of filler (far more than a pipe holds,
#      so it cannot finish writing until its reader has gone), and, like compose,
#      exits 255 when its reader closes the pipe. Deterministic: grep -q exits on
#      the first line it is given, and the stub is by then still writing.
#   B. THE CONTROL. Before any verdict is trusted, the stub is shown to reproduce
#      the fault: the unwrapped pipeline under pipefail returns 255 every time, and
#      without pipefail 0. A stub that did not break the pipe would pass any helper.
#   C. THE REAL CHECKS. Every check or check_log in install.sh that reads a log, or
#      the list of running services, through a pipe is extracted as written and run
#      through those helpers in six situations: a healthy box; logs that are silent
#      while the service runs; nothing running; logs that cannot be read; a log
#      holding a line the install must refuse (each of two); and the negative and
#      mixed checks must FAIL on those while every positive one stays ok. A
#      positive check must be ok on a log that holds its line and FAIL on one that
#      does not (a "fix" that made every check ok would otherwise pass A and B).
#      Subjects are derived: a log check install.sh grows without a case here, or a
#      case whose check has gone, is reported.
#   D. THE LIST OF SERVICES. compose_has finds a name that is first in a long list
#      and refuses one that is not there, an unreadable list and a name that is only
#      part of another.
#   E. NO OTHER EARLY-EXIT READER. Outside a check's command string (the helpers
#      cover those), no line of install.sh pipes `compose logs` or `compose ps` into
#      `grep -q`, `grep -m` or `head`: the same race, in the main body, where it
#      would silently skip a group of checks.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No helper block, no compose-has block, no log check to run, or a stub that did
# not break the pipe: each is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

lines = open("install.sh").read().split("\n")
problems = []


def fail(msg):
    problems.append(msg)
    print("FAIL: " + msg)


def lift(begin, end):
    out, inside = [], False
    for ln in lines:
        if ln == begin:
            inside = True
            continue
        if ln == end:
            inside = False
            continue
        if inside:
            out.append(ln)
    return "\n".join(out)


helpers = lift("# check-helpers: begin", "# check-helpers: end")
compose_has = lift("# compose-has: begin", "# compose-has: end")
stop = False
if not helpers.strip():
    fail("install.sh has no '# check-helpers: begin' .. 'end' block, so the helpers every verification check runs through cannot be run on their own and this gate measured nothing")
    stop = True
elif not (re.search(r"^check\(\)", helpers, re.M) and re.search(r"^check_log\(\)", helpers, re.M)):
    fail("the check-helpers block defines no check() or check_log(), so this gate measured nothing")
    stop = True
if not compose_has.strip():
    fail("install.sh has no '# compose-has: begin' .. 'end' block, so the way the installer asks whether a service exists cannot be run on its own and this gate measured nothing")
    stop = True
elif not re.search(r"^compose_has\(\)", compose_has, re.M):
    fail("the compose-has block defines no compose_has(), so this gate measured nothing")
    stop = True

# ---- logical statements: a backslash at the end of a line continues it -----------
logical = []
cur, start = None, 0
for i, ln in enumerate(lines):
    if cur is None:
        cur, start = ln, i + 1
    else:
        cur = cur + " " + ln.strip()
    if cur.rstrip().endswith("\\"):
        cur = cur.rstrip()[:-1].rstrip()
        continue
    logical.append((start, cur))
    cur = None

stmt_re = re.compile(r'^\s*(check_log|check)\s+"((?:[^"\\]|\\.)*)"\s+"')
statements = {}   # name -> (line, text)
for n, text in logical:
    if text.lstrip().startswith("#"):
        continue
    m = stmt_re.match(text)
    if not m:
        continue
    # A check that asks compose for a log, or for the list of running services,
    # through a pipe: the shape this gate is about.
    if re.search(r"\blogs\s", text) or re.search(r"--services\s*\|", text):
        statements[m.group(2)] = (n, text)

# ---- what each real check must say in each situation ---------------------------------
# 1 healthy, 2 service up but its log silent, 3 nothing running, 4 logs unreadable,
# 5 a refused line in the gateway's log and the console's, 6 a refused line in the
# gateway's log only.
POS = {1: "ok", 2: "FAIL", 3: "FAIL", 4: "FAIL", 5: "ok", 6: "ok"}
CASES = {
    "gateway exports agent events": POS,
    "gateway clamps a run budget to a ceiling": POS,
    "client keys: the gateway holds $IDENTITY_KEYS_COUNT": POS,
    "identity map: the gateway reads it": POS,
    # Negative: only what it is for. On a silent or unreadable log it reads ok, which is
    # why install.sh pairs it with the positive check on the same log.
    "identity map: every key is bound and every binding has a key": {1: "ok", 5: "FAIL", 6: "FAIL"},
    "chain verifier is running and has read the bus": POS,
    # Mixed: the line it wants AND not the line it refuses, in the console's log.
    "console's bus is live": {1: "ok", 2: "FAIL", 3: "FAIL", 4: "FAIL", 5: "FAIL", 6: "ok"},
    # Reads the list of running services only.
    "typed plane: typryx is running on its $TYPED_PLANE backend": {1: "ok", 2: "ok", 3: "FAIL", 4: "FAIL", 5: "ok", 6: "ok"},
    # The OpenAI door's log (CLAUDE.md invariant 32): the gateway's questions, asked
    # of the second gateway. Its log carries what the gateway's does in each
    # situation, plus the line that names the wire it serves.
    "openai door serves the OpenAI wire": POS,
    "openai door exports agent events": POS,
    "openai door clamps a run budget to a ceiling": POS,
    "openai door: client keys: the door holds ${IDENTITY_openai_KEYS_COUNT:-0}": POS,
    "openai door: identity map: the door reads it": POS,
    "openai door: every key is bound and every binding has a key": {1: "ok", 5: "FAIL", 6: "FAIL"},
}
SCENARIO = {
    1: "a healthy box",
    2: "the service is up and its log says nothing",
    3: "nothing is running",
    4: "the logs cannot be read",
    5: "the logs hold a line the install must refuse",
    6: "the gateway's log holds a line the install must refuse",
}

if not statements:
    fail("install.sh has no check or check_log that reads a log or the list of running services through a pipe, so this gate measured nothing")
    stop = True
for name in sorted(statements):
    if name not in CASES:
        fail(f"install.sh:{statements[name][0]} check {name!r} reads a log or the service list through a pipe and has no case in this gate: add what it must say in each of the six situations")
for name in sorted(CASES):
    if name not in statements:
        fail(f"this gate has a case for a check named {name!r} and install.sh has no check named that any more (renamed or removed): the case judges nothing")

# ---- the stub docker ---------------------------------------------------------------
STUB = """#!/bin/sh
# Stands in for docker, for scripts/checks-survive-a-closed-pipe.sh only. It writes a
# log the way compose does, line by line to a pipe, and exits 255 when its reader goes
# away (SIGPIPE ignored, so the write fails and the exit status is the error).
trap '' PIPE
printf '%s\\n' "$*" >>"$STUB_DIR/calls"
[ "$1" = compose ] || { echo "stub docker: unexpected command: $*" >&2; exit 97; }
shift
sub="$1"
shift
case "$sub" in
  logs)
    svc=""
    for a in "$@"; do svc="$a"; done
    [ -f "$STUB_DIR/logs/$svc" ] || exit 1
    cat "$STUB_DIR/logs/$svc" || exit 255
    cat "$STUB_FILLER" || exit 255
    ;;
  ps)
    [ -f "$STUB_DIR/ps" ] || exit 1
    cat "$STUB_DIR/ps" || exit 255
    cat "$STUB_FILLER" || exit 255
    ;;
  *)
    echo "stub docker: unexpected subcommand: $sub" >&2
    exit 97
    ;;
esac
"""

STAMP = "2026-10-13T09:00:0"
GW_GOOD = [
    STAMP + "1Z tokenfuse gateway listening on 0.0.0.0:4100",
    STAMP + "1Z NDJSON export enabled: /var/lib/stack/events/tokenfuse.ndjson",
    STAMP + "1Z run budget ceiling: a caller-declared or default budget is clamped to it (5.00 USD)",
    STAMP + "1Z client auth: ON (3 key(s))",
    STAMP + "1Z identity map: ON (2 unit(s), 3 key(s), 0 prefix(es))",
]
# The OpenAI door's start-up, as tokenfuse v1.13.1 prints it (the wire line carries
# tracing's colour codes on a box, which a `.*` between the two words reads past).
DOOR_GOOD = [
    STAMP + "1Z INFO tokenfuse: serving one door \x1b[3mwire\x1b[0m=OpenAi \x1b[3mpath\x1b[0m=/v1/chat/completions",
    STAMP + "1Z agent-event NDJSON export enabled (fresh prev_hash chain) path='/var/lib/stack/events/tokenfuse-openai.ndjson'",
    STAMP + "1Z run budget ceiling: a caller-declared or default budget is clamped to it (5.00 USD)",
    STAMP + "1Z client auth: ON (3 key(s))",
    STAMP + "1Z identity map: ON (1 unit(s), 3 key binding(s)); strict=Enforce",
]
GW_BAD_A = [STAMP + "2Z tokenfuse: client key `felyx` has no keys[] binding in the identity map"]
GW_BAD_B = [STAMP + "2Z tokenfuse: identity map key_id `ghost` has no matching TOKENFUSE_CLIENT_KEYS entry"]
CONN_GOOD = [STAMP + "3Z genaryx-web: bus LIVE (/var/lib/stack/events)"]
CONN_BAD = [STAMP + "3Z genaryx-web: bus startup failed: permission denied"]
AC_GOOD = [STAMP + "5Z PASS tokenfuse.ndjson (hash chain: 4 chained, 1 head(s))"]
SILENT = [STAMP + "9Z nothing of interest"]
RUNNING = ["agent-conform", "typryx", "console", "tokenfuse-gateway", "tokenfuse-gateway-openai"]


def logs_for(situation):
    """{service: lines} for a situation, or None when the logs cannot be read. A line the
    install must refuse comes FIRST, so grep -q on it exits while the stub is still writing."""
    if situation == 1:
        return {"tokenfuse-gateway": GW_GOOD, "tokenfuse-gateway-openai": DOOR_GOOD, "console": CONN_GOOD, "agent-conform": AC_GOOD}
    if situation in (2, 3):
        return {s: SILENT for s in ("tokenfuse-gateway", "tokenfuse-gateway-openai", "console", "agent-conform")}
    if situation == 4:
        return None
    if situation == 5:
        return {"tokenfuse-gateway": GW_BAD_A + GW_GOOD, "tokenfuse-gateway-openai": GW_BAD_A + DOOR_GOOD,
                "console": CONN_BAD + CONN_GOOD, "agent-conform": AC_GOOD}
    if situation == 6:
        return {"tokenfuse-gateway": GW_BAD_B + GW_GOOD, "tokenfuse-gateway-openai": GW_BAD_B + DOOR_GOOD,
                "console": CONN_GOOD, "agent-conform": AC_GOOD}


def ps_for(situation):
    if situation == 3:
        return ["unrelated-service"]
    if situation == 4:
        return None
    return RUNNING


FILLER = ""


def box(root, situation):
    d = tempfile.mkdtemp(dir=root)
    os.makedirs(os.path.join(d, "logs"))
    os.makedirs(os.path.join(d, "bin"))
    stub = os.path.join(d, "bin", "docker")
    open(stub, "w").write(STUB)
    os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
    open(os.path.join(d, "calls"), "w").close()
    logs = logs_for(situation)
    if logs is not None:
        for svc, content in logs.items():
            open(os.path.join(d, "logs", svc), "w").write("\n".join(content) + "\n")
    ps = ps_for(situation)
    if ps is not None:
        open(os.path.join(d, "ps"), "w").write("\n".join(ps) + "\n")
    return d


def run(root, situation, body):
    """Runs body under the installer's own shell options with the stub first on PATH."""
    d = box(root, situation)
    script = os.path.join(d, "run.sh")
    open(script, "w").write(
        "set -euo pipefail\n"
        "fail=0\n"
        "die() { printf 'die: %s\\n' \"$*\" >&2; exit 99; }\n"
        + helpers + "\n" + compose_has + "\n"
        "COMPOSE=(docker compose)\n"
        "DC=\"${COMPOSE[*]}\"\n"
        "IDENTITY_KEYS_COUNT=3\n"
        "IDENTITY_openai_KEYS_COUNT=3\n"
        "TYPED_PLANE=own-model\n"
        "sleep() { :; }\n"
        + body + "\n")
    r = subprocess.run(["bash", script], capture_output=True, text=True, timeout=120,
                       env={"PATH": os.path.join(d, "bin") + os.pathsep + os.environ.get("PATH", ""),
                            "STUB_DIR": d, "STUB_FILLER": FILLER, "HOME": d})
    calls = open(os.path.join(d, "calls")).read().strip().split("\n")
    return r, [c for c in calls if c]


if not stop:
    root = tempfile.mkdtemp()
    # Four megabytes, written once: a pipe holds 64 KiB at most, so a stub writing this
    # cannot finish before its reader has read it all or gone away.
    FILLER = os.path.join(root, "filler")
    open(FILLER, "w").write(("filler " + "x" * 72 + "\n") * 50000)

    # ---- B. the control: the stub really breaks the pipe -------------------------------
    pipeline = "docker compose logs tokenfuse-gateway 2>&1 | grep -qF 'client auth: ON (3 key(s))'"
    broken = []
    for _ in range(5):
        r, _calls = run(root, 1, "set +e\n(set -o pipefail; " + pipeline + "); echo \"on=$?\"\n(set +o pipefail; " + pipeline + "); echo \"off=$?\"")
        on = re.search(r"on=(\d+)", r.stdout)
        off = re.search(r"off=(\d+)", r.stdout)
        broken.append((on.group(1) if on else "?", off.group(1) if off else "?"))
    if any(on != "255" or off != "0" for on, off in broken):
        fail("the stub docker did not reproduce the broken pipe (pipefail on, then off, five times: "
             + ", ".join(f"{a}/{b}" for a, b in broken)
             + "; expected 255/0 every time), so a helper that passed here would prove nothing")

    # ---- C. the real checks, through the helpers ------------------------------------------
    ran = 0
    for name in sorted(n for n in CASES if n in statements):
        text = statements[name][1].strip()
        for situation, want in sorted(CASES[name].items()):
            r, calls = run(root, situation, text)
            ran += 1
            m = re.search(r"^   (ok|FAIL)  ", r.stdout, re.M)
            if not m:
                fail(f"{name!r} ({SCENARIO[situation]}): no verdict; exit {r.returncode}, stderr: {r.stderr.strip()[:200]}")
                continue
            got = m.group(1)
            if got == want:
                if got == "ok" and not any(c.startswith("compose logs") or c.startswith("compose ps") for c in calls):
                    fail(f"{name!r} ({SCENARIO[situation]}): reported ok without asking docker anything, so it proved nothing")
                continue
            if got == "FAIL":
                fail(f"{name!r} ({SCENARIO[situation]}): reported FAIL although its line is there. The producer's exit status after the reader left (compose exits 255 on a closed pipe) was counted against the box")
            else:
                why = {2: "the log holds nothing it looks for", 3: "nothing it looks for is running",
                       4: "the logs could not be read", 5: "the log holds the line the install must refuse",
                       6: "the log holds the line the install must refuse"}[situation]
                fail(f"{name!r} ({SCENARIO[situation]}): reported ok although {why}. A check that cannot fail reports silence as health")

    # ---- D. the list of services ------------------------------------------------------------
    for situation, probe, want in (
        (1, "console", True),              # first-but-two in a list that goes on for megabytes
        (1, "agent-conform", True),
        (1, "no-such-service", False),
        (1, "consol", False),              # -x: a part of a name is not the name
        (3, "console", False),             # nothing running
        (4, "console", False),             # the list cannot be read
    ):
        r, _calls = run(root, situation, f"compose_has {probe} && echo yes || echo no")
        got = r.stdout.strip().split("\n")[-1] if r.stdout.strip() else ""
        ran += 1
        if got != ("yes" if want else "no"):
            fail(f"compose_has {probe} said {got!r} when the list was read in situation {situation} ({SCENARIO[situation]}); it should say {'yes' if want else 'no'}")

    if ran == 0:
        fail("no check was run, so this gate measured nothing")

# ---- E. no other early-exit reader on compose's logs or service list ----------------------
reader = re.compile(r"\|\s*(?:grep\s+-[A-Za-z]*q[A-Za-z]*|grep\s+-m\s*\d+|head\b)")
checks_seen = 0
for n, text in logical:
    if text.lstrip().startswith("#"):
        continue
    if stmt_re.match(text):
        checks_seen += 1
        continue   # a check's command string runs through the helpers above
    for m in reader.finditer(text):
        left = re.split(r"&&|\|\||;|\$\(|\bthen\b", text[:m.start()])[-1]
        if re.search(r"(COMPOSE\[@\]|\bdocker\s+compose\b|\$DC\b).*\b(logs|ps)\b", left):
            fail(f"install.sh:{n} pipes `compose logs` or `compose ps` into an early-exit reader ({m.group(0).strip('| ')}) outside a check: the reader exits at its first match, compose exits non-zero on the closed pipe, and under pipefail the pipeline fails with the line there. Read the output to its end first (compose_has does)")
if checks_seen == 0:
    fail("install.sh has no check or check_log call at all, so this gate measured nothing")

if not stop:
    shutil.rmtree(root, ignore_errors=True)

if problems:
    print()
    print(f"{len(problems)} problem(s). A verification check has to say what the box is, not which of")
    print("two processes finished first. See CLAUDE.md invariant 30.")
    sys.exit(1)

print(f"OK: {len(statements)} log and service-list checks in install.sh, {ran} runs through the real helpers")
print("    against a stub docker that exits 255 when its reader leaves (shown to break the pipe):")
print("    a healthy box is ok, a silent, absent or unreadable one is FAIL, a refused line is never ok;")
print("    compose_has reads the whole list; and no other pipe into an early-exit reader is left.")
PY
