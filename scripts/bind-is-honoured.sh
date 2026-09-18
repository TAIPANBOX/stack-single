#!/usr/bin/env bash
#
# Enforces invariant 11 of CLAUDE.md: the operator's bind is honoured end to
# end. `GATEWAY_BIND` is the one address decision an operator makes here, and
# every check and every host setting that depends on it has to read it rather
# than assume loopback.
#
# WHAT THIS IS ABOUT
#
# Measured 2026-09-17 on a box whose GATEWAY_BIND was its tailscale address,
# the shape a customer's appliance wants (reachable from their clouds over a
# private mesh, not from the LAN): the gateway was published on that address
# only, `curl http://<that address>:4100/healthz` answered 200, the check that
# reads Docker's port rule passed, and the FIRST check of the run read FAIL,
# twice, because it probed `http://127.0.0.1:4100/healthz` whatever the
# operator had chosen. A healthy box exited 1 (#54).
#
# So this holds, about install.sh's own verification section:
#
#   1. The "gateway answers" check probes `$GATEWAY_PROBE`, never a literal
#      loopback, and the probe map sends `0.0.0.0` to `127.0.0.1`: every
#      address includes loopback, and loopback is the one that is always there.
#
#   2. When the bind is ONE address, loopback must REFUSE, and a check says so.
#      It must fail to pass, like the "NOT on the host" checks beside it, and
#      it must be skipped for loopback and for 0.0.0.0, where a refusal would
#      be wrong. A gateway answering on an address the operator did not name
#      is published wider than they decided.
#
# And about what the same bind needs from the HOST. Measured the same day
# (#56): after a reboot, docker.service became active two seconds after
# tailscaled, before tailscale0 carried the address, the gateway's port bind
# failed, the container ended `Exited (128)`, and `unless-stopped` never
# retries a start that failed. A later `up -d` printed `Started` for a
# container with no port mapping at all. Put right, and proven by a second
# reboot, with `net.ipv4.ip_nonlocal_bind = 1` and a docker.service drop-in
# ordered after tailscaled. So:
#
#   3. For a bind that is one address, install.sh writes the sysctl into
#      /etc/sysctl.d/, applies it, and refuses with the reason (`|| die`) if
#      either fails: a box that looks installed until its first reboot is the
#      half-install invariant 6 is about.
#
#   4. Where tailscaled.service exists, it writes a docker.service drop-in
#      carrying both `After=tailscaled.service` and `Wants=tailscaled.service`,
#      reloads systemd, and refuses with the reason if it cannot.
#
#   5. The verification section reads the gateway's port mapping from
#      `docker port` on the container itself. `Started` is compose's word for
#      the container; the mapping is Docker's word for the port, and on that
#      box the two disagreed.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No "gateway answers" check left, or no `case "$GATEWAY_BIND"` block left to
# judge: each is reported and fails. A gate whose subject has been deleted
# must not read as a clean bill of health.
#
# This file is the ONE copy of this check. CI and the pre-push hook call it.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - install.sh <<'PY'
import re
import sys

lines = open(sys.argv[1]).read().split("\n")
problems = []


def note(msg):
    problems.append(msg)
    print("FAIL: " + msg)


def find(pattern, start=0, end=None):
    """Index of the first line matching the regex in [start, end), or None."""
    for i in range(start, len(lines) if end is None else end):
        if re.search(pattern, lines[i]):
            return i
    return None


def guarded_by_bind_case(idx, what):
    """The line at idx must sit inside a `case "$GATEWAY_BIND"` whose no-op
    arm names both loopback and 0.0.0.0, so the code there runs only for a
    bind that is ONE address."""
    top = None
    for j in range(idx, -1, -1):
        if re.match(r'^\s*case "\$GATEWAY_BIND" in\s*$', lines[j]):
            top = j
            break
        if j < idx and re.match(r"^\s*esac\s*$", lines[j]):
            break
    if top is None:
        note(f"{what} is not inside a `case \"$GATEWAY_BIND\"` block: it would run for every bind, loopback included")
        return
    arm = find(r'^\s*[^)#]*\b127\.0\.0\.1\b[^)]*\b0\.0\.0\.0\b[^)]*\)\s*;;\s*$', top, idx)
    if arm is None:
        note(f"{what} is inside a `case \"$GATEWAY_BIND\"` block with no arm that skips both 127.0.0.1 and 0.0.0.0: it would run where it is wrong")


# ---- 1. the probe reads the operator's choice --------------------------------
answers = find(r'^\s*check "gateway answers on ')
if answers is None:
    note('no `check "gateway answers on ..."` in install.sh: the first verification check is gone, so this gate measured nothing')
else:
    cmd = lines[answers]
    if re.search(r"127\.0\.0\.1:4100", cmd):
        note("the gateway check probes 127.0.0.1:4100 whatever GATEWAY_BIND says: a gateway published on one address reads FAIL on a healthy box")
    if "$GATEWAY_PROBE" not in cmd and "${GATEWAY_PROBE}" not in cmd:
        note("the gateway check does not probe $GATEWAY_PROBE: nothing maps the operator's bind to the address to probe")
    mapping = find(r'^\s*0\.0\.0\.0\)\s*GATEWAY_PROBE=127\.0\.0\.1\b', 0, answers)
    if mapping is None:
        note("no `0.0.0.0) GATEWAY_PROBE=127.0.0.1` arm before the gateway check: a bind on every address would be probed at http://0.0.0.0:4100")

