#!/usr/bin/env bash
# CLAUDE.md invariant 80: the gateway's spend reaches the FinOps console. focus-export runs on
# every box, over both gateway doors, one folder per door, and the console reads both folders,
# read only, as its tokenfuse-focus connector.
#
# WHY
#
# Until 1.13.0 no launcher named the console's spend source. focus-export sat behind the
# operator's `routines` profile, which install.sh never starts, and read `traces/gateway` alone,
# so the OpenAI door's calls never reached FOCUS (stack-single#61); and the console mounted the
# bus and its own data and nothing else, with no -focus-dir, so its AI pages showed the generated
# estate it starts with beside two gateways that had served real agents. Every piece was green on
# its own.
#
# WHAT THIS CHECKS
#
#   A. the resolved configuration (docker compose config, every profile on, a fake .env):
#      focus-export sits behind no profile, mounts the traces volume read only and the focus
#      volume read-write, and its script reads `traces/<door>` and writes `focus/<door>` for both
#      doors, gateway and gateway-openai;
#   B. costcrew mounts the same focus volume READ ONLY, and its -focus-dir and -focus-dir-openai
#      name that mount's `gateway` and `gateway-openai` folders, two different folders, with
#      -focus-replace-generated beside them, on a costcrew image of v0.7.0 or later (the first that
#      reads -focus-dir, costcrew invariant 104);
#   C. init-volumes creates both folders, owns them 10001 (focus-export's uid) and leaves them
#      readable and searchable by "other", because costcrew runs outside the bus group and joins
#      no group (invariant 24);
#   D. focus-export's own script, lifted out of the resolved configuration and run in a scratch
#      tree against a stub `tokenfuse`: each door gets exactly one file the console would read
#      (`*.csv`), written whole (no partial file left under a name the console reads), a window
#      that exports nothing keeps the last good file, and the stub was asked about both doors'
#      trace folders;
#   E. install.sh checks, on every run, that focus-export runs with a folder per door.
#
# It refuses to report OK when it measured nothing: no focus-export, no costcrew, no init-volumes,
# no script to run, or no Docker to resolve the file.
#
# Scenarios: features/the-gateway-spend-reaches-the-finops-console.feature.
# Teeth: scripts/gates-have-teeth.sh, cases named "costcrew-reads-spend".
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
	echo "costcrew-reads-spend: docker is needed to resolve compose.yaml; measured nothing" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/costcrew-reads-spend.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import json, os, re, shlex, subprocess, sys

work = sys.argv[1]
root = os.getcwd()
problems = []

def bad(msg):
    problems.append(msg)

def stop(msg):
    print("FAIL costcrew-reads-spend: " + msg)
    sys.exit(1)

text = open("compose.yaml").read()
required = sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?", text)))
envfile = os.path.join(work, ".env")
with open(envfile, "w") as f:
    for name in required:
        f.write("%s=placeholder\n" % name)
clean = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}
r = subprocess.run(
    ["docker", "compose", "--project-directory", root, "--env-file", envfile,
     "-f", os.path.join(root, "compose.yaml"), "--profile", "*", "config", "--format", "json"],
    capture_output=True, text=True, env=clean, cwd=root)
if r.returncode != 0:
    stop("docker compose config failed: %s" % ((r.stderr.strip().splitlines() or ["?"])[-1]))
cfg = json.loads(r.stdout)
services = cfg.get("services", {})
for need in ("focus-export", "costcrew", "init-volumes"):
    if need not in services:
        stop("no %s service in the resolved configuration; measured nothing" % need)

# Profiles exactly as written: the resolved form with every profile on keeps them listed.
def profiles_written(name):
    m = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [a-z0-9-]+:\s*$|\Z)", text, re.M | re.S)
    if not m:
        return None
    p = re.search(r'^\s+profiles:\s*\[([^\]]*)\]', m.group(1), re.M)
    return [x.strip().strip('"') for x in p.group(1).split(",")] if p else []

def mounts(svc):
    out = []
    for v in services[svc].get("volumes", []) or []:
        if v.get("type") == "volume":
            out.append((v.get("source"), v.get("target"), bool(v.get("read_only"))))
    return out

DOORS = ("gateway", "gateway-openai")

# ---- A. focus-export ----------------------------------------------------------------
fx = services["focus-export"]
prof = profiles_written("focus-export")
if prof is None:
    stop("compose.yaml has no focus-export block to read its profiles from; measured nothing")
if prof:
    bad("focus-export sits behind the profile(s) %s, so a box that sets nothing exports nothing "
        "and the console reads no spend" % prof)
fx_m = mounts("focus-export")
traces = [m for m in fx_m if m[0] == "traces"]
focus = [m for m in fx_m if m[0] == "focus"]
if not traces or not traces[0][2]:
    bad("focus-export does not mount the traces volume read only")
