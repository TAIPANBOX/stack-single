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
   *(gate: `scripts/gates-have-teeth.sh`, 11 cases: six real faults, one
   non-fault, and four subjects taken away. Two cases mutate the stack-k8s TREE
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
    *(gate: `scripts/bind-is-honoured.sh`, which refuses to report OK when the
    gateway check or the `case "$GATEWAY_BIND"` block is gone; teeth in
    `scripts/gates-have-teeth.sh`)*

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
