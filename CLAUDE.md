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
```

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
5. **Fail before doing half the job.** Check preconditions up front and refuse,
   rather than starting and leaving the machine in a state neither installed nor
   clean. *(gate: `scripts/fail-before-half-the-job.sh`, which requires every
   refusal to precede the first side effect, and every fetch, clone and service
   start to carry `|| die`)*

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

Invariant 5's gate is a ratchet, not a repair. Both properties it checks were
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
