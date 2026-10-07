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
./scripts/features-are-bound.sh
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
    *(gate: `scripts/bus-has-a-writer.sh`, which refuses to report OK when the
    gateway, init-volumes, or every writable volume has been taken away;
    teeth in `scripts/gates-have-teeth.sh`)*

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
    *(gate: `scripts/bind-is-honoured.sh`, which refuses to report OK when the
    gateway check or the `case "$GATEWAY_BIND"` block is gone; teeth in
    `scripts/gates-have-teeth.sh`)*

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
    *(gate: `scripts/felyx-through-the-gateway.sh`; teeth in
    `scripts/gates-have-teeth.sh`)*

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
    typryx on its stub backend, which makes no outbound call. `jev` needs
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
    compose.yaml, components.json, README.md and install.sh to be the one pin (v0.4.0
    since 2026-10-04, the release the risk-signal proxy needs; v0.3.0 was the first
    with the training log); it
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
    almost never arrive. Nothing seeds a `hold_if_signal` policy. `@claude`: the
    broker was NOT a policy enforcement point on this launcher before (it never
    set `TOKENFUSE_WARDRYX_URL`), so turning the signal on makes every tool call
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
    URLs, requires typryx 0.4.0, wardryx 1.2.0 and tokenfuse 1.5.0 or later, no
    seeded `hold_if_signal` and one in the README, and refuses to report OK on no
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
    estate, not a bill of yours.)*

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
