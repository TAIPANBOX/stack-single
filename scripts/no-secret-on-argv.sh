#!/usr/bin/env bash
#
# Enforces invariant 46 of CLAUDE.md: no credential reaches a process's argument
# list in what the installer runs. Not a bearer key or a client key on a docker
# run, wget or curl command line, not a token in a git URL, not a secret expanded
# into a compose command, healthcheck or flag.
#
# WHY
#
# An argument list is not private. Every local user reads it with ps, the
# command line of a container is kept in docker inspect for as long as the
# container exists, and busybox's wget or nc puts its own argv in /proc. The
# installer ran `docker run ... wget --header="Authorization: Bearer <admin key>"`
# for every check of a key, so the admin key of the policy plane sat in the
# argument list of the host's docker client for the length of that check, and
# the console's clone URL carried its token into git's argv and, when git writes
# the remote, into the clone's .git/config. The request now travels on stdin, and
# a token travels in the environment of the one command that reads it.
#
# WHAT IT JUDGES, AND HOW
#
#   1. Static, over install.sh, compose.yaml and scripts/*.sh (not this gate and
#      not the teeth harness, whose mutations are text): no credential in a URL,
#      no --header or -H on a line (the request helper writes headers to stdin),
#      no secret expansion on a line that runs an argument-carrying program
#      (docker, wget, curl, git, nc, ssh, ...), except inside single quotes or as
#      a NAME="$VALUE" prefix that exports it to one command, and no secret in a
#      compose command, entrypoint, healthcheck test or flag.
#   2. Behavioural, over the request helper lifted out of install.sh between its
#      markers and run against a stub docker: the key must reach the container on
#      stdin and in no argument.
#   3. Behavioural, over the console clone command lifted out of install.sh and
#      run against a stub git: the token must be in the environment of git and in
#      no argument, the credential helper must hand git the token, and the clone
#      URL must carry no credential, so git cannot write one into .git/config.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No install.sh, no request-helper block, no credential-helper clone line, or no
# subject to scan is reported and fails. A gate that found nothing to judge must
# not say the tree is clean.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
exec python3 - <<'PY'
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

FAKE = "NOSECRET-FAKE-7f3a9c"
# A non-ASCII body: Content-Length must be its BYTE count (e-acute is two bytes). Written
# as an escape so this file stays ASCII.
MBODY = "caf\u00e9 {\"a\":1}"
problems = []

def fail(msg):
    problems.append(msg)

# ---- static half -----------------------------------------------------------

SECRET_EXPANSION = re.compile(
    r"\$\{?(?:[A-Za-z0-9_]*_)?(?:KEYS?|SECRETS?|TOKENS?|PASSWORD|PASS|ADMIN|BEARER|CREDENTIALS?"
    r"|WARDRYX_GATEWAY|WARDRYX_ADMIN|GATEWAY_ADMIN|CLOUD_ADMIN)\}?(?![A-Za-z0-9_])"
)
ARG_PROGRAM = re.compile(r"\b(docker|wget|curl|git|nc|ssh|scp|rsync|openssl|psql|mysql)\b")
URL_CREDENTIAL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s/'\"@]*:[^\s/'\"@]*@")
HEADER_FLAG = re.compile(r"--header\b|(?:^|\s)-H(?:\s|=|['\"])")
COMPOSE_EXEC_KEY = re.compile(r"\b(command|entrypoint|test|args)\s*:")
SECRET_FLAG = re.compile(r"--(password|token|secret|api-key|admin|key)[=\s]\S*\$")

def live_text(line):
    # Single-quoted text is never expanded by the outer shell, and NAME="$VALUE"
    # before a command exports VALUE to that one command. Neither puts a value on
    # an argument list, so neither counts.
    t = re.sub(r"'[^']*'", "''", line)
    t = re.sub(r'\b[A-Za-z_][A-Za-z0-9_]*="\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"(?=\s)', "", t)
    return t