# ---- 2. one address means loopback refuses -----------------------------------
refusal = find(r'^\s*\*\)\s*check "gateway is NOT on loopback"\s+"! curl [^"]*http://127\.0\.0\.1:4100/')
if refusal is None:
    if find(r'check "gateway is NOT on loopback"') is None:
        note('no `check "gateway is NOT on loopback"` in install.sh: a bind on one address is never shown to refuse loopback, so a gateway published wider than the operator decided reads as healthy')
    else:
        note('the "gateway is NOT on loopback" check is not a must-fail `! curl` against http://127.0.0.1:4100 in the `*)` arm: it does not say what it is meant to')
else:
    guarded_by_bind_case(refusal, 'the "gateway is NOT on loopback" check')

# ---- 3. the sysctl that lets the bind survive a reboot -----------------------
def command_at(idx):
    """The logical command the line at idx belongs to, continuation lines
    joined: back to its first line, forward to its last."""
    while idx > 0 and lines[idx - 1].rstrip().endswith("\\"):
        idx -= 1
    parts = [lines[idx]]
    j = idx
    while parts[-1].rstrip().endswith("\\") and j + 1 < len(lines):
        j += 1
        parts.append(lines[j])
    return " ".join(p.strip().rstrip("\\").strip() for p in parts)


sysctl_write = find(r"ip_nonlocal_bind = 1.*>\s*/etc/sysctl\.d/\S+\.conf")
if sysctl_write is None:
    note("install.sh never writes net.ipv4.ip_nonlocal_bind = 1 into /etc/sysctl.d/: a gateway bound to one address comes back from a reboot as Exited (128), and nothing retries it")
else:
    if "|| die" not in command_at(sysctl_write):
        note("the sysctl write into /etc/sysctl.d/ has no `|| die`: a box that could not be made to survive a reboot would look installed until it rebooted")
    applied = find(r"^\s*sysctl\s", sysctl_write)
    if applied is None or "|| die" not in command_at(applied):
        note("the sysctl file is written but not applied with `sysctl ... || die`: the setting would wait for the next reboot, which is the moment it was needed")
    guarded_by_bind_case(sysctl_write, "the sysctl write")

# ---- 4. docker after tailscaled, where tailscaled exists ---------------------
dropin = find(r">\s*/etc/systemd/system/docker\.service\.d/\S+\.conf")
if dropin is None:
    note("install.sh never writes a docker.service drop-in under /etc/systemd/system/docker.service.d/: docker starts before tailscaled holds the address it must bind")
else:
    cmd = command_at(dropin)
    for unit in ("After=tailscaled.service", "Wants=tailscaled.service"):
        if unit not in cmd:
            note(f"the docker.service drop-in does not carry {unit}: ordering docker after tailscaled is what a second reboot proved")
    if "|| die" not in cmd:
        note("the docker.service drop-in write has no `|| die`: a box that could not be ordered after tailscaled would look installed until it rebooted")
    guard = find(r"^\s*if\s.*tailscaled\.service", 0, dropin)
    if guard is None:
        note("the docker.service drop-in is written without checking that tailscaled.service exists: a Wants= on a unit that is not there fails docker.service itself")
    reload = find(r"^\s*systemctl daemon-reload\b", dropin)
    if reload is None or "|| die" not in command_at(reload):
        note("no `systemctl daemon-reload || die` after the docker.service drop-in: systemd would not read it until something else reloaded")
    guarded_by_bind_case(dropin, "the docker.service drop-in")

# ---- 5. the port mapping is read from docker, not from `Started` -------------
mapping = find(r'^\s*check "gateway has a port mapping"')
if mapping is None:
    note('no `check "gateway has a port mapping"` in install.sh: `Started` from `up -d` is believed, and on 2026-09-17 it was said of a container with no port mapping')
elif "docker port" not in command_at(mapping):
    note('the "gateway has a port mapping" check does not read `docker port`: it is not asking Docker about the port')

if find(r'^\s*case "\$GATEWAY_BIND" in\s*$') is None:
    note('no `case "$GATEWAY_BIND" in` block in install.sh at all: nothing branches on the operator\'s bind, so this gate measured nothing')

if problems:
    print(f"{len(problems)} problem(s)")
    print()
    print("GATEWAY_BIND is the operator's one address decision. A check that assumes")
    print("loopback reads a healthy appliance as broken. See CLAUDE.md invariant 11.")
    sys.exit(1)

print("OK: the gateway is probed on $GATEWAY_PROBE (0.0.0.0 mapped to loopback), a bind")
print("    on one address is shown to refuse loopback, gets ip_nonlocal_bind and a docker")
print("    drop-in after tailscaled or a refusal, and the port mapping is read from docker.")
PY
