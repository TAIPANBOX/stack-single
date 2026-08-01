#!/usr/bin/env bash
# Lints install.sh, and unlike its predecessor it can actually fail.
#
# The pre-push hook used to run:
#
#     command -v shellcheck >/dev/null && shellcheck install.sh || bash -n install.sh
#
# In `A && B || C`, a failing B runs C. So every shellcheck finding fell through
# to `bash -n`, which only checks syntax and passes on almost anything. That step
# had been green for its whole life while shellcheck exited 1 with five findings.
# A check that cannot fail is worse than no check: it occupies the slot.
#
# THE FIVE FINDINGS WERE ALL FALSE, and each is silenced AT ITS LINE in
# install.sh with the reason beside it, not by a flag here:
#
#   SC2154  `rc is referenced but not assigned`, on the trap. It is assigned in
#           that same trap string; shellcheck does not look inside single-quoted
#           trap arguments.
#   SC1091  `Not following /etc/os-release` and `./.env`. Both live on the
#           target machine, not in this repo.
#   SC2329  `probe() and code() are never invoked`. They are, indirectly: both
#           are passed as strings to `check`, which evaluates them. shellcheck
#           says as much in its own message.
#
# THE FIRST VERSION OF THIS FILE PASSED THEM AS `-e SC1091,SC2154,SC2329`, AND
# THAT WAS WRONG. Break-testing it showed a genuinely undefined variable
# (`NET="$undefined_thing"`) producing two SC2154 findings with plain shellcheck
# and ZERO through the exclusion. Silencing a code everywhere to quiet one true
# negative throws away every real instance of it. Per-line directives cost four
# comments and keep the code live in the other 500 lines.
#
# So: never add a code to a flag here. Silence it at the line, with the reason.
#
# SHELLCHECK VERSIONS DISAGREE, so the directives name every code that applies.
# 0.11 on this machine reports the unreachable-function case as SC2329; the
# older build on ubuntu-latest reports the same thing as SC2317. The first CI
# run went red on exactly that, and on two SC2015 findings that 0.11 does not
# raise at all. Anything that lints has to be told what it may see, not what one
# machine happened to show.
#
# ONE OF THOSE CI-ONLY FINDINGS WAS REAL. SC2015 on the `mv genaryx
# genaryx-a360` line is a genuine second-run defect, measured and written up at
# its own line and in CLAUDE.md invariant 2. A lint step that could not fail had
# been sitting on top of it.
#
# shellcheck is present on ubuntu-latest and on this machine. If it is genuinely
# absent this FAILS rather than falling back, because the fallback is what hid
# the findings in the first place.
#
# This file is the ONE copy of this check. The hook and CI both call it.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "FAIL: shellcheck is not installed, so install.sh was linted by nothing."
  echo "      Install it (brew install shellcheck / apt-get install shellcheck)"
  echo "      rather than skipping: a skipped check reports silence as health."
  exit 1
fi

if ! shellcheck install.sh; then
  echo
  echo "install.sh is curl-piped into bash as root on somebody else's machine."
  echo "If this finding is genuinely false, silence it with a"
  echo "\`# shellcheck disable=SCxxxx\` directive ON ITS OWN LINE, with the reason"
  echo "in a comment above. Do NOT add the code to a flag in this script: that"
  echo "would silence it everywhere, which is how a real one gets lost."
  exit 1
fi

echo "OK: shellcheck passes on install.sh with no codes disabled globally."
echo "    Four findings are silenced at their own lines, each with its reason."