def statics(name, text, compose=False):
    if not text.strip():
        fail(f"{name}: is empty, so this gate measured NOTHING in it")
        return 0
    judged = 0
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        judged += 1
        where = f"{name}:{n}"
        # A credential in a URL is judged on a command line only. The DSN that
        # install.sh writes into .env is an environment value, not an argument, and
        # the fixtures that test refusals in scripts/ carry fake credentials on
        # purpose; both are outside this rule.
        if not compose and name == "install.sh" and URL_CREDENTIAL.search(line) and ARG_PROGRAM.search(live_text(line)):
            fail(f"{where}: a URL carries a credential on a command line, so it is on an argument list and in .git/config")
        if HEADER_FLAG.search(line) and not compose:
            fail(f"{where}: a --header or -H flag on a command line; headers go on stdin through the request helper")
        if not compose and ARG_PROGRAM.search(live_text(line)) and SECRET_EXPANSION.search(live_text(line)):
            fail(f"{where}: a secret is expanded on a line that runs an argument-carrying program")
        if compose and (COMPOSE_EXEC_KEY.search(line) or SECRET_FLAG.search(line)) and SECRET_EXPANSION.search(line):
            fail(f"{where}: a secret is expanded into a compose command, entrypoint, healthcheck or flag")
        if compose and SECRET_FLAG.search(line):
            fail(f"{where}: a secret-named flag is given a value on the command line")
    return judged

try:
    install = open("install.sh").read()
except OSError:
    install = ""
    fail("install.sh is not there, so this gate measured NOTHING")

subjects = {"install.sh": install}
for path in sorted(glob.glob("scripts/*.sh")):
    base = os.path.basename(path)
    if base in ("gates-have-teeth.sh", "no-secret-on-argv.sh"):
        continue
    subjects[path] = open(path).read()
compose_text = open("compose.yaml").read() if os.path.exists("compose.yaml") else ""
if not compose_text:
    fail("compose.yaml is not there, so this gate measured NOTHING in it")

judged = 0
for name, text in subjects.items():
    judged += statics(name, text)
judged += statics("compose.yaml", compose_text, compose=True)
if judged == 0:
    fail("no non-comment line in any subject, so this gate measured NOTHING")

# ---- behavioural: the request helper ----------------------------------------

