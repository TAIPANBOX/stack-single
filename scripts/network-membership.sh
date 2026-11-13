#!/usr/bin/env bash
#
# Enforces: which networks each service of this stack is on, and that an agent
# has no route out except the doors (CLAUDE.md invariant 38).
#
# WHY
#
# Until invariant 38 every container shared one `default` network, and every
# container had a route to the internet. So an agent that could reach a model
# provider directly did not need the gateway at all: the metered door, the
# budget and the policy were all bypassable by one connection (findings F-014,
# the 2026-10-17 review). The fix is topology, not a rule inside a service:
# agent-facing services sit on an internal network whose only doors are the
# gateways and the MCP broker (scopyx is behind the broker since G2.1, so a read
# of the web is labelled from the act), and the few services that need the
# internet sit on the one network with a route out. That is only true if nothing drifts, so this
# gate reads the resolved configuration and compares it with the table below.
#
# THE TABLE IS THE SPEC
#
# A new service is not finished until it is in the table, and a service that
# changes networks changes the table in the same commit. Edge membership is a
# list here, not a judgement made per service: adding a service to edge is an
# edit to this file that a reviewer sees.
#
# THE OVERRIDE
#
# Two services need the internet only for a choice the operator makes in .env:
# typryx and the typryx-wardryx-proxy, for a jev or own-model backend. Compose
# cannot put a service on a network conditionally, so install.sh writes
# compose.override.yaml, which compose reads beside compose.yaml, and removes it
# when the choice is not made. This gate lifts the `# egress-override:` block
# out of install.sh, runs it for each choice, and checks the resolved
# configuration each time. (The costcrew add-on is not in that block: CLAUDE.md
# invariant 24 forbids install.sh from naming it, so its SSO route is not
# wired here at all.)
#
# NOT COVERED: that a container actually fails to reach the internet. That is a
# probe on a live Docker engine, and it is in .github/workflows/install.yml
# (the step named "agents network"), which runs on a fresh runner. This gate
# checks that the probe is there and that it names the networks it must.
#
# WHAT IT REFUSES TO REPORT OK ON
#
# No Docker Compose, no compose.yaml, a resolved configuration with no services,
# no egress-override block, or a table entry for a service that does not exist:
# each is reported and fails, rather than passing on nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! docker compose version >/dev/null 2>&1; then
	echo "FAIL: no docker compose here, so the resolved networks could not be read."
	echo "      This gate does not pass on a box that cannot run it."
	exit 1
fi
if [ ! -f compose.yaml ] || [ ! -f install.sh ]; then
	echo "FAIL: compose.yaml or install.sh is missing, so this measured nothing."
	exit 1
fi

python3 - "$PWD" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

root = sys.argv[1]
problems = []


def bad(msg):
    problems.append(msg)


# service -> the networks the table gives it, with no override
TABLE = {
    "init-volumes": {"core"},
    "policy-db": {"core"},
    "wardryx": {"core", "risk-signal", "browser-policy"},
    "idryx": {"core"},
    "heraldyx": {"edge", "core"},
    "agent-conform": {"core"},
    "scopyx": {"core", "edge"},
    "scopyx-browser": {"edge", "browser-policy", "browser-broker"},
    "typryx": {"core"},
    "typryx-wardryx-proxy": {"risk-signal"},
    "tokenfuse-mcp-broker": {"agents", "core", "risk-signal", "browser-broker", "front"},
    "vouchryx": {"core"},
    "keyryx": {"core"},
    "keyryx-witness": set(),
    "tokenfuse-cloud": {"core"},
    "tokenfuse-gateway": {"edge", "agents", "core"},
    "tokenfuse-gateway-openai": {"edge", "agents", "core"},
    "wg": {"edge"},
    "caddy": {"edge", "front"},
    # the guests' two proxies (invariant 77): no key, no secret, no environment
    "guest-door": {"core", "guests"},
    "guest-callback": {"core", "callbacks"},
    "console": {"core", "agents", "front"},
    "record-seal": {"core"},
    "focus-export": {"core"},
    "idryx-detect": {"core"},
    # the broker drills, run by a person: they reach the broker and the gateway by name, and nothing else
    "mockryx-drill": {"core"},
    "verdryx-drift": {"core"},
    # the error-budget routine: reads traces, appends to its own stream, calls nothing
    "verdryx-slo": set(),
    "costcrew-init": {"core"},
    "costcrew": {"agents", "core", "front"},
    # the CostCrew runner (invariant 60): on agents alone, no route out, so its model calls
    # can only reach a provider through the gateway
    "costcrew-run": {"agents"},
}
# services that get edge only through compose.override.yaml, and the choice
OVERRIDE_EDGE = {"typryx": "typed", "typryx-wardryx-proxy": "typed"}
# the one list of who may be on each network, written out so a reader sees it
AGENT_FACING = {"tokenfuse-gateway", "tokenfuse-gateway-openai", "tokenfuse-mcp-broker",
                "console", "costcrew", "costcrew-run"}
