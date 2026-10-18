# CLAUDE.md, working instructions for stack-single

These instructions apply to any model working in this repo. Read this file
before changing anything. It holds process and invariants only: **no status.**
Status goes stale, and a stale instruction file is worse than none.

## Read before you change anything

1. `README.md`, for what the installer promises an operator.
2. `install.sh`, in full, before editing any part of it. It is one file and it
   runs as root on somebody else's machine.
3. `GOTCHAS.md` in the sibling repo `TAIPANBOX/stack-k8s`. Most traps this
   installer can hit were already paid for there.

## What this is

The agent-governance stack on one machine: the same wiring stack-k8s proved on
a cluster, minus Kubernetes, as a curl-pipe-bash installer plus a compose file.
Public, Apache-2.0.

## Blast radius

This is a `curl | bash` installer that runs as root on a machine the operator
cares about. There is no undo, there is no dry run by default, and the person
running it has already decided to trust us before reading a line of it. Every
change here is a change to something with root on somebody else's box.

## The working loop

1. Branch off `main`, one logical increment per branch.
2. Run the gate below.
3. **Test the second run, not just the first.** See invariant 2.
4. Commit with Conventional Commits, ending with the standard co-author
   trailer.
5. Open a PR with `gh`. **Ask the user before merging.**

## Gates

```sh
./scripts/shell-lint.sh
./scripts/closed-by-default.sh
./scripts/fail-before-half-the-job.sh
./scripts/build-context-complete.sh
./scripts/manifest-is-true.sh
./scripts/record-is-not-on-the-bus.sh
./scripts/bus-has-a-writer.sh
./scripts/bind-is-honoured.sh
./scripts/apt-never-removes-docker.sh
./scripts/gateway-cache-is-off.sh
./scripts/declassify-is-keyed.sh
./scripts/run-budget-ceiling.sh
./scripts/chain-verifier-is-contained.sh
./scripts/bus-names-match-their-source.sh
./scripts/delegation-off-by-default.sh
./scripts/delegation-key-not-printed.sh
./scripts/delegation-dirs-are-split.sh
./scripts/felyx-through-the-gateway.sh
./scripts/env-sources-cleanly.sh
./scripts/delegation-key-reused-on-rerun.sh
./scripts/typed-data-mode.sh
./scripts/typed-risk-signal.sh
./scripts/finops-is-opt-in.sh
./scripts/closure-off-by-default.sh
./scripts/no-owner-quotes.sh
./scripts/firewall-is-enforce.sh
./scripts/pii-is-shadow.sh
./scripts/identity-files-are-checked.sh
./scripts/checks-survive-a-closed-pipe.sh
./scripts/gen-is-bounded.sh
./scripts/openai-door.sh
./scripts/features-are-bound.sh
./scripts/status-is-read-only.sh
./scripts/health-checks-are-declared.sh
./scripts/metered-doors-require-keys.sh
./scripts/broker-blocks-raw-secrets.sh
./scripts/wardryx-gateway-key-is-pep.sh
./scripts/network-membership.sh
./scripts/no-provider-key-outside-the-gateway.sh
./scripts/gates-have-teeth.sh   # invariant 8; needs a clean tree
```

The same list, in the same order, as `.github/workflows/gates.yml` runs. The
last one reaches the network, because what it checks lives in another
repository.

## Where the gates run

Two callers, one copy of each check: `.github/workflows/gates.yml` and
`.githooks/pre-push`. Never inline a check into either.

```sh
git config core.hooksPath .githooks   # once, per clone, for the local half
```

**Until 2026-08-01 the hook was the only caller, and that was a hole.**
`core.hooksPath` is local configuration: it is not committed and does not travel
with a clone, so these gates enforced nothing for anybody who cloned this repo.
CI is what makes them travel. This repo is public, so standard runners cost
nothing. `git push --no-verify` still skips the local half, and should be rare
enough to be worth explaining.

## Hard invariants

Each one carries how it is held today. Use `(gate: ...)`, `(test: ...)`,
`(partly gated: ...)` or `(not enforced)`, and use the weakest one that is
true. An invariant with no check, written as though it had one, is worse than
an absent invariant.

1. **The stack comes up closed.** `GATEWAY_BIND` defaults to `127.0.0.1` and
   the console is on loopback. Publishing a service beyond the host is the
   operator's decision, made explicitly, never a default. A default that
   exposes is a security decision taken on somebody else's behalf.
   *(gate: `scripts/closed-by-default.sh`)*
2. **The second run is the real test: works twice, from empty, untouched.** An
   installer that succeeds once and cannot be re-run is a demonstration, not a
   deployment. Every failure this project has had in this area was a step that
   was correct once and impossible twice. *(not enforced)*
3. **A verification check must be able to fail.** The installer's own checks
   have to be shown catching a broken stack, otherwise a green install reports
   silence rather than health. *(not enforced)*
4. **Never assume GNU beyond what the preflight has already guaranteed.** The
   premise here is narrower than it reads: `install.sh` refuses anything that is
   not Debian or Ubuntu, at line 64, before it touches the machine. Inside that
   fence GNU coreutils are a fact, not an assumption. The rule binds anything
   that runs OUTSIDE the fence, and it binds the day the fence is widened.
   *(partly gated: `scripts/fail-before-half-the-job.sh` holds the fence itself,
   failing if the distro refusal is removed. Nothing checks the portability of
   code added outside it.)*
5. **Every file an image copies is a file this installer fetched.** The
   Dockerfiles come from `TAIPANBOX/stack-k8s`, which does not know this
   consumer exists, so a change there breaks an install here with nothing in
   this repository having changed and neither side's CI seeing it. That is not
   hypothetical: `wg.Dockerfile` grew a `COPY images/uapi-proxy`, a directory,
   and a clean `curl | bash` died ten minutes in on a cache-key error. The
   fetch is a whole tarball now rather than five raw URLs, because a tarball
   cannot drift file by file.
   *(gate: `scripts/build-context-complete.sh`, verified by hiding
   `images/uapi-proxy` and watching it name that exact file. It judges paths
   under `images/` only: build ARGs, globs and the sibling repositories this
   installer clones are things it cannot judge, and its first draft reported
   eleven failures on a tree that builds perfectly.)*
6. **Fail before doing half the job.** Check preconditions up front and refuse,
   rather than starting and leaving the machine in a state neither installed nor
   clean. *(gate: `scripts/fail-before-half-the-job.sh`, which requires every
   refusal to precede the first side effect, and every fetch, clone and service
   start to carry `|| die`)*

8. **A check must be able to tell "did not fail" from "did not run", and every
   gate here has been made to fail on purpose to prove it can.** This
   repository is one of the two where writing the harness found a real hole
   rather than confirming a sound gate.

   `build-context-complete.sh` printed "OK: 0 build-context path(s) across 5
   Dockerfiles, every one present" and exited 0 when no COPY or ADD source
   matched the `images/` prefix. The count is already only 1, so ONE Dockerfile
   refactor in stack-k8s empties this check without touching this repository at
   all. That seam, between two repositories neither of which knows the other
   exists, is the exact thing the gate was written for, and it would have gone
   on reporting every path present while checking none.

   None of the four gates here said anything about measuring nothing before
   2026-08-09, which is why all four were checked by hand for that property
   rather than trusted.
   *(gate: `scripts/gates-have-teeth.sh`, 176 cases (`@measured SRC=~/Development/stack-k8s
   ./scripts/gates-have-teeth.sh` in a clean checkout of this branch 2026-10-04,
   `OK: 176 cases`, exit 0; this line said 11 for a long time after that stopped
   being true, so the last line the script prints is the figure to trust). The
   first eleven were six real faults, one non-fault and four subjects taken
   away. Two cases mutate the stack-k8s TREE
   rather than this repo, because that is what the gate reads; the tree is
   resolved once per run, the same three ways the gate resolves it, so a run
   costs at most one fetch. Verified on both paths: with a sibling checkout,
   and in a worktree with no sibling, which is what CI does.)*

   **What it does not cover.** It cannot test itself. It proves each gate
   catches the faults named in it, not every fault of that kind.
   `shell-lint.sh` has only a non-fault case: its subject is `install.sh` by
   name, and a missing `install.sh` makes shellcheck itself fail, which is not
   a property of the gate.

9. **The record reads the bus and writes somewhere else.** `events` is a bus:
   four components append to it, anything may read it, and an operator clearing
   disk space deletes from it. The record plane writes a hash-chained store of
   sealed segments whose whole value is that nobody can quietly change what it
   says. Keeping that store on the bus's own volume means an operator tidying
   up the bus deletes the evidence about it, and nothing looks wrong while it
   happens: the stack comes up, the seal runs, the pack verifies.

   So `record-seal` mounts `events` READ ONLY, writes the separate `records`
   volume, and is the only writer of it. The last part is not tidiness: the
   store takes no cross-process lock, so a second writer is two minters of one
   shard. The cluster gets the same property from `concurrencyPolicy: Forbid`
   on its CronJob; here it is one container running one serial loop.

   The profile is off by default, like `egress`. `WITH_RECORD=1 ./install.sh`
   builds `stack/trailryx:dev`, and `docker compose --profile record up -d
   record-seal` starts it.
   *(gate: `scripts/record-is-not-on-the-bus.sh`, which also refuses to report
   OK when there is no `record-seal` service left to judge)*