BEGIN_HTTP, END_HTTP = "# argv-free-http: begin", "# argv-free-http: end"
STUB_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["NOSECRET_STUB_DIR"]
open(os.path.join(d, "docker.argv"), "a").write(json.dumps(sys.argv[1:]) + "\n")
data = sys.stdin.buffer.read()
open(os.path.join(d, "docker.stdin"), "ab").write(data)
sys.stdout.write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
'''

def utf8_locale():
    """A UTF-8 locale that is installed here, or None. Under one, bash counts characters, not bytes."""
    try:
        names = subprocess.run(["locale", "-a"], capture_output=True, text=True, timeout=10).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        names = []
    for cand in ("C.UTF-8", "C.utf8", "en_US.UTF-8", "en_US.utf8"):
        if cand in names:
            return cand
    return None

def run_with_stub(stub_name, stub_src, script, extra_env, scratch):
    stubdir = os.path.join(scratch, "bin")
    os.makedirs(stubdir, exist_ok=True)
    stub = os.path.join(stubdir, stub_name)
    with open(stub, "w") as f:
        f.write(stub_src)
    os.chmod(stub, 0o755)
    env = dict(os.environ)
    env["PATH"] = stubdir + os.pathsep + env.get("PATH", "")
    env["NOSECRET_STUB_DIR"] = scratch
    env.update(extra_env)
    return subprocess.run(["bash", "-c", script], env=env, cwd=scratch,
                          capture_output=True, text=True, timeout=60)

def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""

LOC = utf8_locale()
if LOC is None:
    fail("no UTF-8 locale (C.UTF-8 or en_US.UTF-8) is installed, so the byte count of a non-ASCII body was not measured")
start = install.find(BEGIN_HTTP)
end = install.find(END_HTTP)
if start < 0 or end < 0 or end < start:
    fail(f"install.sh has no '{BEGIN_HTTP}' ... '{END_HTTP}' request-helper block, so no argument-free request was measured")
else:
    block = install[start:end]
    scratch = tempfile.mkdtemp(prefix="no-secret-on-argv.")
    try:
        script = (
            'NET=agent-stack_core\n' + block + '\n'
            'code http://wardryx:8090/v1/policies "$FAKE"\n'
            'http_request POST http://tokenfuse-gateway:4100/v1/runs '
            '"Content-Type: application/json"$\'\\r\\n\'"x-fuse-key: $FAKE"$\'\\r\\n\' \'{"a":1}\'\n'
            'http_request POST http://tokenfuse-gateway:4100/v1/runs "Content-Type: application/json"$\'\\r\\n\' "$MBODY"\n'
        )
        env_req = {"FAKE": FAKE, "MBODY": MBODY}
        if LOC is not None:
            env_req.update(LC_ALL=LOC, LANG=LOC)
        r = run_with_stub("docker", STUB_DOCKER, script, env_req, scratch)
        argv = read(os.path.join(scratch, "docker.argv"))
        stdin = read(os.path.join(scratch, "docker.stdin"))
        if r.returncode != 0:
            fail(f"the request helper did not run under the stub (exit {r.returncode}): {r.stderr.strip()[:200]}")
        if FAKE in argv:
            fail("the request helper puts a key on the docker argument list")
        if f"Authorization: Bearer {FAKE}" not in stdin:
            fail("the request helper does not send the bearer key on stdin")
        if f"x-fuse-key: {FAKE}" not in stdin:
            fail("the request helper does not send the client key on stdin")
        if "Content-Length: 7" not in stdin:
            fail("the request helper sends no Content-Length for a body")
        if f"Content-Length: {len(MBODY.encode('utf-8'))}\r\n" not in stdin:
            fail("the request helper sends a Content-Length in characters, not bytes, so a non-ASCII body is cut short")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

# ---- behavioural: the console clone ------------------------------------------

lines = install.split("\n")
clone_idx = next((i for i, l in enumerate(lines) if "git -c credential.helper=" in l), None)
if clone_idx is None:
    fail("install.sh has no `git -c credential.helper=` clone line, so the console's token was not measured")
else:
    stmt = []
    j = clone_idx
    while j < len(lines) and j - clone_idx < 6:
        l = lines[j].rstrip()
        stmt.append(l[:-1] if l.endswith("\\") else l)
        if not l.endswith("\\"):
            break
        j += 1
    text = " ".join(stmt)
    text = re.split(r"\s\|\|\s", text, maxsplit=1)[0].strip()
    if URL_CREDENTIAL.search(text):
        fail("the console clone command carries a credential in its URL")
    scratch = tempfile.mkdtemp(prefix="no-secret-on-argv.")
    try:
        stub_git = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["NOSECRET_STUB_DIR"]
args = sys.argv[1:]
open(os.path.join(d, "git.argv"), "a").write(json.dumps(args) + "\n")
open(os.path.join(d, "git.env"), "w").write(os.environ.get("CONSOLE_TOKEN", "UNSET"))
for a in args:
    if a.startswith("credential.helper=!"):
        out = subprocess.run(["sh", "-c", a[len("credential.helper=!"):], "get"],
                             input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True, env=os.environ)
        open(os.path.join(d, "git.helper"), "w").write(out.stdout)
'''
        script = text + "\n"
        r = run_with_stub("git", stub_git, script, {"CONSOLE_TOKEN": FAKE}, scratch)
        argv = read(os.path.join(scratch, "git.argv"))
        helper = read(os.path.join(scratch, "git.helper"))
        if r.returncode != 0 and not os.path.exists(os.path.join(scratch, "git.argv")):
            fail(f"the console clone line did not run under the stub (exit {r.returncode}): {r.stderr.strip()[:200]}")
        if FAKE in argv:
            fail("the console clone puts the token on git's argument list")
        calls = [json.loads(x) for x in argv.splitlines() if x.strip()]
        if calls:
            a = calls[0]
            helper_at = next((i for i, x in enumerate(a) if x.startswith("credential.helper=!")), None)
            reset_at = a.index("credential.helper=") if "credential.helper=" in a else None
            if helper_at is None or reset_at is None or reset_at > helper_at:
                fail("the console clone does not reset the credential helper list first, so a helper the system already has would be handed the token")
        if "username=x-access-token" not in helper or f"password={FAKE}" not in helper:
            fail("the credential helper does not hand git the token from its environment")
        if read(os.path.join(scratch, "git.env")) != FAKE:
            fail("the console clone does not pass the token to git in its environment")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

if problems:
    print("FAIL: a credential reaches an argument list, or this gate measured nothing:")
    for p in problems:
        print("  - " + p)
    sys.exit(1)

print(f"OK: no credential on an argument list in {judged} judged line(s) of {len(subjects) + 1} subject(s); "
      "the request helper sends its keys on stdin, the console token reaches git from its environment.")
PY
