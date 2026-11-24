#!/usr/bin/env bash
# CLAUDE.md invariant 82: the console's revoke button is wired, with a key of its own that only the console
# holds, as a file, and vouchryx accepts it beside the operator's.
#
# WHY
#
# vouchryx serves POST /v1/revoke with a bearer key, and the console has a `delegation_revoke` command (admin
# only, passkey-gated) that posts there, reading GENARYX_VOUCHRYX_URL and GENARYX_VOUCHRYX_REVOKE_KEY_FILE. This
# launcher set neither, so cutting an agent off meant a curl from a container with the operator's key; stack-k8s
# and stack-up wire the button. The console refuses to start with one of the two set and not the other.
#
# WHAT THIS CHECKS
#
#   A. the resolved configuration (docker compose config, every profile on, a fake .env with both keys):
#      the console names vouchryx's URL on its port and the key FILE, mounts ./console-revoke read only at that
#      file's directory, and no other service mounts ./console-revoke; vouchryx's VOUCHRYX_REVOKE_KEYS is the
#      operator's key and the console's, two entries, and with CONSOLE_REVOKE_KEY empty it is the operator's
#      alone; the console and vouchryx share a network;
#   B. the `# console-revoke-key:` block, lifted out of install.sh and run in a scratch STACK_DIR with chown and
#      chmod recorded: the file holds .env's value with no newline, mode 0400, owner 10001, directory
#      0:10001 0710 whatever the umask; a second run keeps the file; a changed .env value replaces it; an empty
#      value refuses; nothing is printed that holds the key; a link at the key's name is replaced, never followed;
#   C. install.sh mints CONSOLE_REVOKE_KEY with gen, calls the block before the stack starts, and checks the
#      console's key with vouchryx (400, nothing revoked) and a key vouchryx does not hold (401).
#
# It refuses to report OK when it measured nothing: no console, no vouchryx, no block, no Docker.
#
# Scenarios: features/the-console-can-revoke-a-delegation.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "console-revoke".
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "console-revoke: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/console-revoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []
def bad(m): problems.append(m)
def stop(m):
    print("FAIL console-revoke: " + m); sys.exit(1)

text = open("compose.yaml").read()
install = open("install.sh").read()
required = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", text)))
clean = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}

def resolve(extra):
    envfile = os.path.join(work, "env-%d" % len(extra))
    with open(envfile, "w") as f:
        for n in required:
            f.write("%s=placeholder\n" % n)
        for k, v in extra.items():
            f.write("%s=%s\n" % (k, v))
    r = subprocess.run(["docker", "compose", "--project-directory", root, "--env-file", envfile, "-f",
                        os.path.join(root, "compose.yaml"), "--profile", "*", "config", "--format", "json"],
                       capture_output=True, text=True, env=clean, cwd=root)
    if r.returncode != 0:
        stop("docker compose config failed: %s" % ((r.stderr.strip().splitlines() or ["?"])[-1]))
    return json.loads(r.stdout).get("services", {})

svc = resolve({"VOUCHRYX_REVOKE_KEYS": "operatorkey", "CONSOLE_REVOKE_KEY": "consolekey"})
for need in ("console", "vouchryx"):
    if need not in svc:
        stop("no %s service in the resolved configuration; measured nothing" % need)

# ---- A ----------------------------------------------------------------------------------
cenv = svc["console"].get("environment") or {}
url = cenv.get("GENARYX_VOUCHRYX_URL")
kf = cenv.get("GENARYX_VOUCHRYX_REVOKE_KEY_FILE")
if url != "http://vouchryx:4310":
    bad("the console's GENARYX_VOUCHRYX_URL is %r, not vouchryx on its port (http://vouchryx:4310)" % url)
if not kf:
    bad("the console has no GENARYX_VOUCHRYX_REVOKE_KEY_FILE, so its revoke button has no key")
