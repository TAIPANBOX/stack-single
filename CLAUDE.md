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

**And it is broken right now, in `install.sh`, measured 2026-08-01.** The
console is staged with:

```sh
[ -d genaryx ] && mv genaryx genaryx-a360 2>/dev/null || true
```

On a first run this is fine. On a re-run `genaryx-a360` already exists, so `mv`
moves the freshly cloned `genaryx` INSIDE it, as `genaryx-a360/genaryx`. The
command succeeds, `|| true` would have swallowed a failure anyway, and the
`docker build` two lines down reads the stale top level. **The second run builds
the console from the previous run's source and says nothing.** Reproduced in a
scratch directory: after run two, the marker file still reads run one's content.

The fix is to clone into `genaryx-a360` directly and delete the `mv`, which adds
no destructive operation. It is NOT applied yet: it changes what a root
installer does on somebody else's machine, and that is the user's call.

Found by shellcheck (SC2015) after `scripts/shell-lint.sh` was made capable of
failing. The previous lint step ran `shellcheck ... || bash -n ...`, so every
finding fell through to a syntax check and the step was green for its whole
life. Note that this defect needs no VM to see: it is two `mkdir`s and an `mv`.

**Invariant 4 was mis-stated, and the check this section used to ask for would
have been theatre.** The old note wanted a grep for `df -T`, `readlink -f` and
`sed -i` without a portable fallback. Reading `install.sh` first shows why that
is the wrong check twice over. The file contains exactly one of those, a
`sed -i` at line 498, and it is inside a message telling the operator how to
widen the bind, not a command this script runs: the grep would have failed on
prose. And the reason it can afford GNU at all is the preflight at line 64,
which refuses any host that is not Debian or Ubuntu before touching the machine.
So what needs holding is the fence, not the userland behind it, and that is what
the gate now does. The unheld half is real: nothing stops portability-dependent
code being added outside the fence, and nothing notices if the fence is widened
to a distro where these differ.

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
