#!/usr/bin/env bash
# Enforces that every container of this stack carries the baseline, or names why not.
#
# WHY
#
# A service with a writable root, every capability and no process limit is one defect away
# from persisting itself, raising itself or taking the box down, and nothing about it shows
# in a run: it starts, it answers, every other check is green. Seven of twenty-eight services
# carried the first three lines before this gate, and none the last two, and each new
# service was another chance to forget. So the rule is the default, and an exception is a
# line somebody has to write, with a reason, and take out again.
#
# THE BASELINE
#
#   read_only: true, cap_drop: [ALL], security_opt: no-new-privileges:true, a pids_limit
#   that is a real limit, and ulimits: core: 0. A user that is not root. Every tmpfs sized.
#   Nobody runs with the syscall filter off: a service that needs more than Docker's default
#   names a profile file, and that file is Docker's default plus the rules named here.
#
# A PROFILE IS A FILE, AND COMPOSE DOES NOT READ IT WHEN IT COMPARES
#
# Compose hashes the line that names the file and never its contents, so a profile edited under
# the same name leaves a running service on the old filter with every check green. So a profile
# is pinned by digest to its versioned name, here, and a change is a new name in compose.yaml.
#
# HOW
#
# compose.yaml carries the baseline through a YAML anchor, so a line of the file says
# nothing about what a service gets. The gate reads the RESOLVED configuration, every
# profile on, from `docker compose config --format json`, on a stand-in .env, and finds its
# subjects there: a service nobody listed is held like the rest. hardening-exceptions.json
# names each exception: the service, the key, the value, why, and until when. Every field
# is required, the key comes from a closed list, and until is `permanent` or the name of
# what closes it. An exception that excuses nothing is a failure: whoever fixes a service
# has to take its exception out, and that is what keeps the file honest.
#
# A process limit has one ceiling here, because a limit above it limits nothing: the point
# is to stop a fork bomb, and the per-service values are measured, not derived.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No compose.yaml, no service, no Compose, or no exceptions file: each is reported as
# measuring nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "containers-carry-the-baseline: ...";
#  scenarios: features/every-container-carries-the-baseline.feature)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -s compose.yaml ]; then
	echo "FAIL: compose.yaml is not there or is empty, so the baseline measured NOTHING."
	exit 1
fi
if [ ! -f hardening-exceptions.json ]; then
	echo "FAIL: hardening-exceptions.json is not there, so the baseline measured NOTHING."
	exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
	echo "FAIL: there is no Docker Compose here to resolve compose.yaml, so the baseline measured NOTHING."
	exit 1
fi
python3 - <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

PIDS_CEILING = 2048
KEYS = {"baseline", "read_only", "cap_drop", "no_new_privileges", "pids", "core", "user", "cap_add", "seccomp", "apparmor"}
# What `baseline` excuses: a service that takes none of it yet.
BASELINE = {"read_only", "cap_drop", "no_new_privileges", "pids", "core"}
FORBIDDEN_SERVICE_KEYS = {"privileged": True, "pid": "host", "ipc": "host", "network_mode": "host"}
# The digest of each profile, written once. A published name never changes its bytes: a change
# is the next version, a new row here and a new line in compose.yaml.
PROFILES = {"./seccomp/chromium-v1.json": "744d959fbe18e8187de3be9152da259b2a553cdff01b6b969b4f96af2e5ce74e"}
# Docker's default profile as canonical JSON: moby's profiles/seccomp/default.json, the same
# bytes in 26.1.5 and 28.0.4, the two engines the supported hosts run.
DOCKER_DEFAULT = "885442dc08f21f8d60f99ea43d59af88b1c529103815fe24bbf9ce998d3a609d"
# What a profile may add to it, each with the mask it was measured under. clone may carry a
# user, pid and net namespace and no other; unshare a user namespace and nothing else.
ADDED = {
    "chroot": [],
    "clone": [{"index": 0, "value": 0x0E020000, "op": "SCMP_CMP_MASKED_EQ"}],
    "unshare": [{"index": 0, "value": 0xEFFFFFFF, "op": "SCMP_CMP_MASKED_EQ"}],
}