if not focus or focus[0][2]:
    bad("focus-export does not mount the focus volume read-write, so it cannot write the export")
script = "\n".join(fx.get("command") or [])
entry = fx.get("entrypoint") or []
if not script.strip():
    stop("focus-export has no script in its command; measured nothing")
for door in DOORS:
    if not re.search(r"\bfor door in\b[^\n]*\b%s\b" % re.escape(door), script):
        bad("focus-export's loop does not name the %s door, so its calls never reach FOCUS" % door)

# ---- B. costcrew --------------------------------------------------------------------
cc = services["costcrew"]
cmd = [str(x) for x in (cc.get("command") or [])]
def flag(name):
    if name in cmd:
        i = cmd.index(name)
        return cmd[i + 1] if i + 1 < len(cmd) else ""
    return None
cc_focus = [m for m in mounts("costcrew") if m[0] == "focus"]
if not cc_focus:
    bad("costcrew does not mount the focus volume, so -focus-dir names a folder that is not there "
        "and the console refuses to start")
elif not cc_focus[0][2]:
    bad("costcrew mounts the focus volume read-write; it reads the export and must not be able to change it")
main_dir, oa_dir = flag("-focus-dir"), flag("-focus-dir-openai")
if main_dir is None:
    bad("costcrew has no -focus-dir, so the console reads none of the gateway's spend")
if oa_dir is None:
    bad("costcrew has no -focus-dir-openai, so the OpenAI door's spend never reaches the console")
if cc_focus and main_dir is not None and oa_dir is not None:
    base = cc_focus[0][1].rstrip("/")
    if main_dir.rstrip("/") != base + "/gateway":
        bad("costcrew's -focus-dir is %r, not the gateway's folder %r of the focus mount" % (main_dir, base + "/gateway"))
    if oa_dir.rstrip("/") != base + "/gateway-openai":
        bad("costcrew's -focus-dir-openai is %r, not the OpenAI door's folder %r of the focus mount" % (oa_dir, base + "/gateway-openai"))
    if main_dir.rstrip("/") == oa_dir.rstrip("/"):
        bad("costcrew names one folder as both doors; it refuses that, and would count every call twice")
if "-focus-replace-generated" not in cmd:
    bad("costcrew has no -focus-replace-generated, so on a box with the generated estate the console imports nothing")
img = str(cc.get("image", ""))
v = re.search(r":v(\d+)\.(\d+)\.(\d+)", img)
if not v:
    bad("costcrew's image %r carries no version tag to judge" % img)
elif tuple(int(x) for x in v.groups()) < (0, 7, 0):
    bad("costcrew's image %r is older than v0.7.0, which does not read -focus-dir" % img)

# ---- C. init-volumes ---------------------------------------------------------------------
iv = "\n".join(services["init-volumes"].get("command") or [])
for door in DOORS:
    if not re.search(r"mkdir -p[^\n]*/vol/focus/%s(\s|$)" % re.escape(door), iv):
        bad("init-volumes does not create /vol/focus/%s, and the console refuses to start on a folder that is not there" % door)
if not re.search(r"chown -R 10001:10001 /vol/focus(\s|;|$)", iv):
    bad("init-volumes does not give /vol/focus to 10001, focus-export's uid")
for door in DOORS:
    modes = re.findall(r"chmod (\d{3,4})[^\n;]*/vol/focus/%s(?=[\s;]|$)" % re.escape(door), iv)
    if not modes:
        bad("init-volumes sets no mode on /vol/focus/%s" % door)
    elif int(modes[-1][-1]) & 5 != 5:
        bad("init-volumes leaves /vol/focus/%s mode %s, which costcrew (outside the bus group) cannot read" % (door, modes[-1]))
top = re.findall(r"chmod (\d{3,4}) /vol/focus(?=[\s;]|$)", iv)
if not top or int(top[-1][-1]) & 1 != 1:
    bad("init-volumes leaves /vol/focus itself unsearchable by other, so costcrew cannot reach either folder")

# ---- D. the loop itself, against a stub tokenfuse ------------------------------------------
tree = os.path.join(work, "tree")
stack = os.path.join(tree, "var/lib/stack")
for door in DOORS:
    os.makedirs(os.path.join(stack, "traces", door), exist_ok=True)
    os.makedirs(os.path.join(stack, "focus", door), exist_ok=True)