def binds(s):
    return [v for v in (svc[s].get("volumes") or []) if v.get("type") == "bind"]
mine = [v for v in binds("console") if os.path.basename(str(v.get("source", "")).rstrip("/")) == "console-revoke"]
if not mine:
    bad("the console does not mount ./console-revoke, so the key file it is told to read is not there")
else:
    m = mine[0]
    if not m.get("read_only"):
        bad("the console mounts ./console-revoke read-write; it reads its key and must not be able to change it")
    if kf and os.path.dirname(kf) != str(m.get("target", "")).rstrip("/"):
        bad("the key file %r is not inside the mount %r" % (kf, m.get("target")))
for s in svc:
    if s == "console":
        continue
    if any(os.path.basename(str(v.get("source", "")).rstrip("/")) == "console-revoke" for v in binds(s)):
        bad("%s mounts ./console-revoke, which holds the console's revoke key and is the console's alone" % s)
keys = str((svc["vouchryx"].get("environment") or {}).get("VOUCHRYX_REVOKE_KEYS", ""))
if keys.split(",") != ["operatorkey", "consolekey"]:
    bad("vouchryx's VOUCHRYX_REVOKE_KEYS resolves to %r, not the operator's key and the console's" % keys)
svc0 = resolve({"VOUCHRYX_REVOKE_KEYS": "operatorkey", "CONSOLE_REVOKE_KEY": ""})
keys0 = str((svc0["vouchryx"].get("environment") or {}).get("VOUCHRYX_REVOKE_KEYS", ""))
if keys0 != "operatorkey":
    bad("with no CONSOLE_REVOKE_KEY, VOUCHRYX_REVOKE_KEYS resolves to %r, not the operator's key alone" % keys0)
def nets(s):
    n = svc[s].get("networks") or {}
    return set(n if isinstance(n, (dict, list)) else [])
if not (nets("console") & nets("vouchryx")):
    bad("the console and vouchryx share no network, so the button cannot reach vouchryx")

# ---- B ----------------------------------------------------------------------------------
m = re.search(r"^# console-revoke-key: begin\n(.*?)^# console-revoke-key: end\n", install, re.M | re.S)
block = m.group(1) if m else ""
if not m or "console_revoke_key_prepare()" not in block:
    bad("install.sh has no '# console-revoke-key:' block defining console_revoke_key_prepare(); measured nothing about the key file")