src = open("compose.yaml").read()
required = sorted(set(re.findall(r"\$\{([A-Za-z0-9_]+):\?", src)))
with tempfile.TemporaryDirectory() as d:
    open(os.path.join(d, "compose.yaml"), "w").write(src)
    with open(os.path.join(d, ".env"), "w") as f:
        for name in required:
            f.write(f"{name}=x\n")
    r = subprocess.run(
        ["docker", "compose", "--profile", "*", "config", "--format", "json"],
        cwd=d, capture_output=True, text=True,
    )
if r.returncode != 0:
    print("FAIL: docker compose could not resolve compose.yaml, so the baseline measured NOTHING: "
          + (r.stderr.strip().splitlines() or ["?"])[-1])
    sys.exit(1)
try:
    services = json.loads(r.stdout).get("services") or {}
except ValueError:
    print("FAIL: the resolved configuration is not JSON, so the baseline measured NOTHING.")
    sys.exit(1)
if not services:
    print("FAIL: the resolved configuration has no services, so the baseline measured NOTHING.")
    sys.exit(1)

try:
    table = json.load(open("hardening-exceptions.json")).get("exceptions")
except ValueError as e:
    print(f"FAIL: hardening-exceptions.json is not JSON: {e}")
    sys.exit(1)
if not isinstance(table, list):
    print("FAIL: hardening-exceptions.json has no exceptions list, so the baseline measured NOTHING.")
    sys.exit(1)

problems = []
excused = {}
for n, e in enumerate(table, 1):
    missing = [k for k in ("service", "key", "value", "why", "until") if not e.get(k)]
    if missing:
        problems.append(f"exception {n} has no {', '.join(missing)}: every field is required")
        continue
    if e["key"] not in KEYS:
        problems.append(f"exception {n} ({e['service']}): {e['key']} is not one of {sorted(KEYS)}")
        continue
    if e["service"] not in services:
        problems.append(f"exception {n}: {e['service']} is not a service of compose.yaml")
        continue
    if not isinstance(e["why"], str) or len(e["why"].strip()) < 20:
        problems.append(f"exception {n} ({e['service']} {e['key']}): the reason says nothing")
    excused[(e["service"], e["key"])] = e
used = set()


def excuse(svc, key):
    for k in (key, "baseline"):
        if k == "baseline" and key not in BASELINE:
            continue
        if (svc, k) in excused:
            used.add((svc, k))
            return True
    return False


def core_limit(s):
    # `core: 0` comes out of `config --format json` as {"core": {}}: a zero is omitted, on
    # Compose 2.26.1 and 5.6.1 alike. No `core` key at all is what no limit looks like.
    u = (s.get("ulimits") or {}).get("core")
    if isinstance(u, dict):
        return max([u.get(k) or 0 for k in ("single", "soft", "hard")])
    return u