stubs = os.path.join(work, "stubs")
os.makedirs(stubs, exist_ok=True)
asked = os.path.join(work, "asked")
with open(os.path.join(stubs, "tokenfuse"), "w") as f:
    f.write("""#!/bin/sh
# focus-export --traces DIR --out FILE; behaves as STUB_<door> says: csv or none
[ "$1" = focus-export ] || { echo "stub: unexpected $*" >&2; exit 97; }
traces="$3"; out="$5"
echo "$traces" >>"%s"
echo "$out" >>"%s.out"
door="$(basename "$traces")"
mode="$(cat "%s/mode.$door" 2>/dev/null || echo none)"
if [ "$mode" = csv ]; then
  printf 'BilledCost,x_agent_id\\n0.000010,agent://ci.invalid/%%s\\n' "$door" >"$out"
  exit 0
fi
echo "Error: no calls found in the trace at '$traces' - nothing to export" >&2
exit 1
""" % (asked, asked, work))
with open(os.path.join(stubs, "sleep"), "w") as f:
    # One window per run: the loop's sleep ends the shell that runs it.
    f.write("#!/bin/sh\nkill -TERM $PPID\nexit 0\n")
for t in ("tokenfuse", "sleep"):
    os.chmod(os.path.join(stubs, t), 0o755)

# The resolved configuration keeps compose's escaping: `$$` is the shell's `$`.
body = script.replace("$$", "$").replace("/var/lib/stack", stack)
if body == script:
    stop("focus-export's script names no /var/lib/stack path to run it against; measured nothing")
if entry[:2] != ["/bin/sh", "-c"]:
    bad("focus-export's entrypoint is %r, not /bin/sh -c, so its script is handed to the gateway as arguments" % entry)

def window(modes):
    for door, m in modes.items():
        open(os.path.join(work, "mode." + door), "w").write(m)
    env = dict(os.environ, PATH=stubs + ":" + os.environ["PATH"], FOCUS_EXPORT_INTERVAL="1")
    return subprocess.run(["sh", "-c", body], env=env, capture_output=True, text=True, timeout=30)

def readable(door):
    d = os.path.join(stack, "focus", door)
    return sorted(n for n in os.listdir(d) if n.lower().endswith((".csv", ".csv.gz")))

def leftovers(door):
    d = os.path.join(stack, "focus", door)
    return sorted(os.listdir(d))

w1 = window({"gateway": "csv", "gateway-openai": "csv"})
for door in DOORS:
    got = readable(door)
    if len(got) != 1:
        bad("after a window with calls on both doors, focus/%s holds %d file(s) the console reads (%s), not one: %s"
            % (door, len(got), got, (w1.stdout + w1.stderr).strip()[-300:]))
    elif door not in open(os.path.join(stack, "focus", door, got[0])).read():
        bad("focus/%s/%s does not hold that door's export" % (door, got[0]))
    if len(leftovers(door)) != len(readable(door)):
        bad("focus/%s keeps a file beside the export after a good window: %s" % (door, leftovers(door)))
seen = open(asked).read().split() if os.path.exists(asked) else []
for door in DOORS:
    if os.path.join(stack, "traces", door) not in seen:
        bad("the stub was never asked about traces/%s, so that door's calls are not exported" % door)

outs = open(asked + ".out").read().split() if os.path.exists(asked + ".out") else []
for o in outs:
    if o.lower().endswith((".csv", ".csv.gz")):
        bad("focus-export writes the export straight into %s, a name the console reads, so a read during "
            "the write sees half an export" % os.path.relpath(o, tree))
        break
first = {d: readable(d) for d in DOORS}
w2 = window({"gateway": "none", "gateway-openai": "csv"})
if readable("gateway") != first["gateway"] or not first["gateway"]:
    bad("a window that exported nothing on the gateway did not keep its last good file: %s -> %s"
        % (first["gateway"], readable("gateway")))
if len(readable("gateway-openai")) != 1:
    bad("a second window grew focus/gateway-openai to %s; one file per door is what bounds the folder" % readable("gateway-openai"))
if leftovers("gateway") != readable("gateway"):
    bad("a window that exported nothing left a file beside the export: %s" % leftovers("gateway"))
if "no calls found" not in (w2.stdout + w2.stderr):
    bad("a window that exported nothing did not print the tool's own words, so a real failure would read as quiet")

# ---- E. install.sh asks the box ---------------------------------------------------------------
install = open("install.sh").read()
m = re.search(r'^check "focus-export is running, with a folder per door" \\\n\s+"([^\n]*)"', install, re.M)
if not m:
    bad("install.sh does not check that focus-export runs with a folder per door")
else:
    for door in DOORS:
        if "/var/lib/stack/focus/%s'" % door not in m.group(1) and "/var/lib/stack/focus/%s " % door not in m.group(1):
            bad("install.sh's focus-export check does not ask for the %s folder" % door)

if problems:
    for p in problems:
        print("FAIL costcrew-reads-spend: " + p)
    sys.exit(1)
print("OK: costcrew-reads-spend (invariant 80): focus-export runs on every box over both doors, one file per door "
      "written whole, and the FinOps console reads both folders read only as the gateway's spend")
PY