FRONT = {"caddy", "console", "costcrew", "tokenfuse-mcp-broker"}
RISK = {"wardryx", "typryx-wardryx-proxy", "tokenfuse-mcp-broker"}
# the browser's one path to a decision: scopyx-browser and wardryx, nothing else
BROWSER_POLICY = {"scopyx-browser", "wardryx"}
# the broker's one path to the browser (G2.1): the browser is not agent-facing, so the
# broker is the only way a read of the web reaches it
BROWSER_BROKER = {"scopyx-browser", "tokenfuse-mcp-broker"}
# where containers of other projects sit (invariant 77): guest-door alone, which takes the doors'
# three names there and forwards an agent's routes; no door, no plane, no database and no key.
# A door that shared a network with a guest could be handed, by a guest that took a plane's
# name, a call meant for that plane: Docker answers a name from every network a container is on.
GUESTS = {"guest-door"}
GUEST_DOOR_NAMES = {"vouchryx", "tokenfuse-gateway", "tokenfuse-mcp-broker"}
# where a guest the stack calls back is reached: guest-callback alone
CALLBACKS = {"guest-callback"}
INTERNAL = {"core", "agents", "risk-signal", "browser-policy", "browser-broker", "guests", "callbacks"}
NETWORKS = INTERNAL | {"edge", "front"}

# ---- the install.sh block that writes the override --------------------------
install = open(os.path.join(root, "install.sh")).read()
m = re.search(r"^# egress-override: begin\n(.*?)^# egress-override: end\n", install, re.M | re.S)
if m:
    block = m.group(1)
else:
    # Reported, not exited on: the rest still says what is wrong with the networks.
    bad("install.sh has no egress-override block, so the conditional edge was measured nothing")
    block = "egress_override() { :; }\n"

# ---- a scratch project with fake secrets, like typed-risk-signal.sh ----------
work = tempfile.mkdtemp(prefix="s2net-")
blockdir = tempfile.mkdtemp(prefix="s2net-block-")
shutil.copy(os.path.join(root, "compose.yaml"), os.path.join(work, "compose.yaml"))
for d in ("typed", "delegation", "delegation-public", "environments", "identity", "identity-openai"):
    os.makedirs(os.path.join(work, d))
open(os.path.join(work, "policy.yaml"), "w").close()
text = open(os.path.join(work, "compose.yaml")).read()
names = sorted(set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*):\?", text)))
with open(os.path.join(work, ".env"), "w") as f:
    for n in names:
        f.write("%s=fake-not-a-secret\n" % n)
    f.write("TYPRYX_KEYS=fake-door-key=agent://local.invalid/default-agent\n")

clean_env = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSE_")}
clean_env.pop("TYPED_MODE", None)


