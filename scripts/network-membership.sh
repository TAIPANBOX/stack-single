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
# gateways and scopyx, and the few services that need the internet sit on the
# one network with a route out. That is only true if nothing drifts, so this
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
    "scopyx": {"agents", "core", "edge"},
    "scopyx-browser": {"agents", "edge", "browser-policy"},
    "typryx": {"core"},
    "typryx-wardryx-proxy": {"risk-signal"},
    "tokenfuse-mcp-broker": {"agents", "core", "risk-signal", "front"},
    "vouchryx": {"core"},
    "tokenfuse-cloud": {"core"},
    "tokenfuse-gateway": {"edge", "agents", "core"},
    "tokenfuse-gateway-openai": {"edge", "agents", "core"},
    "wg": {"edge"},
    "caddy": {"edge", "front"},
    "console": {"core", "agents", "front"},
    "record-seal": {"core"},
    "focus-export": {"core"},
    "idryx-detect": {"core"},
    "verdryx-drift": {"core"},
    "costcrew-init": {"core"},
    "costcrew": {"agents", "core", "front"},
}
# services that get edge only through compose.override.yaml, and the choice
OVERRIDE_EDGE = {"typryx": "typed", "typryx-wardryx-proxy": "typed"}
# the one list of who may be on each network, written out so a reader sees it
AGENT_FACING = {"tokenfuse-gateway", "tokenfuse-gateway-openai", "tokenfuse-mcp-broker",
                "scopyx", "scopyx-browser", "console", "costcrew"}
FRONT = {"caddy", "console", "costcrew", "tokenfuse-mcp-broker"}
RISK = {"wardryx", "typryx-wardryx-proxy", "tokenfuse-mcp-broker"}
# the browser's one path to a decision: scopyx-browser and wardryx, nothing else
BROWSER_POLICY = {"scopyx-browser", "wardryx"}
INTERNAL = {"core", "agents", "risk-signal", "browser-policy"}
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
        plane_on_agents = members("agents") - AGENT_FACING
        for n in sorted(plane_on_agents):
            bad("the agents network holds %s, which is not an agent-facing service" % n)
        if members("agents") != AGENT_FACING:
            bad("agents members are %s, the table lists %s" % (sorted(members("agents")), sorted(AGENT_FACING)))
        if members("front") != FRONT:
            bad("front members are %s, the table lists %s" % (sorted(members("front")), sorted(FRONT)))
        if members("risk-signal") != RISK:
            bad("risk-signal members are %s, the table lists %s" % (sorted(members("risk-signal")), sorted(RISK)))
        alias = ((svcs.get("scopyx-browser") or {}).get("networks") or {}).get("agents") or {}
        if "scopyx" not in (alias.get("aliases") or []):
            bad("scopyx-browser lost the alias scopyx on the agents network, so agents cannot reach it")
        if "agents" not in ((svcs.get("scopyx-browser") or {}).get("networks") or {}):
            bad("scopyx-browser is not on the agents network")

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
print("    the agents network holds only the doors and scopyx (%s)" % ", ".join(sorted(AGENT_FACING)))
PY
