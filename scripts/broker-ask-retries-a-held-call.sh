#!/usr/bin/env bash
#
# CLAUDE.md invariant 79: the installer's ask through the MCP broker reads a call held for a person as held,
# asks again a bounded number of times, and reads every other failure at once.
#
# WHY
#
# With the typed risk signal on, the broker asks the proxy for a risk class on every tool call, and the seeded
# rule (invariant 57) holds a call that arrives with no signal. A proxy backed by a hosted model can miss its
# deadline on the first call after a quiet night, so the installer's own `ask` came back "requires approval"
# and the check printed FAIL on a healthy box, measured on forge 2026-11-15 06:14 (proxy log
# `reason=unanswered:timeout`, broker log `wardryx held tool call`); the same run on the same tree passed ten
# minutes later. The same call in the same run is the same pending hold, so asking again is safe, and it goes
# through once the signal answers. Anything else (a refusal, an error from typryx, no answer) is a real fault
# and must fail on the first try.
#
# HOW
#
# Lifts the `# mcp-ask:` block out of install.sh and runs mcp_ask_answered against a stub http_request that
# plays a list of answers, with `sleep` stubbed so no case waits. Requires: an answer on the first call is ok
# after one call; held, held, answered is ok after three; held for ever fails after a bounded number of calls;
# an error that is not a hold fails after one call; and the request still names the agent and the run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
problem() { echo "FAIL: $*"; fail=1; }

block="$(sed -n '/^ *# mcp-ask: start/,/^ *# mcp-ask: end/p' install.sh)"
if [ -z "$block" ] || ! grep -q 'mcp_ask_answered()' <<<"$block"; then
  echo "FAIL: no '# mcp-ask:' block with mcp_ask_answered in install.sh, so this gate measured nothing"
  exit 1
fi

ANSWERED='HTTP/1.1 200 OK\r\n\r\n{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{}"}],"isError":false}}'
HELD='HTTP/1.1 200 OK\r\n\r\n{"jsonrpc":"2.0","id":1,"error":{"code":-32004,"message":"wardryx: requires approval (approval ap_0123456789abcdef)"}}'
BROKEN='HTTP/1.1 200 OK\r\n\r\n{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"typryx: bad key"}],"isError":true}}'

# run_with <answers...>: prints "<exit> <calls>"; the request headers of the first call go to $T/hdrs.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
run_with() {
  printf '%s\n' "$@" >"$T/answers"
  : >"$T/calls"
  (
    # shellcheck disable=SC2329,SC2317  # both called by the lifted block through eval
    sleep() { :; }
    # shellcheck disable=SC2329,SC2317
    http_request() {
      local n; n=$(($(wc -l <"$T/calls") + 1)); echo x >>"$T/calls"
      [ "$n" -eq 1 ] && printf '%s' "$3" >"$T/hdrs"
      local a; a="$(sed -n "${n}p" "$T/answers")"; [ -n "$a" ] || a="$(tail -n 1 "$T/answers")"
      printf '%b' "$a"
    }
    eval "$block"
    mcp_ask_answered http://tokenfuse-mcp-broker:4200/mcp k3y
  )
  echo "$? $(wc -l <"$T/calls" | tr -d ' ')"
}

r="$(run_with "$ANSWERED")"
[ "$r" = "0 1" ] || problem "an answer on the first call: want 'exit 0 after 1 call', got '$r'"
grep -q 'x-fuse-agent-id: agent://local.invalid/install-check' "$T/hdrs" || problem "the ask no longer names the install-check agent"
grep -q 'x-fuse-run-id: install-check-broker' "$T/hdrs" || problem "the ask no longer names its run"

r="$(run_with "$HELD" "$HELD" "$ANSWERED")"
[ "$r" = "0 3" ] || problem "held, held, then answered: want 'exit 0 after 3 calls', got '$r' (a held call is not asked again)"

r="$(run_with "$HELD")"
case "$r" in
  "0 "*) problem "a call held for ever reads as answered: '$r'" ;;
  *" 1") problem "a call held for ever is asked only once: '$r'" ;;
esac
n="${r#* }"; [ "$n" -le 6 ] || problem "a call held for ever is asked $n times; the retry must be bounded (at most 6)"

r="$(run_with "$BROKEN")"
[ "$r" = "1 1" ] || problem "an error that is not a hold: want 'exit 1 after 1 call', got '$r' (a real fault must not be retried)"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "OK: the broker ask is answered on the first call, asks again after a hold (bounded at $n calls), and fails at once on any other error; it names its agent and run (invariant 79)."