def run_block(extra):
    env = dict(clean_env)
    env.update(extra)
    script = os.path.join(blockdir, "block.sh")
    with open(script, "w") as f:
        f.write("set -u\ndie() { echo \"$*\" >&2; exit 2; }\n" + block + "egress_override \"$1\"\n")
    r = subprocess.run(["bash", script, work], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        bad("the egress-override block failed for %s: %s" % (extra, (r.stderr or r.stdout).strip()[-200:]))


def resolve():
    cmd = ["docker", "compose", "--project-directory", work, "-f", os.path.join(work, "compose.yaml")]
    if os.path.exists(os.path.join(work, "compose.override.yaml")):
        cmd += ["-f", os.path.join(work, "compose.override.yaml")]
    cmd += ["--profile", "*", "config", "--format", "json"]
    r = subprocess.run(cmd, capture_output=True, text=True, env=clean_env, cwd=work)
    if r.returncode != 0:
        bad("docker compose config failed: %s" % (r.stderr.strip().splitlines() or ["?"])[-1])
        return None
    return json.loads(r.stdout)


CASES = [
    ("the stock box (typed stub)", {"TYPED_MODE": "stub"}, set()),
    ("typed off", {"TYPED_MODE": "off"}, set()),
    ("typed jev", {"TYPED_MODE": "jev"}, {"typryx", "typryx-wardryx-proxy"}),
    ("typed own-model", {"TYPED_MODE": "own-model"}, {"typryx", "typryx-wardryx-proxy"}),
]

counted = 0
for label, extra, want_edge in CASES:
    run_block(extra)
    cfg = resolve()
    if cfg is None:
        continue
    svcs = cfg.get("services", {})
    if not svcs:
        bad("%s: the resolved configuration has no services, so this gate measured nothing" % label)
        continue
    got_names = set(svcs)
    for n in sorted(got_names - set(TABLE)):
        bad("%s: %s is not in the table in scripts/network-membership.sh, so its networks are unclassified" % (label, n))
    for n in sorted(set(TABLE) - got_names):
        bad("%s: the table names %s and the resolved configuration does not have it" % (label, n))
    for n, s in svcs.items():
        if n not in TABLE:
            continue
        got = set((s.get("networks") or {}).keys())
        if "default" in got:
            bad("%s: %s is on the default network, which has a route out to the internet" % (label, n))
        want = set(TABLE[n]) | ({"edge"} if n in want_edge else set())
        extra_edge = got - want
        if "edge" in extra_edge:
            bad("%s: %s is on network edge, which the table does not give it" % (label, n))
        if got != want:
            bad("%s: %s is on %s, the table gives it %s" % (label, n, sorted(got), sorted(want)))
    counted += 1

# The stock box's own checks: the networks and who is on each.
run_block({"TYPED_MODE": "stub"})
cfg = resolve()
if cfg is not None:
    if not cfg.get("services"):
        bad("the resolved configuration has no services, so this gate measured nothing")
    else:
        svcs = cfg["services"]
        nets = cfg.get("networks", {})
        if set(nets) != NETWORKS:
            bad("the networks are %s, the table gives %s" % (sorted(nets), sorted(NETWORKS)))
        for n, props in nets.items():
            props = props or {}
            if n in INTERNAL and props.get("internal") is not True:
                bad("network %s must be internal, so it has no route out" % n)
            if n == "edge" and props.get("internal") is True:
                bad("network edge must not be internal: it is the one route out")
            if n == "front":
                if props.get("internal") is True:
                    bad("network front must not be internal: published ports need a route to the host")
                opt = (props.get("driver_opts") or {}).get("com.docker.network.bridge.enable_ip_masquerade")
                if str(opt).lower() != "false":
                    bad("network front must not masquerade: nothing on it may use this host as a route out")

        def members(net):
            return {n for n, s in svcs.items() if net in (s.get("networks") or {})}

        if members("edge") != {n for n, t in TABLE.items() if "edge" in t}:
            bad("edge members are %s, the table lists %s" % (sorted(members("edge")), sorted(n for n, t in TABLE.items() if "edge" in t)))
        if "scopyx-browser" in members("core"):
            bad("scopyx-browser is on core: the browser must not reach a plane")
        if members("browser-policy") != BROWSER_POLICY:
            bad("browser-policy members are %s, the table lists %s: the browser's only path is wardryx, and nothing else may join it"
                % (sorted(members("browser-policy")), sorted(BROWSER_POLICY)))
        if members("browser-broker") != BROWSER_BROKER:
            bad("browser-broker members are %s, the table lists %s: the broker's only path to the browser, and nothing else may join it"
                % (sorted(members("browser-broker")), sorted(BROWSER_BROKER)))
        for n in ("scopyx", "scopyx-browser"):
            if n in members("agents"):
                bad("%s is on the agents network: an agent would fetch without the broker, and the run would carry no label from the act" % n)
        plane_on_agents = members("agents") - AGENT_FACING
        for n in sorted(plane_on_agents):
            bad("the agents network holds %s, which is not an agent-facing service" % n)
        if members("agents") != AGENT_FACING:
            bad("agents members are %s, the table lists %s" % (sorted(members("agents")), sorted(AGENT_FACING)))
        if members("front") != FRONT:
            bad("front members are %s, the table lists %s" % (sorted(members("front")), sorted(FRONT)))
        if members("guests") != GUESTS:
            bad("guests members are %s, the table lists %s: a container of another project reaches the doors through guest-door, and nothing else may join it"
                % (sorted(members("guests")), sorted(GUESTS)))
        if members("callbacks") != CALLBACKS:
            bad("callbacks members are %s, the table lists %s: a guest is called back through guest-callback, and nothing else may join it"
                % (sorted(members("callbacks")), sorted(CALLBACKS)))
        gd = ((svcs.get("guest-door") or {}).get("networks") or {}).get("guests") or {}
        if set(gd.get("aliases") or []) != GUEST_DOOR_NAMES:
            bad("guest-door answers on the guests network to %s, not to %s: a guest calls the doors by their own names"
                % (sorted(gd.get("aliases") or []), sorted(GUEST_DOOR_NAMES)))
        for n in ("guest-door", "guest-callback"):
            s_ = svcs.get(n) or {}
            if s_.get("environment"):
                bad("%s is given an environment (%s): the guests' proxies hold no key and read no secret"
                    % (n, ", ".join(sorted(s_["environment"]))))
            for v in s_.get("volumes") or []:
                src = v.get("source", "") if isinstance(v, dict) else str(v).split(":")[0]
                ro = v.get("read_only") if isinstance(v, dict) else str(v).endswith(":ro")
                if not ro or "guest-door" not in str(src):
                    bad("%s mounts %s: the guests' proxies mount their own configuration, read only, and nothing else" % (n, src))
        if members("risk-signal") != RISK:
            bad("risk-signal members are %s, the table lists %s" % (sorted(members("risk-signal")), sorted(RISK)))
        alias = ((svcs.get("scopyx-browser") or {}).get("networks") or {}).get("browser-broker") or {}
        if "scopyx" not in (alias.get("aliases") or []):
            bad("scopyx-browser lost the alias scopyx on the browser-broker network, so the broker cannot reach it")

# ---- the probes that prove it on a live engine --------------------------------
sf = os.path.join(root, "install.sh")
if re.search(r"agent-stack_default", install):
    bad("install.sh names the agent-stack_default network: no network of this stack is a default any more")
if not re.search(r'^NET="agent-stack_core"', install, re.M):
    bad("install.sh does not probe from agent-stack_core, so its checks would not see the planes they test")
wf_path = os.path.join(root, ".github", "workflows", "install.yml")
wf = open(wf_path).read() if os.path.exists(wf_path) else ""
for needle, why in (
    ("agent-stack_browser-policy", "the browser's policy network, from a container that is only on it"),
    ("agent-stack_agents", "the agents network"),
    ("agent-stack_guests", "the guests network"),
    ("agent-stack_callbacks", "the callbacks network"),
    ("agent-stack_edge", "a positive control on the edge network, so a broken runner cannot pass"),
    ("tokenfuse-gateway:4100", "the gateway, which an agent must reach"),
):
    if needle not in wf:
        bad("the install workflow does not probe %s (%s)" % (why, needle))

shutil.rmtree(work, ignore_errors=True)
shutil.rmtree(blockdir, ignore_errors=True)

if problems:
    # The same fault is seen once per egress case; report it once, with the first case's wording.
    labels = [c[0] + ": " for c in CASES]
    seen = set()
    shown = []
    for p in problems:
        key = p
        for l in labels:
            if p.startswith(l):
                key = p[len(l):]
                break
        if key in seen:
            continue
        seen.add(key)
        shown.append(p)
    for p in shown:
        print("FAIL: " + p)
    print("network-membership: %d problem(s), %d distinct" % (len(problems), len(shown)))
    sys.exit(1)

print("OK: %d services classified in the table; %d egress cases resolved; networks %s"
      % (len(TABLE), counted, ", ".join(sorted(NETWORKS))))
print("    the agents network holds only the doors (%s); scopyx is reached through the broker" % ", ".join(sorted(AGENT_FACING)))
print("    the guests network holds only %s, under the names %s; callbacks only %s"
      % (", ".join(sorted(GUESTS)), ", ".join(sorted(GUEST_DOOR_NAMES)), ", ".join(sorted(CALLBACKS))))
PY