profiles_used = set()
for svc in sorted(services):
    s = services[svc]
    say = lambda msg: problems.append(f"{svc}: {msg}")
    if s.get("read_only") is not True and not excuse(svc, "read_only"):
        say("no read_only: true, and no exception says why")
    if "ALL" not in (s.get("cap_drop") or []) and not excuse(svc, "cap_drop"):
        say("cap_drop does not hold ALL, and no exception says why")
    sec = s.get("security_opt") or []
    if "no-new-privileges:true" not in sec and not excuse(svc, "no_new_privileges"):
        say("security_opt does not hold no-new-privileges:true, and no exception says why")
    pids = s.get("pids_limit")
    if pids is None:
        if not excuse(svc, "pids"):
            say("no pids_limit, and no exception says why")
    elif not isinstance(pids, int) or isinstance(pids, bool) or pids <= 0:
        say(f"pids_limit {pids} is no limit")
    elif pids > PIDS_CEILING:
        say(f"pids_limit {pids} is above the ceiling of {PIDS_CEILING}")
    core = core_limit(s)
    if core is None:
        if not excuse(svc, "core"):
            say("no ulimits: core: 0, and no exception says why")
    elif core != 0:
        say(f"ulimits core is {core}, not 0")
    user = str(s.get("user") or "")
    if user in ("", "0", "root") or user.startswith("0:") or user.startswith("root:"):
        if not excuse(svc, "user"):
            say("runs as root or as whatever the image says, and no exception says why")
    adds = s.get("cap_add") or []
    if adds:
        if (svc, "cap_add") not in excused:
            say(f"cap_add {adds} and no exception names it")
        else:
            used.add((svc, "cap_add"))
            allowed = excused[(svc, "cap_add")]["value"]
            allowed = allowed if isinstance(allowed, list) else [allowed]
            wider = sorted(set(adds) - set(allowed))
            narrower = sorted(set(allowed) - set(adds))
            if wider:
                say(f"cap_add holds {wider}, which its exception does not name")
            if narrower:
                say(f"its exception names {narrower}, which cap_add does not hold")
    if "ALL" in adds:
        say("cap_add: ALL undoes the baseline")
    for t in s.get("tmpfs") or []:
        if "size=" not in str(t):
            say(f"tmpfs {t} has no size")
    for k, bad in FORBIDDEN_SERVICE_KEYS.items():
        if s.get(k) == bad:
            say(f"{k}: {bad} is not allowed on any service")
    if s.get("read_only") is False:
        say("read_only: false written out")
    if "no-new-privileges:false" in sec:
        say("no-new-privileges:false written out")
    for opt in sec:
        name, _, value = opt.replace("=", ":", 1).partition(":")
        if name == "seccomp":
            if value == "unconfined":
                say("seccomp:unconfined turns the filter off, and no exception can say why: name a profile file")
                continue
            e = excused.get((svc, "seccomp"))
            if e is None:
                say(f"{opt}, and no exception says why")
                continue
            used.add((svc, "seccomp"))
            if e["value"] != value:
                say(f"{opt}, and its exception names {e['value']}")
            profiles_used.add(value)
        elif name == "apparmor":
            if value == "unconfined":
                say("apparmor=unconfined written out: on the hosts that need it install.sh measures that, and on the rest it is a wider door")
                continue
            e = excused.get((svc, "apparmor"))
            if e is None:
                say(f"{opt}, and no exception says why")
                continue
            used.add((svc, "apparmor"))
            if f"- apparmor={e['value']}\n" not in src:
                say(f"its exception names apparmor={e['value']}, and compose.yaml has no such line")

# A zombie counts against pids_limit, and the browser's PID 1 reaps nothing, so the limit comes
# with init or not at all. Measured: 66 zombies after eleven fetches without it, none with it.
browser = services.get("scopyx-browser")
if browser is None:
    problems.append("there is no scopyx-browser, so what it needs was measured against nothing")
else:
    if browser.get("pids_limit") and browser.get("init") is not True:
        problems.append("scopyx-browser: a pids_limit with no init: true, and its zombies would use it up")
    if not browser.get("shm_size"):
        problems.append("scopyx-browser: no shm_size, and Chromium runs out of 64 MiB on ordinary pages")
    if not browser.get("mem_limit"):
        problems.append("scopyx-browser: no mem_limit, the one service whose size comes from what it is handed")

    secopts = browser.get("security_opt") or []
    if not any(o.startswith("seccomp:./seccomp/") for o in secopts):
        problems.append("scopyx-browser: no profile of its own, and the default refuses Chrome's sandbox")
    if not any(o.startswith("apparmor=") for o in secopts):
        problems.append("scopyx-browser: no apparmor line, so on one of the two supported hosts its sandbox does not start")