10. **The bus has a writer, and every volume a non-root service writes has an
    owner.** Two faults of one shape were live on every install until
    2026-09-13 and passed every check. The gateway had no
    `TOKENFUSE_EVENTS_PATH`, so its exporter was off, the file init-volumes
    pre-creates for idryx stayed at 0 bytes, idryx loaded an empty log, heraldyx
    had nothing from the money plane and the record sealed none of it. And
    init-volumes chowned `/vol/records` without mounting `records`, and did
    nothing for `scopyxevents` or `focus`, so on a fresh box scopyx crash-looped
    on "permission denied", record-seal ran and stored nothing while printing
    "nothing sealed here to pack yet", and focus-export could not write a CSV.
    A fresh named volume is root:root 0755; a service that is not root cannot
    write it until something says who owns it.

    So `tokenfuse-gateway` names its events file inside a volume it mounts
    read-write, every `--load tokenfuse:` in compose.yaml names that same file,
    and every named volume a non-root service mounts read-write is mounted by
    `init-volumes` and given to that uid or gid there. install.sh section 8
    reads the gateway's own "export enabled" line, because on a fresh box the
    file is legitimately empty and its size proves nothing.

    The control plane is the second writer of the same bus and had the same
    fault until 2026-09-17 (#57): no `TOKENFUSE_EVENTS_PATH`, so a budget gone
    and a sustained loop stayed inside `/v1/incidents`, unseen by the notifier
    and the record. And naming the file is not enough for either tokenfuse
    image: they run as uid 10001 with gid 999, which cannot CREATE a file in
    the `root:10001 2775` events directory, and the exporter swallows the open
    error. So each money-plane writer names its own file, and `init-volumes`
    pre-creates both by name, owned by that uid.

    Since invariant 32 the box can run a second gateway, the OpenAI door, so
    "the gateway's file" reads "a file some gateway writes": every service that
    runs the gateway image with no subcommand is a writer, no two writers name one
    file (two gateways on one chained file fork its chain), `init-volumes`
    pre-creates each one, every `--load tokenfuse:` names a file some gateway
    writes, and every reader that loads the gateways' log loads each gateway's
    file, so idryx and `idryx-detect` load `tokenfuse-openai.ndjson` on every box
    (empty unless the door runs).
    *(gate: `scripts/bus-has-a-writer.sh`, which refuses to report OK when the
    gateway, init-volumes, or every writable volume has been taken away, and
    derives the gateways from their image and command lines rather than naming
    them; teeth in `scripts/gates-have-teeth.sh`)*

11. **The operator's bind is honoured end to end.** `GATEWAY_BIND` is the one
    address decision an operator makes here, and every check that depends on
    it reads it rather than assuming loopback. Check 1 probed
    `http://127.0.0.1:4100/healthz` whatever the variable said, so a box whose
    gateway was published on its tailscale address only, the shape an
    appliance wants, exited 1 on two runs while every other check passed and
    the same probe against that address answered 200 (#54, 2026-09-17).

    So the probe goes to `$GATEWAY_PROBE`, which is the bind with `0.0.0.0`
    mapped to loopback (every address includes it), and when the bind is ONE
    address the run also shows loopback REFUSING, a check that must fail to
    pass like the "NOT on the host" ones: a gateway that answers on an address
    the operator did not name is published wider than they decided.

    The same bind has to survive a reboot, and on that box it did not (#56):
    docker.service became active two seconds after tailscaled, before
    tailscale0 carried the address, the gateway's bind failed, the container
    ended `Exited (128)`, and `unless-stopped` never retries a start that
    failed. A later `up -d` said `Started` of a container with no port
    mapping. So for a bind that is one address the installer writes
    `net.ipv4.ip_nonlocal_bind = 1` into `/etc/sysctl.d/` and applies it, and
    where `tailscaled.service` exists a `docker.service` drop-in with
    `After=` and `Wants=tailscaled.service`, each with `|| die` (a box that
    looks installed until its first reboot is invariant 6's half-install),
    and section 8 reads the gateway's port mapping from `docker port` on the
    container rather than believing `Started`. Proven by a second reboot on
    that box: published, healthz 200, within 40 s.

    The probe follows the bind the box HAS, not the one this run was given.
    `@claude 2026-10-13`: `GATEWAY_PROBE` was worked out once, at the top of
    `install.sh`, before `.env` is read, and a re-run sources `.env` over the
    run's own default (the README's way to change the bind on an installed box is
    to edit `GATEWAY_BIND` there). So with nothing in the environment, check 1
    probed loopback on a healthy box whose gateway is published on one other
    address, and `TOKENFUSE_DELEGATION_URL` would have been minted from the same
    stale value on a re-run that first enables delegation. @measured `install.sh`
    v1.1.32 re-run on a Debian 13 box whose `.env` holds `GATEWAY_BIND=192.168.1.10`,
    2026-10-13: `FAIL gateway answers on 127.0.0.1:4100` with no `GATEWAY_BIND` in
    the environment, `ok gateway answers on 192.168.1.10:4100` with it exported,
    `curl http://192.168.1.10:4100/healthz` 200 throughout. So the mapping is one
    function, `gateway_probe_resolve`, called at the top and again on the next line
    of code after every `. ./.env`, and nothing else assigns `GATEWAY_PROBE`.
    *(gate: `scripts/bind-is-honoured.sh`, which refuses to report OK when the
    gateway check or the `case "$GATEWAY_BIND"` block is gone, and requires the
    single assignment, the call before the first read of `.env`, the call after
    every read of it, and runs the lifted function for loopback, `0.0.0.0`, an
    address and two IPv6 literals and across a `.env` that names another bind;
    `scripts/delegation-key-reused-on-rerun.sh` runs the real slice of `install.sh`
    over a `.env` naming `192.168.1.10` and requires the delegation origin to
    follow it; teeth in `scripts/gates-have-teeth.sh`; scenarios in
    `features/the-install-report-matches-the-box.feature`)*

12. **The package step never takes Docker away, and never asks apt for what
    the box already has.** On Debian 13 with Docker CE installed, the line
    this installer ran on any box that already had docker,
    `apt-get install docker-buildx`, resolved to `Remv docker-ce` and `Remv
    docker-ce-cli`: the distro's buildx depends on Debian's `docker-cli`,
    which conflicts with Docker's own (#55, measured 2026-09-17 with
    `apt-get install -s`). The box already had buildx, as
    `docker-buildx-plugin`. Every earlier run was on Ubuntu with no Docker
    present, where the line is harmless, which is how an installer that
    removes Docker shipped.

    So every `apt-get install` here carries `--no-remove`, which makes such a
    resolution an error rather than a removal whatever a distro's dependency
    graph says this year; buildx is asked for only when `docker buildx
    version` fails; and on a Docker CE box it is asked for from Docker's own
    repository, as `docker-buildx-plugin`.
    *(gate: `scripts/apt-never-removes-docker.sh`: the static half reads every
    apt line, the behavioural half runs the package step under stub `apt-get`,
    `docker` and `dpkg` and reads back what apt was asked for; it refuses to
    report OK when no apt line or the step's anchors are left; teeth in
    `scripts/gates-have-teeth.sh`)*

13. **The gateway's semantic cache is off, explicitly.** @decided 2026-09-24:
    the launcher turns the tokenfuse gateway's semantic response cache off by
    name, because its shadow-mode default serialises every call behind one
    lock while it walks the whole cache computing cosine similarity and serves
    nothing (tokenfuse#319). Every compose service that runs the gateway
    binary with no subcommand carries `TOKENFUSE_CACHE: "off"`.
    *(gate: `scripts/gateway-cache-is-off.sh`, subjects derived from
    compose.yaml's own image and command lines, not a hard-coded service name;
    refuses to report OK when no such service is left to judge; teeth in
    `scripts/gates-have-teeth.sh`)*

14. **The typed plane's bus writer and its network door are each closed the
    same way an existing door already is, not by a second mechanism to keep
    in sync.** @decided 2026-09-26: `typryx`'s journal moves onto the shared
    `events` volume now that agent-passport registers its four event types
    (typed_answer, typed_unanswered, typed_refused, calibration_drift), so
    heraldyx can alert on them; `record-seal` counts all four refused rather than
    sealed: they carry agent-event v1.0, a schema trailryx 1.0 does not read
    (unknown_schema), and past the schema its mapper refuses the four by name
    on purpose (trailryx#81).
    `tokenfuse-mcp-broker`, a new opt-in service fronting `typryx` by
    configuration alone (tokenfuse's own code is not touched), publishes on
    `${GATEWAY_BIND:-127.0.0.1}:4200`, the identical expression
    `tokenfuse-gateway` publishes 4100 on, so a box that never widened
    `GATEWAY_BIND` never widens this door either, and there is no second bind
    variable to forget. It sits behind the same `typed` profile as `typryx`
    itself, off by default; `TOKENFUSE_MCP_KEYS`, generated by `install.sh`
    like every other key here, is the credential a caller must present, and
    this launcher never sets `TOKENFUSE_MCP_ALLOW_OPEN_BIND`.
    *(gate: `scripts/bus-has-a-writer.sh`, invariant 10 above, extended to
    typryx's own `TYPRYX_EVENTS` writer; teeth in `scripts/gates-have-teeth.sh`.
    The broker's own port line reusing `${GATEWAY_BIND:-127.0.0.1}` is not
    separately checked, the same as every other service's own `ports:` line
    beyond the gateway's, which invariant 1 leaves to `closed-by-default.sh`'s
    one subject; *(not enforced)* for the broker specifically. install.sh's
    own end-of-run checks, only when the broker is running, prove the broker
    reaches typryx for a `tools/list` and refuses a `tools/call` with no
    client key. They also prove an actual typryx answer through the broker:
    `an ask through the broker is answered` sends an `ask` whose key travels
    only as `{{secret:typryx_key}}` and requires `"isError":false` in the body.
    It needs typryx v0.2.0 or later (`_meta` credential reading is typryx#6).
    @measured live on this Mac, 2026-09-26, against the compose project with
    the broker's own network: green on typryx v0.2.0, red on v0.1.0, red with
    a wrong broker key, red with typryx stopped)*

15. **The delegation plane is off by default, and enabling it needs a real
    trusted issuer, never an invented one.** `@decided 2026-09-27`: the
    launchers offer vouchryx as an opt-in delegation plane, off by default,
    so a gateway can verify a proved delegation chain instead of trusting a
    claimed one. A default install carries no `vouchryx` service and every
    `TOKENFUSE_DELEGATION_*` variable on the always-on gateway defaults to
    empty, which is the value tokenfuse's own chainproof reads as off.
    `WITH_DELEGATION=1 ./install.sh` needs either the operator's own
    `VOUCHRYX_TRUSTED_ISSUERS` or the explicit, clearly-labelled
    `WITH_DELEGATION_DEMO_ISSUER=1` (never a production posture); with
    neither, install.sh refuses before anything starts, naming what is
    missing. The signing key and the revocation key are minted once, into
    files this launcher owns, never printed, and reused on every later run.
    vouchryx is never published to the host: the gateway reaches it, and
    polls its revocations, over the compose network only. `./delegation`
    (the signing key) belongs to vouchryx's uid 65532 and is mounted into
    vouchryx alone; the gateway reads the served JWKS from
    `./delegation-public`. A bind mount keeps host ownership, so on Linux a
    root-owned 0700 directory stops both containers (measured 2026-09-27 on
    Debian 13: both exited 2); Docker Desktop on macOS hides it.
    *(gate: `scripts/delegation-off-by-default.sh`, `scripts/delegation-key-not-printed.sh`,
    `scripts/delegation-key-reused-on-rerun.sh`, `scripts/delegation-dirs-are-split.sh`;
    teeth in `scripts/gates-have-teeth.sh`)*

16. **Felyx, the console's copilot, reaches its model through this box's own
    gateway, by default.** `@decided 2026-09-27`: the launchers route Felyx
    through the stack's gateway by default, with its agent id in the trust
    domain. The console points it at `http://tokenfuse-gateway:4100` by
    service name, allow-lists that one name for its residency check
    (`GENARYX_COPILOT_LOCAL_HOSTNAMES`, genaryx invariant 14, console v1.1.17
    on), and names it `agent://${RECORD_TRUST_DOMAIN:-local}/genaryx/felyx`, so
    its calls are priced, budgeted and policy-checked like any agent's. No key
    ships: `GENARYX_COPILOT_KEY` in `.env` turns it on; without it Felyx says
    it is not configured. Nothing sets `GENARYX_COPILOT_ALLOW_REMOTE`. Measured
    2026-09-27 on a Linux Docker network with console v1.1.17 and a stub
    gateway: Felyx reported `local: true` and its question reached the gateway;
    without the allow-list it refused the endpoint.
    `@decided 2026-10-13` (paraphrased): the console gains an optional setting
    naming a gateway client key Felyx sends as `x-fuse-key` (genaryx invariant
    24), and this launcher passes it through. compose.yaml hands the console
    `GENARYX_COPILOT_FUSE_KEY_REF: env:GENARYX_COPILOT_FUSE_KEY` and
    `GENARYX_COPILOT_FUSE_KEY: ${GENARYX_COPILOT_FUSE_KEY:-}`: the key comes from
    `.env`, empty unless an operator gives Felyx one, never written into
    compose.yaml and never required. The operator gives Felyx its own line in
    the keys file and, with a map, a `keys[]` binding whose `agents` include
    Felyx's agent id (README, "Client keys and the identity map"). A console
    that does not read the reference ignores both lines.

    The closing report says which of the two the box has. `@claude 2026-10-13`:
    with client keys on and `GENARYX_COPILOT_KEY` set, `felyx_gateway_note` prints
    one of two notes. With `GENARYX_COPILOT_FUSE_KEY` set, Felyx presents it, and it
    has to be one of the keys and, with a map, bound to Felyx's agent id; empty,
    Felyx sends none and its calls are refused 401. The report used to say "sends no
    key" on both, including on a box that had given Felyx one. @measured two
    throwaway consoles `ghcr.io/taipanbox/genaryx-console:v1.1.44` on a Debian 13 box
    against its gateway with client keys on, 2026-10-13: with
    `GENARYX_COPILOT_FUSE_KEY` set to a key the gateway holds, `copilot_ask` answered
    HTTP 200 in 1611 ms; with it empty, it returned the gateway's 401 `unauthorized`
    ("requires a client credential in the `x-fuse-key` header").
    *(gate: `scripts/felyx-through-the-gateway.sh`, which also lifts
    `felyx_gateway_note` out of `install.sh` and runs it for a Felyx with a key, one
    without, client keys off and no provider key, and requires that it never prints
    the key; teeth in `scripts/gates-have-teeth.sh`, three of them for the key and
    five for the note; `features/felyx-presents-its-own-client-key.feature`. Not
    covered by a gate: a console presenting the key to a live gateway, which needs a
    running stack and was measured by hand once (above). The console pinned here
    (v1.1.45) carries genaryx invariant 24: @measured
    `git merge-base --is-ancestor 60ade51 d994ce5` in the genaryx checkout, 2026-10-13, exit 0,
    and `git merge-base --is-ancestor 60ade51 fd7a1ab` in the same checkout, 2026-10-14, exit 0,
    where fd7a1ab is the source label of v1.1.45.)*
    `@claude 2026-10-17`: since invariant 35 a box given no keys file mints
    `GENARYX_COPILOT_FUSE_KEY` and binds it to Felyx's id alone, and the closing
    note says the key is minted and bound rather than asking the operator to do it.

17. **The installer is run for real on every change, first install and
    re-run.** Every script gate here reads files; from v1.1.9 to v1.1.12 every
    install stopped at `. ./.env` (exit 127, an unquoted `|` in a default)
    while all of them stayed green, because nothing ran install.sh on a real
    box after the line went in. `.github/workflows/install.yml` runs it twice
    on a fresh Ubuntu runner, with the default profile, with the delegation
    profile and with the typed risk signal on (the stub backend), and requires
    "every check passed" both times.
    *(gate: `.github/workflows/install.yml`; red on a branch re-planting the
    unquoted default, 2026-09-27)*

18. **Typed answers come from the place the operator chose, and nothing is
    chosen for them.** `@decided 2026-09-30`: `TYPED_MODE` is `jev`,
    `own-model` or `off`, and off is the default, so a default install has no
    typryx, exactly as before. `WITH_TYPED=1` with no `TYPED_MODE` is unchanged:
    typryx on its stub backend, which makes no outbound call. `@claude
    2026-10-15`: that choice is written to `.env` as `TYPED_MODE='stub'`, and a
    re-run with nothing set keeps it; until then a plain re-run read no mode and
    turned the plane off, so the README's promise that a box keeps its mode was
    false for the stub. Only `TYPED_MODE=off` turns the stub off. `jev` needs
    `TYPED_JEV_KEY_FILE`, the PATH of a file holding the key; `own-model` needs
    `TYPED_MODEL_URL` (ending in `/v1`) and `TYPED_MODEL_NAME`. A missing input
    refuses in section 0b, before a package is installed or a file written, and
    a refusal never echoes what it was given (a key pasted where the path goes
    is not printed). A key is only ever a FILE: install.sh copies it into
    `./typed` (0400, uid 65532), compose mounts that directory read only at
    `/run/typed`, and `.env` and `docker compose config` name the path inside
    the container, never the bytes. It is not an environment value, it is not
    printed and it is not logged. A re-run with nothing set changes nothing; a
    run that sets a mode replaces the previous mode's lines rather than adding
    to them. `jev` is left unpriced because no prices are wired anywhere else
    here, and the installer's own ask-through-the-broker check is skipped in
    `jev` mode because it would spend at TypeSafe on every run.

    The local training log follows the same rule of nothing chosen for them.
    `@decided 2026-09-30`: typryx v0.3.0 (the pin here since 2026-09-30) can
    keep an opt-in training log, `TYPRYX_TRAINING_DIR`, and it is off by
    default. `TYPED_TRAINING=1` writes `TYPRYX_TRAINING_DIR=/var/lib/typryx/training`
    into `.env`: a directory inside the `typryxdata` volume, mounted writable,
    on the same volume as the ledger (`TYPRYX_LEDGER_DIR`), because
    `typryx export --training` pairs the log with the human truths the ledger
    holds. Nothing set writes no line, so a default install's `.env` and its
    resolved compose config are what they were (the typed profile's own render
    gains one empty `TYPRYX_TRAINING_DIR: ""` line, which typryx reads as
    unset). It is independent of the mode and survives a change of mode;
    `TYPED_TRAINING=0` turns it off; `TYPED_TRAINING=1` with typed answers off,
    or a value that is neither 1 nor 0, refuses before the box is touched. The
    export carries human truths only, so a Jev answer cannot become a training
    label (TypeSafe's terms), and the data stays in the volume on the box.
    Every typryx image pin here is the one tag compose.yaml defaults to.
    *(gate: `scripts/typed-data-mode.sh`, which lifts the `# typed-mode:` block
    out of install.sh and runs it in a scratch directory for each case, reads
    `docker compose config` for the default, stub, jev and own-model, and
    requires `--profile typed` only on a line `TYPED_PLANE` decides, and, for
    the training log, runs the block for off, on, re-run, mode switch, 0 and the
    refusals, reads the resolved config for a writable volume under the
    training dir beside the ledger, and requires every `typryx:vX.Y.Z` in
    compose.yaml, components.json, README.md and install.sh to be the one pin (v0.4.1
    since 2026-10-14; v0.4.0 from 2026-10-04, the release the risk-signal proxy needs;
    v0.3.0 was the first with the training log); it
    refuses to report OK on no block, no profile line, no typryx image or no
    Docker; teeth in `scripts/gates-have-teeth.sh`. Not covered: a real
    `install.sh` run on Debian in any typed mode, and the interactive prompt,
    which needs a terminal and is read, not run. @measured live on this Mac,
    2026-09-30 (Docker Desktop, compose project `typryxtrain`, the repo's own
    compose.yaml and the installer block's `.env`, typryx
    `ghcr.io/taipanbox/typryx:v0.3.0`, Ollama qwen2.5:7b): an ask carrying an
    extra `user_email` was answered with `held_back_fields` 1, a truth posted
    to `/v1/outcome`, and `docker compose exec -T typryx typryx export
    --training` wrote one row with only the template's fields and the posted
    label, no email; the training directory was 0700 and its file 0600.)*

19. **The gateway's declassify key is minted per install, and only the operator
    holds it.** `@decided 2026-10-04` (estate audit, wave 1): the tokenfuse
    gateway's `POST /v1/fuse/declassify` lifts a run's taint label, the release
    valve for its agent firewall. It is not behind `TOKENFUSE_ADMIN_KEYS`; its
    own credential, `TOKENFUSE_DECLASSIFY_KEY` (presented as
    `x-fuse-declassify-key`), is optional in the gateway, and with it unset
    anything that can reach the gateway port can clear a run, recorded only as
    `authenticated: false`. This launcher publishes that port on the operator's
    chosen bind and set no key. `install.sh` now mints `GATEWAY_DECLASSIFY_KEY`
    with `gen 40` into `.env` (0600, added by `add_env_default`, so an existing
    install gets it on the next run and a credential already there is never
    rewritten), compose passes it to the gateway as `TOKENFUSE_DECLASSIFY_KEY:
    ${GATEWAY_DECLASSIFY_KEY:?...}`, and the closing report says the key lives
    in `.env` and that clearing a run needs it, never printing the value. Nothing
    in this estate calls the endpoint, so minting a key closes it by default and
    breaks nothing. The reader of the variable is tokenfuse's `declassify.rs`,
    declared in its `components.json`.
    *(gate: `scripts/declassify-is-keyed.sh`, subjects derived from compose.yaml's
    own image and command lines like invariant 13's; it requires the value to be
    a `${VAR:?...}` interpolation (a literal or a `:-` default fails) and
    install.sh to mint that same VAR with `gen`; refuses to report OK with no
    gateway service or no install.sh to read; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: that a running gateway actually
    refuses a call with no key, which needs a live install, and that the key is
    kept from the agent, which is the operator's own custody of `.env`.)*

20. **A run's budget has an operator's ceiling, on every gateway.**
    `@claude 2026-10-04`, from the estate audit's launcher spec (wave 1): a run's
    budget used to be whatever the agent said in `x-fuse-budget-usd`, widened
    again by its next call, so on a box with no client keys and no identity map
    the per-run limit was the agent's own word. tokenfuse 1.5.0 (its invariant
    73) clamps a budget that came from that header, a policy default or its
    built-in default to `TOKENFUSE_MAX_RUN_BUDGET_USD`, and is OFF unless that is
    set; its release notes say the launchers do not set it yet. Every compose
    service that runs the gateway binary with no subcommand sets it from one
    installer variable, `${RUN_BUDGET_CEILING_USD:-5.00}`. `@claude 2026-10-04`:
    the default 5.00 equals tokenfuse's own `DEFAULT_RUN_BUDGET`
    (`crates/gateway/src/proxy.rs`), so an ordinary run is unchanged and only a
    caller-declared larger budget is clamped. It is not on the Cloud budget:
    tokenfuse does not clamp a budget the Cloud sets, which is the operator's own
    word. It bounds one run, not an agent: a new run id gets a new ceiling's
    worth. `install.sh` checks a figure (a positive number of dollars, at most six
    decimals, the one form tokenfuse reads; it exits 2 on anything else) before a
    package is installed, whether it came from the run's environment or was left
    in `.env`, never echoes a refused value, and replaces the `.env` line rather
    than adding a second; section 8 reads the gateway's own start-up line, so a
    gateway older than 1.5.0 turns the check red. @measured `scratch compose
    project from this compose.yaml on Docker Desktop, TOKENFUSE_UPSTREAM pointed
    at a local python stub, wget with x-fuse-budget-usd` 2026-10-04: a declared
    budget of 100 came back with `x-fuse-budget-clamped: 5.00`, a declared 1 and 5
    without the header, and with `RUN_BUDGET_CEILING_USD=2.50` in `.env` a
    declared 5 came back `2.50`.
    *(gate: `scripts/run-budget-ceiling.sh`, subjects derived from compose.yaml's
    own image and command lines like invariant 13's; it lifts the
    `# run-budget-ceiling:` block out of install.sh and runs it per case, reads
    `docker compose config` for 5.00 and for 2.50, and refuses to report OK on no
    gateway, no block or no Docker; scenarios in
    `features/the-run-budget-ceiling.feature`; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: a live call against a real model
    provider, and the clamp on the `cluster` feature.)*

21. **The on-box chain verifier reads every stream and writes exactly one file.**
    `@claude 2026-10-04`, from the estate audit's launcher spec (wave 1): until
    agent-stack-go#66 nothing on a box checked the `prev_hash` chain of the
    shared bus, and a flipped byte went unseen on the 2026-09-17 appliance run.
    `agent-conform watch-dir -every 5m` is a compose service, on by default (it
    spends nothing and a bus nobody verifies is the fault). Its stream
    `agent-conform.ndjson` has to be on the bus for heraldyx to read, so the bus
    is mounted read-write, and compose cannot mount one file of a named volume:
    the account is the whole containment. It runs `10002:10002`, outside both uid
    families (10001, 65532) and outside the bus group (10001), with no
    `group_add` ever; the bus directory is `root:10001 2775` and the other
    planes' files are 0664 owned by 10001, so it reads through the "other" bits
    and can write nothing it does not own and create nothing. `init-volumes`
    pre-creates its stream and gives it to that uid alone, 0644; its state file
    is on its own volume, `conformstate`, never inside the directory it walks
    (it would be read as a stream and an operator clearing the bus would
    delete it and re-send every alert). It is read-only, drops every capability
    and runs one pinned tag. section 8 asks a throwaway busybox run as that uid
    that it CAN append to its own stream and CANNOT write another plane's or
    create a file (the last two must fail to pass), and that the verifier is
    running and has read the bus. @measured `scratch compose project, the
    verifier as 10002:10002 against the live volume` 2026-10-04: its first pass
    printed a line for each of seven streams; busybox as 10002 appended to
    `agent-conform.ndjson`, was refused on `wardryx.ndjson` and refused creating
    a file; one byte flipped in `wardryx.ndjson` produced `FAIL wardryx.ndjson:2:
    chain break` and one `chain_broken` (high) line in `agent-conform.ndjson`
    written by that uid; heraldyx v0.3.0 with file delivery mailed it as `[box]
    agent://agent-conform.internal/verifier: chain_broken`, body "raised an event
    this build does not have a description for", kind `prev_hash_mismatch`:
    neutral wording that names neither the stream nor the line (a finding for
    heraldyx, not fixed here).
    *(gate: `scripts/chain-verifier-is-contained.sh`, subject derived from the
    image name; `scripts/bus-has-a-writer.sh` treats a file `init-volumes` gives
    to a service's uid as an owner of that volume for it; scenarios in
    `features/the-chain-verifier-is-contained.feature`; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: a break on a long-running live
    bus, a forged line that chains correctly, truncation from the end of a file,
    and what `record-seal` makes of the verifier's schema.)*

22. **The typed risk signal is off unless asked, and the network holds its proxy.**
    `@claude 2026-10-04`, from the estate audit's launcher spec (wave 1), whose
    J2 design records as decided that a signal may hold a tool call for a person
    and never deny it: wardryx 1.2.0 reads typed signals on `/v1/decide` and its
    `hold_if_signal` rule can turn an allow into a hold; typryx 0.4.0's
    `wardryx-proxy` asks `action.risk_class` about a tool call and adds the
    answer. `TYPED_RISK_SIGNAL=1` turns it on, only with typed answers on (any
    mode but off, the stub included) and refused otherwise, naming what to set,
    before the box is touched; it is independent of the mode and survives a
    change of mode; `TYPED_RISK_SIGNAL=0` removes its three `.env` lines. On, it
    starts `typryx-wardryx-proxy` (profile `typed-risk-signal`, the typryx image
    the typed plane pins) and points ONLY the MCP broker's policy client
    (`TOKENFUSE_WARDRYX_URL`, mode `enforce`, fail `closed`) at it; the LLM
    gateway keeps asking wardryx directly, because a model call has no pending
    tool call and typryx's latency does not belong in front of a 250 ms
    deadline. The broker's decide deadline is 7000 ms and the proxy's ask
    deadline 3000 ms (`TYPED_RISK_ASK_TIMEOUT_MS`, at most 5000): typryx's own
    150 ms default is shorter than a hosted model answers and the signal would
    almost never arrive. Nothing seeds a `hold_if_signal` policy. The README's one
    example carries `when_absent: hold` (`@claude 2026-10-14`, wardryx 1.4.0): a
    tool call that arrives with no `action.risk_class` signal is held for a person
    rather than passed. Without it the broker sends a call over 12 KiB with no
    arguments and no signal, so padding past the cap was a bypass. Under
    single-use (`WARDRYX_APPROVAL_SINGLE_USE` unset, the default) one approval
    lets exactly one padded call through. `@claude`: the
    broker was NOT a policy enforcement point on this launcher before (it never
    set `TOKENFUSE_WARDRYX_URL`; since invariant 36 it is one on every box, and the
    signal changes only where it asks), so turning the signal on makes every tool call
    subject to the operator's whole `policy.yaml`, requires `x-fuse-agent-id`
    (@measured `wget` through the broker of a scratch compose project with the signal on, 2026-10-04: no header came back `400 Bad Request`, with the header the call was answered) and fails closed. The proxy
    runs open on purpose: with `TYPRYX_KEYS` it demands an `X-Typryx-Key` the
    broker cannot send. So its protection is the network: `risk-signal` holds the
    proxy, the broker and wardryx and nobody else, the proxy is on that network
    alone and publishes nothing, and install.sh checks it is reachable from there
    and from nowhere else (the last two must fail to pass). It names no journal
    or ledger (a second typryx appender, and a file name the source rule would
    refuse). @measured `scratch compose project from this compose.yaml, stub
    backend, busybox on each network` 2026-10-04: the proxy answered `/healthz`
    from `risk-signal` (wardryx's, forwarded) and was a bad address from
    `default`; an MCP `tools/call` with `x-fuse-agent-id` through the broker was
    answered and wardryx's `policy_allow` event carried
    `signals:[{name:action.risk_class,source:typryx,value:read_only,...}]`; with
    a `hold_if_signal` rule for the stub's value the same call was refused
    `requires approval (approval ap_...)` and wardryx wrote `approval_requested`.
    *(gate: `scripts/typed-risk-signal.sh`, which lifts the `# typed-mode:` block
    and runs it per case, reads `docker compose config` for the proxy's
    network, ports, key, upstream and members, the broker's and the gateway's
    URLs, requires typryx 0.4.0, wardryx 1.2.0 and tokenfuse 1.5.0 or later,
    wardryx 1.4.0 or later for the README's `when_absent: hold`, no seeded
    `hold_if_signal` and one in the README that carries `when_absent: hold`, and
    refuses to report OK on no
    block, no proxy or no Docker; scenarios in
    `features/the-typed-risk-signal.feature`; teeth in
    `scripts/gates-have-teeth.sh`; CI's third install leg runs it for real on
    the stub. Not covered: a real backend (no signal measured from Jev or an own
    model), the signal under load, and `install.sh` on Debian by hand.)*

23. **Every stream file on the bus is one heraldyx and idryx accept for its
    writer's source.** `@claude 2026-10-04`, from the estate audit's launcher
    spec (wave 1): heraldyx 0.3.0 and idryx 1.1.0 refuse an event whose `source`
    the file it came from may not carry, and say so once; nothing fails loudly
    and a plane's alerts just stop. The default is `<source>.ndjson` carries
    `<source>` for the fourteen registered sources, plus `tokenfuse-cloud.ndjson`
    and `tokenfuse-mcp.ndjson` carrying `tokenfuse`. Every file this launcher
    writes already matches, so no stream was renamed and `HERALDYX_STREAMS` and
    `IDRYX_STREAMS` stay unset: the repair for a mismatch is a rename, and a
    declaration widens what the box takes from anything that can create a file
    in the bus directory. @measured `heraldyx v0.3.0 -once over a scratch bus, file
    delivery` 2026-10-04: with real events on `tokenfuse.ndjson`,
    `tokenfuse-cloud.ndjson`, `tokenfuse-mcp.ndjson`, `typryx.ndjson`,
    `wardryx.ndjson` and (an earlier run) `agent-conform.ndjson` it raised the
    expected notices and no `foreign_source` or `unknown_stream`, and idryx v1.1.0
    logged `prev_hash chain intact: 2 event(s) chained` for `tokenfuse.ndjson`;
    `vouchryx.ndjson` was not exercised. The pairs, derived from compose.yaml: `tokenfuse.ndjson`
    (gateway), `tokenfuse-cloud.ndjson` (control plane) and `tokenfuse-mcp.ndjson`
    (broker) carry `tokenfuse`; `wardryx.ndjson`, `typryx.ndjson`,
    `vouchryx.ndjson` and `agent-conform.ndjson` carry their own name; idryx and
    `idryx-detect` load `tokenfuse:` from `tokenfuse.ndjson`.
    *(gate: `scripts/bus-names-match-their-source.sh`, which prints the table it
    judged; scenarios in `features/stream-files-match-their-source.feature`;
    teeth in `scripts/gates-have-teeth.sh`. The allowed table and the source each
    image claims are copies of what heraldyx, idryx and each producer carry, and
    nothing holds them equal: the claimed sources were read from each producer's
    source constant, not from a run of every plane, and a stream a plane
    writes that this launcher does not configure is not seen.)*

24. **The FinOps console is an optional add-on: the core stays the core, as
    shipped it cannot spend, and it can write exactly one file on the bus.**
    `@decided 2026-09-25` (paraphrased): an optional add-on joins the core by
    configuration alone and leaves the core unchanged, so a box that never
    enables it runs what it ran without it. `@claude 2026-10-07`: CostCrew, the
    FinOps console, is such an add-on. `costcrew` and its one-shot
    `costcrew-init` sit behind the `finops` profile and nothing else; the only
    way to start it is `docker compose --profile finops up -d costcrew`, typed
    by a person. `install.sh` has no flag for it and no line that names it,
    because the other ways of switching a profile on (`--profile`,
    `COMPOSE_PROFILES`) are each one line in a script that runs as root on
    somebody else's box, for a console that script has nothing to verify about.
    Nothing outside the add-on names it: it has its own one-shot rather than a
    mount in `init-volumes`, which every install runs, and a default and a
    `--profile finops` rendering of `compose.yaml` differ by exactly those two
    services and the `costcrewdata` volume.
    It cannot spend as shipped: no `-gateway`, `-gateway-openai` or
    `COSTCREW_GATEWAY*` is named, which the console itself reports as "cannot
    spend at all", and the crew runner in the same image is not started. Letting
    its planning calls through this box's gateway is the operator's separate
    decision. Its stream is `/var/lib/stack/events/costcrew.ndjson` (genaryx keys
    its read offset off the stem) under `-stack-host ${RECORD_TRUST_DOMAIN}`,
    the one trust domain the record plane takes; `-stack-passports` (inside its
    own data volume, nothing here has a passports location) and `-stack-owner`
    (`COSTCREW_OWNER`, else `ALERT_TO`) are the pair the console refuses to start
    without, and with neither set it exits at start naming the owner. It runs as
    `10003:10003`, outside both bus uid families and the bus group, with no
    `group_add`, read-only, no capabilities, one pinned tag, so on a
    `root:10001 2775` bus it can create nothing and write the one 0644 file
    `costcrew-init` gave it, which the chain verifier reads through the "other"
    bits. Published on `127.0.0.1:8321` only, written as a literal: stack-caddy
    serves one site, baked into an image in another repository, so a second
    would change the core; no `-behind-tls` for the same reason. @measured
    `docker compose config` of origin/main's compose.yaml against this one,
    same fake `.env`, project path normalised, 2026-10-07: the default rendering
    is identical. @measured scratch compose project `finopstest` on Docker
    Desktop (arm64), `ghcr.io/taipanbox/costcrew:v0.3.0`, 2026-10-07: with no
    owner the console exits "a passport with no owner is not a valid document";
    with `ALERT_TO` set it served `/healthz` 200 with no redirect on
    `127.0.0.1:8321` and from a busybox on the compose network, published 39
    passports and wrote 26 lines to `costcrew.ndjson` (owned
    10003:10003, 0644); a busybox as 10003 could append to that file and was
    refused on `wardryx.ndjson`, on `agent-conform.ndjson` and on creating a
    file; `agent-conform:v1.1.0` as 10002 printed `PASS costcrew.ndjson (hash
    chain: 25 chained, 1 head(s))`; after `down` and `up` it published the
    passports again, logged `9 anomalies, 0 of them new` and left the file untouched.

    Its read-only root has a writable temp: a 128 MB tmpfs at `/tmp`. SQLite
    writes a VACUUM's working copy and a sort too big for memory to a temp
    file, and Go spools a large upload to one; with no writable directory
    SQLite answers `disk I/O error (6410)`, its "no temp path" error. Found by
    the v0.4.0 pin (#93): the first start over a v0.3.0 volume dropped the
    clear-text session tokens and then could not VACUUM their bytes out of the
    file, and said so only as a WARNING, so nothing went red. The gate takes a
    TMPDIR inside a volume mounted read-write as equally good. @measured
    `scratch compose projects on Docker Desktop (arm64), costcrew v0.3.0 with
    one signed-in session, then v0.4.0 on the same volume, origin/main's
    compose.yaml against this one` 2026-10-08: without the tmpfs, `WARNING: old
    session tokens were dropped but the database could not be vacuumed ...
    disk I/O error (6410)` and app.db 3,444,736 bytes; with it, no warning,
    `sessions_reset` journaled with `ended: 1`, app.db 3,284,992 bytes, the old
    cookie's 43 bytes found 0 times in app.db and in app.db-wal, the old cookie
    sent back to `/login` and a fresh sign-in served.
    *(gate: `scripts/finops-is-opt-in.sh`, subjects derived from the image name
    and from what the console waits for; `scripts/manifest-is-true.sh` lists the
    two services under `optional_addons` and requires the profile, an
    `install.sh` that never passes it and no `COMPOSE_PROFILES` line naming it;
    `scripts/bus-has-a-writer.sh` and `scripts/bus-names-match-their-source.sh`
    judge the add-on's volume and stream, reading `costcrew-init` as a preparer
    beside `init-volumes`; scenarios in
    `features/the-finops-console-is-an-optional-addon.feature`; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: an `install.sh` run on Debian
    with the profile enabled afterwards, the console under a reboot, the UI in
    a browser, and anything on this box reading the passports it writes (the
    notifier mounts no passports directory, so an alert about a CostCrew agent
    names the agent and not the owner). The first start seeds a generated
    estate, not a bill of yours. Nor whether 128 MB is enough for the database
    a real box grows: at the limit one statement fails "database or disk is
    full", the console carries on.)*

25. **A public repository carries no quote of the owner.** `@decided
    2026-09-09` (paraphrased): in a public repository there is no verbatim
    quote of the owner, no provenance marker naming the owner and no sentence
    attributing a decision to the owner by name. A decision is still recorded,
    so a later reader does not re-derive it: `@decided YYYY-MM-DD` and a
    paraphrase in our own words, not edited afterwards. The verbatim words live
    in private places only. The owner's name as copyright holder or author is
    ownership, not a quote. This tree was already clean when the gate arrived
    (@measured `git grep` for the marker, Cyrillic and guillemets, 2026-10-08:
    none); the sibling stack-k8s was not, and the same script is its gate.
    *(gate: `scripts/no-owner-quotes.sh`, over every tracked text file: the
    owner's marker, any Cyrillic, any guillemet, and the owner's first name or
    surname outside a copyright, author or maintainer line; it refuses to report
    OK on no tracked text file; scenarios in
    `features/public-text-carries-no-owner-quotes.feature`; teeth in
    `scripts/gates-have-teeth.sh`, including a pass case for the owner as
    copyright holder. Not covered: a quote in English with no name beside it,
    and git history, which keeps whatever an earlier commit said.)*

26. **Closing a retained reservation is off by default, and when it is on the
    gateway and the console hold the same secret.** `@decided 2026-10-11`
    (paraphrased, recorded in tokenfuse): a retained reservation is closed by a
    person after a passkey assertion in the console, which mints a short-lived
    token the gateway verifies; both are keyed by one shared secret.
    `@claude 2026-10-12`: on this box that secret is the operator's choice. A
    default install leaves both sides off: compose hands the gateway
    `TOKENFUSE_CLOSURE_SECRET: ${CLOSURE_SECRET:-}` and the console
    `GENARYX_CLOSURE_SECRET_FILE: ${CLOSURE_SECRET_FILE:-}`, and each reads an
    empty value as off. `WITH_CLOSURE=1 ./install.sh` mints the secret once with
    `gen 48` into `.env` and writes the same bytes to `./closure/secret` (0400,
    uid 10001, the console's), which the console mounts read only at
    `/run/closure`. The file is written with `printf '%s'`: the console trims
    whitespace from it and the gateway reads its variable as given, so a
    trailing newline would make every token fail. The secret is never printed.
    A re-run keeps it; turning closing off is removing `CLOSURE_SECRET` and
    `CLOSURE_SECRET_FILE` from `.env`. It takes effect only with a tokenfuse
    image that serves `POST /v1/retained/close` and a console image that has the
    close command: tokenfuse v1.9.0 and console v1.1.34, pinned here since
    1.1.24, are the first that do, and an older image ignores the variable.
    *(gate: `scripts/closure-off-by-default.sh`, which refuses to report OK on
    no gateway, no console, no variable, no guarded mint or no write of the
    file; scenarios in `features/closing-is-off-by-default.feature`; teeth in
    `scripts/gates-have-teeth.sh`. A token minted by a real console and
    verified by a real gateway: @measured stack-k8s
    `evidence/closure-e2e/run.sh` (this compose file's wiring of the gateway,
    the control plane and the console, tokenfuse v1.9.0, console v1.1.34)
    2026-10-12, 29 of 29 twice. Not covered: a live install with
    `WITH_CLOSURE=1`, and a re-run that turns closing off.)*

27. **The gateway's agent firewall runs in enforce on every box, and one
    installer variable is the only way back.** `@decided 2026-10-13`
    (paraphrased): the launcher runs tokenfuse's agent firewall in enforce by
    default, shipped as its own change after a test stack; an operator keeps
    one switch to run it in shadow or off. `@claude 2026-10-13`: tokenfuse reads
    `TOKENFUSE_FIREWALL` as `enforce`, `shadow` or `off`, and reads any other
    value as its default, shadow, without a word
    (`crates/gateway/src/firewall.rs`, `from_env`, at tokenfuse v1.11.0), so a
    misspelt value would run shadow on a box that looked enforced. `@claude 2026-10-13`,
    correction: that holds for tokenfuse v1.11.0 only. From v1.11.1 a value outside the
    three words exits 2 before the listener binds (tokenfuse release notes, v1.11.1), so
    a misspelt value stops the gateway instead of running it in shadow. So every
    gateway service sets `${TOKENFUSE_FIREWALL:-enforce}` in `compose.yaml`, and
    `install.sh` refuses any value other than the three before it installs
    anything, writes a usable one to `.env`, and replaces the line an earlier run
    wrote. In enforce, tokenfuse withholds a model answer that asks a run for
    exec, write or network egress once the run carries an untrusted label, a
    secrets label with network egress, or the suspected-injection label
    (tokenfuse invariants 25 to 27 and 93). The model call has already happened
    and been billed by then, and the response-side judgment does not run on a
    streamed answer. The MCP broker, `focus-export` and the control plane are not
    gateways and do not read the switch.
    *(gate: `scripts/firewall-is-enforce.sh`, subjects derived from compose.yaml's
    own image and command lines like invariant 13's; it requires the default to
    be exactly `${TOKENFUSE_FIREWALL:-enforce}`, lifts the `# firewall-mode:`
    block out of install.sh and runs it per case, and reads `docker compose
    config` for enforce, shadow and off; it refuses to report OK on no gateway
    service, no installer block or no Docker; scenarios in
    `features/the-agent-firewall-is-enforce-by-default.feature`; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: that a running gateway withholds
    a call under enforce, which needs a live stack; the streamed path; the
    broker's own taint decisions under enforce; and whether an operator keeps the
    switch set.)*

28. **Personal data in prompts and tool arguments is recorded in shadow by
    default, on every box, and one installer variable is the only way to move
    it.** `@decided 2026-10-13` (paraphrased): the launchers run TokenFuse's two
    PII scanners, the gateway's and the MCP broker's, in shadow by default, and an
    operator keeps one switch to move them to off, mask or block. Shadow records
    and forwards: the prompt or the tool arguments go on unchanged. The gateway
    adds an `x-fuse-dlp` note (the kinds and a count, never the values) to its
    response and logs nothing; the broker logs a warning and, on a tool response,
    marks `_tokenfuse.dlp_pii`. Neither is an event on the bus. `@claude
    2026-10-13`: TokenFuse reads an unset or unrecognised value as off without a
    word (`crates/gateway/src/defaults.rs`, `dlp_pii_mode_from`, and the broker's
    `TOKENFUSE_MCP_DLP_PII` in `crates/gateway/src/main.rs`, at tokenfuse v1.11.0,
    the tag this launcher pins), so a misspelling would silently switch detection
    off. `@claude 2026-10-13`, correction: that holds for tokenfuse v1.11.0 only. From
    v1.12.0 a set value outside the accepted words exits 2 before the listener binds
    (tokenfuse release notes, v1.12.0, invariant 98); an unset value still takes the
    `shadow` default that compose supplies. Every gateway sets `TOKENFUSE_DLP_PII` and
    the MCP broker sets
    `TOKENFUSE_MCP_DLP_PII`, each from `${TOKENFUSE_DLP_PII:-shadow}` in
    `compose.yaml`. `install.sh` section 0e refuses any value outside off, shadow,
    mask and block before it installs anything. *(gate:
    `scripts/pii-is-shadow.sh`, which lifts the `# pii-mode:` block out of
    install.sh and runs it per case, checks the validation runs before the first
    package install, reads `docker compose --profile typed config` for the
    default, off and block, and refuses to report OK on no subject, no block or no
    Docker; 18 teeth cases in `scripts/gates-have-teeth.sh`. Not covered: a live
    call recording a finding, the streamed path, mask and block against a real
    provider, and whether an operator keeps the switch set.)*

29. **Client keys and the identity map come in as files, the gateway image reads
    them before anything restarts, and a re-run keeps them.** `@decided
    2026-10-13` (paraphrased): the installer takes the gateway's client keys and
    identity map as files that a person or an onboarding agent prepares; keeps
    them across re-runs, never rotating a secret or dropping the map; checks them
    before anything restarts, refusing an unknown unit, an empty file and a map
    that names a key with no secret; mounts the map read only into the gateway;
    and ends by saying which header an agent sends.

    `@claude 2026-10-13`, the shape chosen. `CLIENT_KEYS_FILE` holds one
    `secret:key_id` per line, the line the console's Onboard tab prints (blank
    lines and `#` comments ignored), and `IDENTITY_MAP_FILE` is tokenfuse's map
    (docs/20). Files rather than keys minted here: the onboarding side already
    mints a secret per agent and hands it over, and a second minter would be a
    second copy of every secret to deliver. The keys go into `.env` (0600) as
    `GATEWAY_CLIENT_KEYS`, single-quoted, because a secret may hold `:~:` and a
    shell that sources `.env` expands that `~`; they are never printed. The map
    is copied to `./identity/identity.json`, 0444 like `policy.yaml` (it holds no
    secret, and a bind mount keeps host ownership, so any uid can read it), and
    compose mounts `./identity` read only at `/etc/tokenfuse/identity`. Compose
    passes both as `${...:-}`, which tokenfuse reads as off, so a box that gave no
    file runs as before.

    Checked twice, and nothing is written until both pass. Section 0f, before a
    package is installed, is what a shell can check with no JSON parser: each file
    readable, regular, not empty, no NUL byte, at most 256 KiB (keys) or 1 MiB
    (map); each key line split on its LAST colon as tokenfuse splits it, a secret
    of 24 to 256 of `A-Z a-z 0-9 . _ ~ + / = @ : -` and a key id of 1 to 128 of
    `A-Z a-z 0-9 . _ -`, so no comma, quote, dollar or space reaches `.env` or
    the spec; no secret given twice; the map starts with `{`; a value an earlier
    run left in `.env` held to the same grammar; a refusal names the line, never
    the secret. Section 3e, once the images are on the box and before anything
    starts, hands the pair to the gateway image compose resolves for
    `tokenfuse-gateway`, in a throwaway container with no network and the uid it
    runs as, so tokenfuse's own parser is the judge, not a copy of it here.
    Refused: whatever it would exit 2 on (an unknown unit, a bad pattern, a
    non-positive budget, invalid JSON), and three things it only warns about and
    then runs with: a map that configures nothing (an empty file and `{}` read as
    no map at all), a map `key_id` no client key carries, and a client key the map
    does not bind, which under strict=enforce is refused 403 on every call. This
    launcher never sets `TOKENFUSE_IDENTITY_STRICT`; tokenfuse's default is
    enforce (its invariant 37). A re-run that names no file keeps both and checks
    them again; one that names a file replaces what it names and is checked
    against the kept other half; a changed map restarts the gateway, which reads
    the map only at start. Turning either off is removing its `.env` line.
    `@claude 2026-10-17`: that holds for the map only now. Invariant 35 makes the
    keys required on the gateway every box runs, mints them when no file is given,
    and writes `TOKENFUSE_IDENTITY_STRICT: enforce` out on every gateway, so the
    sentence above about this launcher never setting it is history; a map can no
    longer come without keys.

    Section 8 reads the running gateway: its own start-up lines, and two calls it
    must refuse 401 (no key, an unknown key). It names no agent, because a
    mismatch is a high-severity event on the bus and an installer must not page
    its operator on every run; CI's `identity` leg sends that call. Felyx, the
    console's copilot, sends an `x-fuse-key` only when `GENARYX_COPILOT_FUSE_KEY`
    is set (invariant 16; a console from v1.1.44 on, where v1.1.36 sent none), so
    with client keys on and that key empty its calls are refused 401; when
    `GENARYX_COPILOT_KEY` is set the closing report says which of the two the box
    has. @measured `scratch compose project from this
    compose.yaml (tokenfuse v1.11.0, wardryx v1.3.0, a python stub as the
    upstream), .env and ./identity prepared by this block, curl from the compose
    network` 2026-10-13: no key 401 `unauthorized`; an unknown key 401; the
    treasury key as a research agent 403 `identity_mismatch`
    (`agent_id_not_allowed`); the treasury key with no agent id 403
    (`agent_id_missing`); each key as its own agent 200 from the stub; a re-run
    naming no file left `.env` and the map byte for byte; a wider map stayed out
    of force through `up` (403) and was in force after the restart (200); with the
    keys taken out, section 8's call was answered 400 `identity_required` and 402
    with an agent id, never 401, so its check goes red on a gateway that does not
    hold the keys.
    *(gate: `scripts/identity-files-are-checked.sh`, subjects derived from
    compose.yaml's image and command lines like invariant 13's; it lifts the
    `# identity-files:` block out of install.sh and runs the first half per case
    against hostile files and the second half against the pinned gateway image
    and against that image with its ENTRYPOINT emptied, the shape BUILD_FROM_SOURCE
    builds,
    reads the call order in install.sh and `docker compose config`, and refuses
    to report OK on no gateway, no block, no Docker or no image; scenarios in
    `features/client-keys-and-the-identity-map.feature`; teeth in
    `scripts/gates-have-teeth.sh`; CI's `identity` install leg runs install.sh
    twice with both files and asserts 401, 401, 403 `identity_mismatch` and a 402
    past identity. Not covered: the unit budget refusing a call at its monthly
    cap, a box with more than a few keys, a hand-edited `./identity/identity.json`
    (read only at the next start, and only re-checked by the next install.sh
    run), Felyx calling with a key (measured by hand once, invariant 16, not
    gated), and stack-k8s, which has none of this yet.)*

    One block, every door. `@claude 2026-10-14`: the OpenAI door (invariant 32)
    takes a keys file and a map of its own, and they are checked by this same
    block, run for that door by name: `identity_door main` or `identity_door
    openai` names the input variables (`CLIENT_KEYS_FILE` or
    `OPENAI_DOOR_CLIENT_KEYS_FILE`, and the two map variables), the `.env` lines
    (`GATEWAY_CLIENT_KEYS` or `OPENAI_DOOR_CLIENT_KEYS`), the directory
    (`./identity` or `./identity-openai`), the service, and the wire and upstream
    the check container starts with (the gateway refuses the openai wire with no
    upstream). Each door's state is kept under its own name when the other is
    named (`printf -v` and `${!name}`, which bash 3.2 has), and the check now
    requires the container's own `serving one door` line to name the door's route,
    so a check started on the other wire is refused. Not a copy per door: two
    copies of a security check drift apart (stack-k8s GOTCHAS 101).
    *(gate: `scripts/identity-files-are-checked.sh` reads the doors from
    identity_door's own case labels and runs sections A to E once per door, and
    requires every gateway in compose.yaml to be exactly one door's service; it
    also runs one process through both doors and back and requires each to keep
    its own state; teeth for the door dimension in `scripts/gates-have-teeth.sh`)*

30. **A check reports the box, not which of two processes finished first.**
    `@claude 2026-10-13`, from upgrading an installed box to v1.1.32. `install.sh`
    runs under `set -o pipefail`, and several of its verification checks read a
    container's log through a pipe: `docker compose logs <service> 2>&1 | grep -q
    <line>`. `grep -q` exits at its first match, compose is still writing, meets
    the closed pipe and exits 255, and pipefail fails the pipeline although the
    line was in the log. @measured `set -o pipefail; docker compose logs
    tokenfuse-gateway 2>&1 | grep -qF 'client auth: ON (3 key(s))'` five times on
    a Debian 13 box (Docker 26.1.5, Compose 2.26.1), 2026-10-13: exit 0, 255, 255,
    0, 255; the same without `-q`, where grep reads everything: 0 five times. Two
    installs on that box reported `FAIL client keys: the gateway holds 3` and
    `FAIL identity map: the gateway reads it` on a healthy gateway, while CI on
    GitHub's runners happened to pass. The negative form, `! docker compose logs
    ... | grep -qE '<a bad line>'`, reads ok with the bad line present: the 255
    fails the pipeline and `!` turns that into a pass. `@claude`: that direction
    was reproduced with a stub `docker` (below), not seen on the box.

    So `check()` and `check_log()` evaluate a command string in a subshell with
    pipefail off, and a pipeline's verdict is its reader's, the last command's:
    the line was there, or it was not. Once, in the helpers, so a check added next
    month cannot bring the race back. A producer that cannot run at all leaves the
    reader nothing to find, so a positive check still FAILs; the one negative log
    check (`identity map: every key is bound ...`) reads ok on an unreadable log
    and is paired, on the same log, with a positive one that does not. The
    installer's own `if` that asks whether a service exists is `compose_has`,
    which reads the service list to its end before it looks, because a wrong "no"
    there skips a whole group of checks and the run still ends "every check
    passed".
    *(gate: `scripts/checks-survive-a-closed-pipe.sh`. It lifts the
    `# check-helpers:` and `# compose-has:` blocks out of `install.sh` and runs
    them under `set -euo pipefail` against a stub `docker` on PATH that prints a
    log (the line first, then four megabytes) and, like compose, exits 255 when its
    reader goes; it first shows the stub breaks the unwrapped pipeline every time.
    It extracts every `check` and `check_log` of `install.sh` that reads a log or
    the service list through a pipe, as written, and runs each in six situations (a
    healthy box, a silent log, nothing running, unreadable logs, a refused line in
    both logs, a refused line in the gateway's): a positive check must be ok on the
    line and FAIL without it, a refused line must never read ok. A log check added
    without a case here, or a case whose check is gone, is reported. It also
    refuses any other line that pipes `compose logs` or `compose ps` into an
    early-exit reader. Refuses to report OK on no helper block, no check or a stub
    that did not break the pipe. Scenarios in
    `features/the-install-report-matches-the-box.feature`; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: a Compose or a Docker other than
    the pair measured; a log wording that no longer matches the running tokenfuse
    (the fixtures carry the phrases `install.sh` looks for, not tokenfuse's whole
    lines); a short command (`docker port`, `curl`) piped into `grep -q`, which the
    helpers also make safe but this gate does not run.)*

31. **A secret is minted from a bounded read, so minting one ends on its own
    whatever SIGPIPE is set to.** `@claude 2026-10-14`, from a pre-push hook that
    hung on a Mac. The idiom `tr -dc A-Za-z0-9 </dev/urandom | head -c N` reads a
    stream that never ends, and only the pipe head closes stops tr. Git runs a
    hook with SIGPIPE ignored, so tr's next write just fails: macOS's tr never
    exits, and GNU tr exits printing `write error: Broken pipe`. @measured on
    macOS 2026-10-14: `perl -e '$SIG{PIPE}="IGNORE"; alarm 5; exec @ARGV' bash -c
    'LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 5'` was killed by the
    alarm at 5 s (exit 142), and so were install.sh's `gen 40` and
    `scripts/delegation-key-reused-on-rerun.sh`, whose own copy of the generator
    was that line (the hook hung there); in debian:12-slim (GNU coreutils 9.1),
    install.sh's `gen 40` under `trap '' PIPE` returned 40 characters and printed
    `tr: write error: Broken pipe`, three runs of three. install.sh runs on
    Debian or Ubuntu, where tr exits, so no install was stuck; the gates and the
    hook on a Mac were.

    So `gen` reads 4096 bytes with `head -c`, keeps the 62 characters with tr
    (about 990 on average; the longest secret asked for is 64), and cuts to N in
    bash: nothing closes a pipe early, so nothing depends on what SIGPIPE is. Its
    length check still refuses a short value. It lives once, between the
    `# gen:` markers, and the gate that mints keys with it lifts it rather than
    keeping a copy.
    *(gate: `scripts/gen-is-bounded.sh`. In install.sh, `.githooks/*` and
    `scripts/*.sh`, every read of `/dev/urandom` in code (not a comment, not a
    message) is the file operand of `head -c <count>`. A control first runs the
    unbounded line with SIGPIPE ignored and a 3 s bound and requires it either not
    to end or to write to stderr, so the harness is known to reproduce the fault.
    Then every `gen()` defined in those files is run with SIGPIPE ignored and a
    10 s bound, 20 times for each length install.sh asks for: each run must end,
    exit 0, print exactly N of A-Za-z0-9 and nothing on stderr, and no value may
    repeat. Refuses to report OK on no `gen`, no length or no read.
    `scripts/delegation-key-reused-on-rerun.sh` refuses on no `# gen:` block.
    Scenarios in `features/a-secret-is-minted-whatever-sigpipe-is.feature`; teeth
    in `scripts/gates-have-teeth.sh`. Not covered: a generator that is not named
    `gen`, a read of the random source by another path (`/dev/random`,
    `openssl rand`), and the randomness itself, which only "no value repeats in
    100 runs" touches.)*

32. **The OpenAI door is opt-in, a gateway like the first in every hardened
    setting, on keys and a map of its own, on the operator's bind, and never on a
    box that did not ask for it.** `@decided 2026-10-13` (paraphrased): an opt-in
    second tokenfuse gateway serves the OpenAI wire on port 4110, in front of an
    OpenAI-compatible upstream the operator chooses, with every hardened setting
    the first gateway has; the notifier and the identity plane read its stream as
    tokenfuse through a built-in row each of them ships (heraldyx v0.5.0, idryx
    v1.2.0), so invariant 23 stays as written and no stream declaration is set on
    the box; and it takes a keys file and an identity map of its own rather than
    the gateway's, because a unit's month counter lives in one gateway process
    (tokenfuse docs/20) and a unit in both maps would get its cap once on each
    door.

    `@claude 2026-10-14`, the shape. compose.yaml's `tokenfuse-gateway-openai`
    runs the gateway's own image default and bare command, so every gate that
    derives its subjects from those lines judges it, behind `profiles:
    ["openai-door"]`, with every hardened line written out in its own block, not
    through a YAML anchor. It sets `TOKENFUSE_WIRE: openai`, publishes
    `${GATEWAY_BIND:-127.0.0.1}:4110:4100`, exports to
    `tokenfuse-openai.ndjson`, keeps `traces/gateway-openai` (both made by
    `init-volumes` on every box), reads its map from `./identity-openai`, and sets
    no delegation or closure variable (a hand-off proof's DPoP `htu` is checked
    against the 4100 origin, and the console closes reservations through one
    gateway). Its keys are `${OPENAI_DOOR_CLIENT_KEYS:-}` and its map
    `${OPENAI_DOOR_IDENTITY_MAP:-}`; its upstream is
    `${OPENAI_DOOR_CLIENT_KEYS:+${OPENAI_DOOR_IDENTITY_MAP:+${OPENAI_DOOR_UPSTREAM:-}}}`,
    empty unless keys and a map are set, and tokenfuse refuses to start with no
    upstream, so a door started by hand without them does not open. Not
    `${VAR:?}`: compose interpolates every service, a profile's too, so a
    required variable on the door stops `docker compose up` on every box that
    never asked for it. @measured `docker compose config` of a two-service file
    whose profile-only service sets `${DOOR_X:?}`, Docker Compose v5.6.0 on
    macOS, 2026-10-14: "required variable DOOR_X is missing a value" with the
    profile off. @measured the nested `:+` form in `docker compose --profile door
    config` under Compose v2.22.0, v2.26.1 and v2.29.1 (images docker:23.0-cli,
    docker:26.0-cli, docker:24.0.9-cli) and v5.6.0, 2026-10-14: the upstream with
    all three set, empty with any one unset. @measured `docker run --rm
    --network none -e TOKENFUSE_WIRE=openai -e TOKENFUSE_UPSTREAM=
    ghcr.io/taipanbox/tokenfuse:v1.13.1 /usr/local/bin/tokenfuse`, 2026-10-14:
    exit 2, "refusing to start: TOKENFUSE_UPSTREAM is not set" (the gate re-runs
    this on every pass).

    install.sh section 0g reads `OPENAI_DOOR` (1 on, 0 off, unset keeps what
    `.env` saved) and, before any package is installed, refuses the door without
    `OPENAI_DOOR_UPSTREAM` (http or https, a host, no credentials, query or
    fragment, ending in `/chat/completions`), without a keys file and without a
    map (given now or kept in `.env`), and refuses a door setting given with the
    door off; a refusal never echoes the upstream. The door's files go through
    section 0f's block by name (invariant 29). Section 3e checks the gateway's
    pair, then the door's with the image compose resolves for the door, then
    compares the two maps with python3 in a throwaway, network-less container of
    the console's image (@measured `docker run --rm --network none --entrypoint
    python3 ghcr.io/taipanbox/genaryx-console:v1.1.44 -c ...`, 2026-10-14: Python
    3.12.15) and refuses two that declare one unit id, removing both staging
    directories; only then is either written. Both profile lists gain
    `--profile openai-door` on a line `DOOR_ON` decides; off, the container is
    removed by name after `up` (a profile's container survives an `up` that does
    not name it); a new door map restarts the door. Section 8, on every box that
    asked and never skipped there, asks the door what it asks the gateway: 4110 on
    the bind and loopback refusing on a one-address bind, the published rule, the
    wire, the export line, the ceiling line, its keys and map, and 401 with no key
    and with an unknown key. The closing report says a metered upstream bills
    whoever's key the caller sends. `OPENAI_DOOR=0` drops `OPENAI_DOOR` and keeps
    the door's other lines.

    The limits, named rather than implied. The door's traces are not in the FOCUS
    export (`focus-export` reads `traces/gateway`, stack-single#61). The console
    reaches one gateway's admin routes, so a 4110 run shows in the Cloud and on
    the bus and not in the console's runs view. Counters are per gateway process:
    a unit is counted by its door alone (hence distinct units), and a run id used
    on both doors gets a run budget on each, two budgets. A metered upstream is
    billed to whoever's key the caller sends; budgets limit the spend, not whose
    account pays. The door holds the gateway's admin, declassify, Cloud and
    wardryx credentials, so it has the gateway's blast radius. stack-k8s and
    stack-up have no door, and nothing there pre-creates `tokenfuse-openai.ndjson`.
    *(gate: `scripts/openai-door.sh`: the door's compose block against the
    gateway's, the installer block run per case, two maps sharing a unit against
    the pinned gateway and console images, the order in install.sh, the resolved
    configuration with and without the profile, and the pinned image refusing an
    empty upstream; refuses to report OK on no door service, no block, no Docker
    or no image. The firewall, PII and run-budget gates read the resolved
    configuration with `--profile openai-door` and require every gateway section A
    found; `scripts/bus-has-a-writer.sh` and
    `scripts/bus-names-match-their-source.sh` (row `tokenfuse-openai.ndjson ->
    tokenfuse`, and readers pinned at or after the releases that carry it) hold
    its stream; `scripts/checks-survive-a-closed-pipe.sh` runs its log checks.
    Scenarios in `features/the-openai-door.feature`; teeth in
    `scripts/gates-have-teeth.sh`; CI's `openai-door` install leg runs install.sh
    twice with the door on against a stub upstream on the runner, asserts 401,
    401, 403 `identity_mismatch`, 402 and a 200 whose upstream received the
    caller's own Authorization, and turns the door off. Not covered: a real
    metered upstream, a streamed call through the door, a box with a one-address
    bind, `docker-compose` v1, and the forge upgrade from its hand-written
    override, which is an operator step.)*

33. **`status` reads the installed stack and changes nothing.** `./install.sh status`
    runs the verification list section 8 runs, from one function, `stack_checks`,
    which both callers run, against a stack that is already up. It installs,
    pulls, starts, stops, restarts and removes nothing, issues no device, sends no
    mail, and writes nothing to the event bus: the checks that would are marked
    `install_only` and print as `skip` under status. It refuses a directory with no
    `.env` before it calls any tool. *(gate: `scripts/status-is-read-only.sh`, a
    stub docker, curl, apt-get, systemctl and ufw that log every call; 10 teeth
    cases in `scripts/gates-have-teeth.sh`; scenarios in
    `features/status-checks-the-installed-stack.feature`.)*

34. **Docker watches every service that exposes a health path, and no distroless
    one.** Each service the installer probes at `/healthz` (the gateway, the
    OpenAI door, the cloud and the console) has a compose healthcheck that asks the
    same path on the port it listens on, with a tool its image already has (bash's
    `/dev/tcp`). `wardryx`, `idryx`, `typryx-wardryx-proxy` and `vouchryx` are
    distroless and carry no healthcheck, by a list in the gate. *(gate:
    `scripts/health-checks-are-declared.sh`, 6 teeth cases; scenarios in
    `features/docker-watches-the-services-with-a-health-path.feature`.)*

35. **The gateway never answers an unnamed caller: it requires client keys on
    every box, its identity map is strict, and a box given no keys file gets keys
    the installer mints, each bound to its own agent ids.** `@decided 2026-10-17`
    (paraphrased): close the agent-security findings of the 2026-10-17 review,
    starting with the defaults; here finding F-001's launcher half. `@claude
    2026-10-17`: with `TOKENFUSE_CLIENT_KEYS` unset tokenfuse admits every caller
    and takes `x-fuse-agent-id` as written, so an agent could speak as another and
    take its policy, its budget and its place in the record; compose passed
    `${GATEWAY_CLIENT_KEYS:-}` and the installer set keys only from an operator's
    file (invariant 29).

    So compose passes `TOKENFUSE_CLIENT_KEYS: ${GATEWAY_CLIENT_KEYS:?...}` on the
    gateway every box runs (the declassify key's shape, invariant 19; the OpenAI
    door keeps `:-` because compose reads a profile's variables on every box, and
    its upstream already keeps it shut), and `TOKENFUSE_IDENTITY_STRICT: enforce`
    on every gateway, written out rather than left to tokenfuse's default. The
    built-in callers of the metered doors, read from compose.yaml, are one: Felyx,
    the console's copilot, which presents `GENARYX_COPILOT_FUSE_KEY` (genaryx
    invariant 24, console v1.1.45 on). Given no keys file, `install.sh` (the
    `# identity-mint:` block after section 0f) mints two keys: `felyx`, bound to
    exactly `agent://<td>/genaryx/felyx` in unit `console`, its secret
    `GENARYX_COPILOT_FUSE_KEY` in `.env`; and `agents`, bound to
    `agent://<td>/agents/*` in unit `agents`, its secret `GATEWAY_AGENT_KEY` in
    `.env` and in `$STACK_DIR/agent-key` (0600), whose path, never the value, the
    closing report prints with the namespace and the headers. `<td>` is
    `RECORD_TRUST_DOMAIN` (`.env`, else the environment, else `local`, compose's own
    default for Felyx's id), refused before any package unless it is a name. The
    agents' pattern stops short of Felyx's id. The map carries no budget and no
    prefixes: it binds and attributes, and a budget is the operator's decision.

    A secret already in `.env` is never rewritten; an absent or empty one is minted
    with `gen 40`. The spec and the map are rebuilt from `.env` on every run, the
    same bytes each time, and pass through section 3e like an operator's files, so
    the gateway image reads them before anything restarts and a re-run restarts
    nothing. `GATEWAY_IDENTITY_MINTED=1` marks the keys as the installer's. An
    operator's own files replace them, both together on a minted box (the minted map
    binds the minted key ids only); a map with no keys, and a map-only box, are
    refused before anything is installed, naming what to give. Section 3c's pull and
    3e's image lookup read the configuration before the keys are written, so each
    hands compose a stand-in for that read alone. Section 8 checks the agents' key
    file (0600, the key `.env` holds) and that Felyx holds its key, bound to the id
    the console names it with; it names no agent, and CI's install legs send the
    calls. `./install.sh status` refuses a `.env` with no keys, naming the re-run.
    Breaking, on purpose: an agent that called with no key is refused 401 after the
    first run of this release, and `docker compose up` on a `.env` from before it
    stops at the missing variable.
    *(gate: `scripts/metered-doors-require-keys.sh`: the compose subjects from their
    image and command lines, the resolved configuration with and without the keys,
    the lifted `# gen:`, `# identity-files:` and `# identity-mint:` blocks run in
    scratch directories (first install, re-run, a Felyx key set by hand or empty, the
    trust domain, the operator's own keys, the four refusals, the operator taking
    over), the minted pair read by the pinned gateway image, and the order in
    `install.sh`; refuses OK on no gateway, no mint block or no Docker;
    `features/the-metered-doors-need-a-key.feature`; teeth in
    `scripts/gates-have-teeth.sh`; CI's install legs call the gateway with and
    without the minted keys. Not covered: one key for all of the operator's agents
    (an agent holding it can speak as any id under `agents/`), rotation (empty a
    line and re-run), a hand-edited minted map (rebuilt on the next run), stack-k8s
    and stack-up.)*

36. **The MCP broker blocks raw secrets and flagged tool listings, and asks the
    policy plane about every tool call, failing closed.** `@decided 2026-10-17`
    (paraphrased, as invariant 35); here finding F-009's launcher half. `@claude
    2026-10-17`: unset, tokenfuse's broker runs `TOKENFUSE_MCP_DLP` shadow (it
    forwards a raw secret it found in tool arguments), `TOKENFUSE_MCP_SCAN` warn
    (it passes a tool listing its scanner flags) and its wardryx hook off, and this
    launcher set none of them, so a denied tool was called and a raw AWS key id was
    forwarded (the review's live rows G5.6 and G6.6, 2026-10-17). So the broker sets
    DLP and the scan to `block`, `TOKENFUSE_WARDRYX_MODE` to
    `${TYPED_RISK_WARDRYX_MODE:-enforce}`, `TOKENFUSE_WARDRYX_URL` to
    `${TYPED_RISK_WARDRYX_URL:-http://wardryx:8090}` (the typed risk signal still
    points it at its proxy, invariant 22), `TOKENFUSE_WARDRYX_FAILMODE: closed` and
    a required `TOKENFUSE_WARDRYX_KEY`. Every `tools/call` therefore carries
    `x-fuse-agent-id`, `policy.yaml` judges tool calls, and an unreachable policy
    plane refuses them. A `{{secret:NAME}}` handle is not a raw secret and resolves
    as before. `TOKENFUSE_MCP_LOCK` stays unset: pinning tool definitions needs a
    lock file somebody approved. @measured scratch compose project from this
    compose.yaml (`docker compose -p ssbroker --profile typed up -d init-volumes
    policy-db wardryx typryx tokenfuse-mcp-broker`, tokenfuse v1.14.0, typryx
    v0.4.1, wardryx v1.5.0, probed from a busybox on its network) 2026-10-17:
    `tools/list` 200 with typryx's tools under the block scan, an `ask` with an agent
    id answered, without one 400, a raw AWS example key id `-32002`, no broker key
    401, `shell_exec` for a drill identity `-32004` by the starter policy, and with
    wardryx stopped `-32004 ... failmode=Closed applied`.
    *(gate: `scripts/broker-blocks-raw-secrets.sh`: the compose subjects from their
    image and `mcp-broker` command, the resolved configuration with nothing set, and
    the image compose resolves run with those switches and no network, which must
    refuse a raw AWS key id `-32002` and a harmless call `-32004` closed; refuses OK
    on no broker, no Docker or an image that never answered;
    `features/the-mcp-broker-blocks-raw-secrets.feature`; teeth in
    `scripts/gates-have-teeth.sh`. Not covered: the scan's block mode in the running
    image (no upstream serves it a poisoned listing here; held by the static and
    resolved halves and the measurement above), tool pinning, a real typed backend
    behind the broker, and stack-k8s's broker manifest.)*

37. **The gateway's policy-plane key is a `pep`, on a new box and on a box re-run.**
    `@decided 2026-10-18` (paraphrased, from the wardryx 2.0.0 release that
    closes the policy-plane findings of the 2026-10-17 review): an enforcement
    point asks for decisions and does not rewrite policy, so the release refuses
    a viewer key on `POST /v1/decide` and `POST /v1/filter-tools`. `@claude
    2026-10-18`: the gateway, the MCP broker and scopyx present this one key on
    every governed call, and with failmode closed a refused decision refuses the
    call, so a viewer key would refuse every governed call the moment wardryx took
    the new image. install.sh mints the entry as `:default:pep`, and a `.env`
    minted before this release keeps `viewer` on every re-run, which leaves
    `.env` as is. So `wardryx_gateway_role` (between the `# wardryx-role:`
    markers) rewrites that one entry, role only, before the first `up`: the
    secret, the org, an agent list, every other entry and every other line stay
    byte for byte, and the admin key is never rewritten.
    *(gate: `scripts/wardryx-gateway-key-is-pep.sh`: the fresh `.env` line gives
    the gateway's key `pep` and no line in install.sh gives it `viewer`; the
    lifted block, run in scratch `.env` files, moves the gateway's own entry and
    nothing else, leaves a `pep` entry, a key that only begins with the gateway's
    secret and a `.env` with no gateway line alone, and creates no `.env`; the
    call comes before the first `up`. Scenarios in
    `features/the-gateway-key-is-a-pep.feature`; nine teeth cases in
    `scripts/gates-have-teeth.sh`. Not covered: that wardryx 2.0.0 answers `pep`
    on `/v1/decide` (the install's own checks, which CI's install.yml runs on a
    fresh runner, not run here), and an `.env` edited by hand to hold a second
    gateway entry.)*

38. **An agent has no route out of the box except through the doors, and no
    plane is on an agent's network.** `@decided 2026-10-18` (paraphrased, wave 1
    of the 2026-10-17 agent-security review, design decision D6 a: containers
    only, with no host firewall change): an agent that could reach a
    model provider directly did not need the metered gateway, because every
    container shared one network with a route to the internet (finding F-014).
    `@claude 2026-10-18`: the networks are declared in compose.yaml. `edge` is
    the one network with a route out, and its members are the services that need
    the internet, listed in `scripts/network-membership.sh`. `agents` is internal
    and holds only the doors (the two gateways and the MCP broker), scopyx, the
    browser, the console and costcrew. `core` is internal and holds the planes.
    `risk-signal` is internal, as it was in use, now declared so. `front` is not
    internal and has masquerade off, so a published port reaches the host without
    a route out. The browser is on `agents`, `edge` and `browser-policy`, not on
    `core`; `browser-policy` is internal and holds exactly scopyx-browser and
    wardryx, the browser's one path to a decision. typryx and
    its risk-signal proxy also get `edge`, through `compose.override.yaml`, only
    when `TYPED_MODE` is `jev` or `own-model`; install.sh writes that file and no
    other. The host firewall is not touched (design decision D6 a).
    `.github/workflows/install.yml` runs a container on `agents` on a fresh runner:
    it must reach the gateway, and must not resolve or reach example.com or
    1.1.1.1, or reach wardryx by name, after a positive control on `edge`. A second
    container, on `browser-policy`, must reach wardryx and neither the gateway nor
    example.com.
    *(gate: `scripts/network-membership.sh`: the resolved configuration against
    the table in the gate, for the stock box and each egress choice, the network
    properties, the install probes present; teeth in `scripts/gates-have-teeth.sh`;
    scenarios in `features/the-agent-networks-are-internal.feature`. Not covered:
    a container failing to reach the internet on the fresh runner is proven only
    by that workflow step, and it has not run yet; the `front` network's masquerade
    behaviour was measured on Docker Desktop only; the browser's own route over
    `edge` is open by design; and no fetch through the `egress-browser` profile has
    been decided by wardryx in CI, only the network path to wardryx is checked.)*

39. **The provider key is held by the gateway, read from a file, and no agent-facing
    service carries it.** `@decided 2026-10-18` (paraphrased, wave 1 of the
    2026-10-17 agent-security review, its design section 2 and decision D9): an
    agent that holds the provider key can call the model with no gateway in the
    way, and the gateway used to forward whatever key a caller sent (finding F-002).
    So each door reads its provider key from a file, `TOKENFUSE_UPSTREAM_KEY_FILE`,
    that the installer writes mode 0400 and owned by uid 10001, the uid the gateway
    runs as, mounted read only into that door alone: `./upstream/anthropic` for the
    Anthropic door, `./upstream/openai` for the OpenAI door. `@claude 2026-10-18`:
    the agent presents its gateway credential and the door supplies the provider
    credential. Once the key is held, a caller's own provider key is refused 401
    `provider_credential_refused` (tokenfuse invariant 122, tokenfuse v1.16.0). The
    installer takes the key as a file, `ANTHROPIC_KEY_FILE` or `OPENAI_KEY_FILE`,
    and never prints it. Felyx, the console's copilot, presents its own gateway key,
    `GENARYX_COPILOT_FUSE_KEY` (invariant 35), and no longer has the provider key as
    `GENARYX_COPILOT_KEY`; a re-run copies that value into the key file once, and the
    `.env` line stays, unused. With no key file the gateway forwards the caller's
    own key as before and says so at startup and in the closing report.
    *(gate: `scripts/no-provider-key-outside-the-gateway.sh`: the resolved
    configuration of every gateway; no service carries a provider key as an
    environment value or by reference; each door reads its own file from its own
    read-only directory and no other service mounts one; the installer's
    `# upstream-key:` block writes the file 0400 for uid 10001; refuses to report
    OK on no gateway subject, no compose file or no installer block; 10 teeth cases
    in `scripts/gates-have-teeth.sh`; `features/the-provider-key-stays-with-the-gateway.feature`.
    Not covered: a live refused call from a caller that holds a provider key, which
    needs a running stack; the MCP broker, which holds no provider key and is not
    judged here; the fire drills' key, `GATEWAY_DRILLS_KEY`, is minted into the map
    but the console does not present it until a console image carries mockryx's
    key flag (release lane); CostCrew, which is not given a gateway here, because
    invariant 24 keeps the add-on out of the core until the owner decides otherwise.)*

## Decisions that have no gate yet

This list is debt, and it is here to stay visible rather than to be tidy.

**Held by this file alone: invariants 2 and 3.** Invariant 4 is half held.

Invariant 2 is the one that matters and the one that has actually broken. It
needs a disposable VM and a two-run script, which costs money, so it stays a
discipline until someone funds the box.

**It was broken, and my first account of HOW was wrong. Both are worth keeping.**

`scripts/shell-lint.sh` was made able to fail, shellcheck raised SC2015 on

```sh
[ -d genaryx ] && mv genaryx genaryx-a360 2>/dev/null || true
```

and I reported that a re-run moves the fresh clone inside the old directory as
`genaryx-a360/genaryx` and builds the stale top level. **That does not happen.**
I proved the `mv` semantics in a scratch directory and never checked whether
`install.sh` reaches that state. It does not: the clone is guarded by
`[ -d "$SRC_DIR/genaryx-a360" ]`, so on a re-run nothing is cloned and `genaryx`
never exists. Proving a mechanism is not proving reachability.

**The real defect was next to it, and simulating the actual branches found it.**
That same guard could not tell "the operator dropped their own source here" from
"we put it here on the last run". After run one it always took the first
reading, so the console was never refreshed again while the other seven
repositories were pulled every time. `stack-single` updated everything except
its own console, silently. Three simulated runs built run one's source every
time.

Fixed by cloning straight into `genaryx-a360` and deciding on `.git`, exactly as
the loop above already does per repository. The `mv` is gone, so the nesting
hazard goes with it. Verified across three cases: repeated runs now refresh,
operator-supplied source that is not a checkout is left alone, and an upgrade
from the old layout is picked up as a checkout because the old flow left
`genaryx-a360/.git` in place.

Invariant 5's gate was written the day the thing it checks broke a live
install, so unlike the others it is a repair with a ratchet on top rather than
a ratchet alone. Its own first draft is the lesson worth keeping: checking
every `COPY` source reported eleven failures on a tree that builds perfectly,
because build ARGs, glob patterns and sibling repositories are not paths it can
resolve. It now judges `images/` only. A check that cries wolf is switched off,
and then the real thing it would have caught goes through.

Invariant 6's gate is a ratchet, not a repair. Both properties it checks were
already true when it was written.

## Standing rule

An approved architecture decision is **not finished** until it is two things: a
numbered invariant in this file, and a gate in a script if it can be checked
structurally. Until then it is a document, and documents do not stop code.

## Money

Anything that provisions a machine to test this installer spends real money.
Tell the user the expected cost before starting, and confirm the teardown
afterwards. Creating infrastructure is the user's decision every time.

## Conventions

- **No long dashes** anywhere: not in scripts, docs, commit messages, or PR
  bodies. Use a comma, a colon, parentheses, or a short hyphen.
- Do not delete or revoke keys, tokens, or certificates on your own initiative.
