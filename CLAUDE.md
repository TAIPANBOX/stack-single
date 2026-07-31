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

There is no CI in this repo, so the local gate is the only gate.

## Gates

```sh
shellcheck install.sh
bash -n install.sh
./scripts/closed-by-default.sh
```

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
4. **Never assume GNU.** This installer meets whatever userland the host has.
   `df -T`, `mount` output, `sed -i` and `readlink -f` all differ, and a helper
   that misreports rather than failing is worse than one that errors.
   *(not enforced)*
5. **Fail before doing half the job.** Check preconditions up front and refuse,
   rather than starting and leaving the machine in a state neither installed nor
   clean. *(not enforced)*

## Decisions that have no gate yet

This list is debt, and it is here to stay visible rather than to be tidy.

**Held by this file alone: invariants 2, 3, 4 and 5.**

Invariant 2 is the one that matters and the one that has actually broken. It
needs a disposable VM and a two-run script, which costs money, so it stays a
discipline until someone funds the box. Invariant 4 is partly checkable: fail
if the script calls `df -T`, `readlink -f` or `sed -i` without a portable
fallback beside it.

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