def canonical(o):
    return hashlib.sha256(json.dumps(o, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


for path in sorted(profiles_used):
    want = PROFILES.get(path)
    if want is None:
        problems.append(f"{path}: no digest in this gate, so nothing holds it to its name")
        continue
    try:
        raw = open(path, "rb").read()
        profile = json.loads(raw)
    except (OSError, ValueError) as e:
        problems.append(f"{path} cannot be read: {e}")
        continue
    if hashlib.sha256(raw).hexdigest() != want:
        problems.append(f"{path} changed and kept its name: Compose hashes the name, so a running service keeps the old filter. Make the next version")
    tag = os.path.basename(path).removesuffix(".json") + ":"
    rules = profile.get("syscalls") or []
    added = [r for r in rules if str(r.get("comment", "")).startswith(tag)]
    if canonical({**profile, "syscalls": [r for r in rules if r not in added]}) != DOCKER_DEFAULT:
        problems.append(f"{path}: take out its {tag} rules and what is left is not Docker's default")
    names = sorted(n for r in added for n in r.get("names", []))
    if names != sorted(ADDED):
        problems.append(f"{path} adds {names}, and what Chrome's sandbox was measured to need is {sorted(ADDED)}")
    for r in added:
        for n in r.get("names", []):
            if n in ADDED and r.get("args", []) != ADDED[n]:
                problems.append(f"{path}: {n} is not held to the mask it was measured under")
            if r.get("action") != "SCMP_ACT_ALLOW":
                problems.append(f"{path}: {n} is not a plain allow")

# The three a certified key hangs on (CLAUDE.md invariant 72). They stayed out of the baseline while a
# new start of vouchryx could find custody at its bound of four live keys and get none (G3.11). keyryx
# v0.1.4 retires the owner's oldest key at the bound instead, so they carry the baseline like the rest,
# nothing waits on G3.11 any more, and a keyryx pinned below v0.1.4 would put the bound back under them.
CLOSED = {"G3.11": "keyryx v0.1.4 closed it"}
KEY_SERVICES = ("init-volumes", "keyryx", "vouchryx")
for (svc, key), e in sorted(excused.items()):
    if e.get("until") in CLOSED:
        problems.append(f"{svc} {key}: until says {e['until']}, and {CLOSED[e['until']]}: take the line out, or name what it waits on now")
for svc in KEY_SERVICES:
    if svc not in services:
        problems.append(f"there is no {svc}, so the three a certified key hangs on were measured against NOTHING")
        continue
    held = sorted(k for k in BASELINE | {"baseline"} if (svc, k) in excused)
    if held:
        problems.append(f"{svc}: excused from the baseline ({', '.join(held)}), and since keyryx v0.1.4 nothing keeps it out")
pins = re.findall(r"ghcr\.io/taipanbox/keyryx:v(\d+)\.(\d+)\.(\d+)@sha256:[0-9a-f]{64}", src)
if not pins:
    problems.append("compose.yaml pins no keyryx by tag and digest, so the custody under the three was measured against NOTHING")
for pin in pins:
    if tuple(int(x) for x in pin) < (0, 1, 4):
        problems.append(f"keyryx is pinned at v{'.'.join(pin)}, below v0.1.4: a new start of vouchryx at the bound gets no key, and changing the three starts it")

for key, e in sorted(excused.items()):
    if key not in used:
        problems.append(f"the exception for {e['service']} {e['key']} excuses nothing: take it out")

# The installer asks the host, and the question has to be the browser's own: the same filter, the
# same user, none of the capabilities. A throwaway with more than the browser has answers for
# something else.
install = open("install.sh").read()
if browser is not None:
    block = re.search(r"^# browser-apparmor: begin$(.*?)^# browser-apparmor: end$", install, re.M | re.S)
    if not block:
        problems.append("install.sh has no '# browser-apparmor:' block, so nothing measures the host")
    else:
        body = block.group(1)
        m = re.search(r"^BROWSER_SECCOMP=(\S+)$", install, re.M)
        if not m or f"seccomp:./{m.group(1)}" not in (browser.get("security_opt") or []):
            problems.append("install.sh measures with a profile compose.yaml does not name for the browser")
        for flag in ("--cap-drop ALL", "--read-only", "no-new-privileges:true", f"--user {browser.get('user')}"):
            if flag not in body:
                problems.append(f"the installer's throwaway has no {flag}, so it does not ask what the browser would be told")
        if "for one in docker-default unconfined;" not in body:
            problems.append("the installer does not try docker-default first, so a host could lose AppArmor it does not need to lose")

# The installer writes one override of its own. It may not take the baseline back.
block = re.search(r"^# egress-override: begin$(.*?)^# egress-override: end$", install, re.M | re.S)
if not block:
    problems.append("install.sh has no '# egress-override:' block, so what it writes was measured against nothing")
else:
    for word in ("read_only", "cap_drop", "cap_add", "security_opt", "privileged", "pids_limit", "ulimits", "tmpfs"):
        if re.search(rf"^\s*{word}\s*:", block.group(1), re.M):
            problems.append(f"the override install.sh writes sets {word}: that takes the baseline back")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print(f"{len(problems)} problem(s) with the baseline.")
    sys.exit(1)
print(f"OK: {len(services)} services carry the baseline, {len(excused)} named exception(s), every one excusing something.")
PY
