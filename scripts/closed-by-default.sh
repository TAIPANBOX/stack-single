#!/usr/bin/env bash
# Enforces invariant 1 of CLAUDE.md: the stack comes up closed.
#
# This is a curl-pipe-bash installer that runs as root on somebody else's
# machine. If a default publishes a service beyond the host, we have made a
# security decision on their behalf and they will find out later, from somebody
# else. The gateway binds loopback until the operator says otherwise.
#
# Checks the DEFAULT in the parameter expansion, so an operator overriding
# GATEWAY_BIND in their environment is fine and is the supported path. What is
# not fine is the shipped default changing.
#
# This file is the ONE copy of this check. The local hook calls it, and CI would
# call the same file if this repo ever gets CI.

set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

default="$(sed -n 's/^GATEWAY_BIND="\${GATEWAY_BIND:-\([^}]*\)}"$/\1/p' install.sh | head -1)"

if [ -z "$default" ]; then
	echo "FAIL: could not find the GATEWAY_BIND default in install.sh"
	echo "      Either it was renamed or the shape changed. Do not delete this"
	echo "      check to make it pass: work out what replaced it and check that."
	fail=1
elif [ "$default" != "127.0.0.1" ] && [ "$default" != "localhost" ] && [ "$default" != "::1" ]; then
	echo "FAIL: GATEWAY_BIND defaults to '$default', which is not loopback"
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo
	echo "The stack comes up closed. Publishing beyond the host is the operator's"
	echo "explicit decision, never a shipped default. See CLAUDE.md invariant 1."
	exit 1
fi

echo "OK: gateway binds loopback by default ($default)."
