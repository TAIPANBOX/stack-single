# Security Policy

stack-single is a curl-pipe-bash installer that brings up the governed agent
stack, as root, on a single machine the operator owns, so its trust boundary
is that machine and every secret `install.sh` writes to it.

## Reporting a vulnerability

Please report security issues privately, not in public issues or pull
requests: open a GitHub private security advisory at
<https://github.com/TAIPANBOX/stack-single/security/advisories/new>. Include
the affected version or commit, a description and a minimal reproduction. We
aim to acknowledge within a few days and to fix high-severity issues before
any public disclosure, with coordinated disclosure within 90 days of the
report. There is no bug-bounty programme; reporters are credited in the
advisory unless they prefer otherwise.

## Supported versions

Before this repository's 1.0, only `main` is supported: fixes land on `main`
and are not backported. From its 1.0 tag, the newest minor gets every fix and
the previous minor gets security-relevant fixes for 90 days after the newer
one is tagged.

## Verifying a build

Every change passes the repository's gates before merge: `scripts/shell-lint.sh`,
`scripts/closed-by-default.sh`, `scripts/fail-before-half-the-job.sh`,
`scripts/build-context-complete.sh` and `scripts/gates-have-teeth.sh`.