if block:
    shims = os.path.join(work, "shims")
    os.makedirs(shims, exist_ok=True)
    log = os.path.join(work, "calls.log")
    for tool in ("chown", "chmod"):
        real = subprocess.run(["sh", "-c", "command -v " + tool], capture_output=True, text=True).stdout.strip()
        with open(os.path.join(shims, tool), "w") as f:
            if tool == "chown":
                f.write('#!/bin/sh\necho "chown $*" >>"%s"\nexit 0\n' % log)
            else:
                f.write('#!/bin/sh\necho "chmod $*" >>"%s"\nexec %s "$@"\n' % (log, real))
        os.chmod(os.path.join(shims, tool), 0o755)

    def run(case, envval, umask="022", pre=None):
        d = os.path.join(work, case)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, ".env"), "w") as f:
            f.write("CONSOLE_REVOKE_KEY=%s\n" % envval)
        if pre:
            pre(d)
        open(log, "w").close()
        script = ('note() { printf "   %s\\n" "$*"; }; die() { printf "!! %s\\n" "$*" >&2; exit 1; }\n'
                  'typed_env_get() { local v; v="$(sed -n "/^$1=/{s///p;q;}" "$STACK_DIR/.env")"; printf "%s" "$v"; }\n'
                  + block + "\numask " + umask + "\nconsole_revoke_key_prepare\n")
        r = subprocess.run(["bash", "-c", script], env=dict(os.environ, STACK_DIR=d, PATH=shims + ":" + os.environ["PATH"]),
                           capture_output=True, text=True)
        return d, r, open(log).read()

    SECRET = "cOnSoLeReVoKeKeY0123456789abcdefABCDEF12"
    d, r, calls = run("fresh", SECRET, umask="077")
    key = os.path.join(d, "console-revoke", "revoke.key")
    if r.returncode != 0:
        bad("a fresh run refused: %s" % (r.stdout + r.stderr).strip()[-200:])
    else:
        if open(key).read() != SECRET:
            bad("the key file does not hold .env's value exactly (no newline, nothing else)")
        if oct(os.stat(key).st_mode & 0o777) != "0o400":
            bad("the key file is mode %s, not 0400" % oct(os.stat(key).st_mode & 0o777))
        if "chown -h 10001:10001 %s" % key not in calls and "chown 10001:10001 %s" % key not in calls:
            bad("the key file is not given to the console's uid 10001")
        if "chown 0:10001 %s" % os.path.join(d, "console-revoke") not in calls:
            bad("the key's directory is not given to root with the console's group (0:10001)")
        if oct(os.stat(os.path.join(d, "console-revoke")).st_mode & 0o777) != "0o710":
            bad("under umask 077 the key's directory is %s, not 0710" % oct(os.stat(os.path.join(d, "console-revoke")).st_mode & 0o777))
        if SECRET in r.stdout + r.stderr:
            bad("the run printed the console's revoke key")
    d2, r2, _ = run("fresh", SECRET)
    if "kept" not in r2.stdout:
        bad("a second run with the same .env did not keep the key file")
    d3, r3, _ = run("fresh", SECRET + "X")
    if r3.returncode != 0 or open(key).read() != SECRET + "X":
        bad("a changed .env value did not replace the key file")
    d4, r4, _ = run("empty", "")
    if r4.returncode == 0:
        bad("an empty CONSOLE_REVOKE_KEY did not refuse")
    def plant(dd):
        os.makedirs(os.path.join(dd, "console-revoke"), exist_ok=True)
        open(os.path.join(dd, "elsewhere"), "w").write("do-not-touch")
        os.symlink(os.path.join(dd, "elsewhere"), os.path.join(dd, "console-revoke", "revoke.key"))
    d5, r5, _ = run("link", SECRET, pre=plant)
    if open(os.path.join(d5, "elsewhere")).read() != "do-not-touch":
        bad("a link at the key's name was followed, and its target written")
    if os.path.islink(os.path.join(d5, "console-revoke", "revoke.key")):
        bad("a link at the key's name was left in place")

# ---- C ----------------------------------------------------------------------------------
if not re.search(r'^add_env_default CONSOLE_REVOKE_KEY "\$\(gen 40\)"$', install, re.M):
    bad("install.sh does not mint CONSOLE_REVOKE_KEY with gen 40")
call = [i for i, l in enumerate(install.splitlines()) if l.strip() == "console_revoke_key_prepare"]
up = [i for i, l in enumerate(install.splitlines()) if re.search(r'"\$\{COMPOSE\[@\]\}".* up -d', l)]
if not call:
    bad("install.sh never calls console_revoke_key_prepare")
elif up and call[0] > up[0]:
    bad("console_revoke_key_prepare runs after the stack starts, so the console starts with no key file and refuses")
if "vouchryx accepts the console's revoke key (nothing revoked)" not in install:
    bad("install.sh does not check that vouchryx accepts the console's key")
if not re.search(r'console_revoke_status not-a-revoke-key[^\n]*= 401', install):
    bad("install.sh does not check that vouchryx refuses a key it does not hold")

if problems:
    for p in problems:
        print("FAIL console-revoke: " + p)
    sys.exit(1)
print("OK: console-revoke (invariant 82): the console names vouchryx and a key file only it mounts, vouchryx takes the "
      "console's key beside the operator's, and install.sh writes the file 0400 for uid 10001 and checks it both ways")
PY
