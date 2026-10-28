#!/usr/bin/env bash
#
# Enforces that no message the installer prints interpolates the VALUE of a key,
# a secret, a token or a file that holds one. The installer's own messages name
# the variable, never its contents: a box whose operator puts a key in a *_FILE
# variable by mistake must not get that key back in the log of the failed run.
#
# WHY
#
# install.sh prints its refusals with die, note, say, warn, fail and err. Before
# this gate, three of them printed a value: GATEWAY_HOLDS_COPILOT_KEY in its
# refusal, and IDENTITY_MAP_FILE and CLIENT_KEYS_FILE by their contents' path,
# which is the value of a variable that holds the keys themselves. A path that
# was typed as the key lands in the log the same way the key would.
#
# WHAT IT JUDGES, AND HOW
#
#   Static, over install.sh. A message line is a line that calls one of those
#   commands. A message line FAILS when it expands a variable whose name ends in
#   a secret-bearing suffix (_KEY, _KEYS, _KEY_FILE, _KEYS_FILE, _MAP_FILE,
#   _SECRET, _SECRET_FILE, _TOKEN, _PASSWORD, _PASS, _CREDENTIAL). A variable
#   whose name ends in _VAR, _ENV or _COUNT names something else and is not
#   judged. Writing a secret to a file or a pipe is not a message and is not
#   judged here; the argv gate judges credentials on command lines.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# An install.sh with no message line at all is reported and fails: a gate that
# found nothing to judge has not judged anything.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ ! -f install.sh ]; then
  echo "FAIL: install.sh is not there, so this gate measured NOTHING."
  exit 1
fi

python3 - <<'PY'
import re
import sys

SECRET_SUFFIXES = (
    "_KEY", "_KEYS", "_KEY_FILE", "_KEYS_FILE", "_MAP_FILE",
    "_SECRET", "_SECRET_FILE", "_TOKEN", "_PASSWORD", "_PASS", "_CREDENTIAL",
)
MESSAGE_CALL = re.compile(r'(^|[\s;&|(])(die|note|say|warn|fail|err)\s')
VAR = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?')

judged = 0
problems = []
with open("install.sh", encoding="utf-8") as fh:
    for n, raw in enumerate(fh, 1):
        line = raw.rstrip("\n")
        if line.lstrip().startswith("#"):
            continue
        if not MESSAGE_CALL.search(line):
            continue
        judged += 1
        # Only the text from the message command onward is the message: a variable
        # in a condition or a redirect target before it is not printed.
        message = line[MESSAGE_CALL.search(line).start():]
        names = sorted({m.group(1) for m in VAR.finditer(message)
                        if m.group(1).endswith(SECRET_SUFFIXES)})
        if names:
            problems.append((n, names, line.strip()[:160]))

if judged == 0:
    print("FAIL: install.sh has no message line at all, so this gate measured NOTHING.")
    sys.exit(1)

if problems:
    print("FAIL: an installer message interpolates the value of a key or secret variable:")
    for n, names, text in problems:
        print(f"  - install.sh:{n} expands {', '.join('$' + x for x in names)}: {text}")
    sys.exit(1)

print(f"OK: no message line expands a key or secret value, in {judged} message line(s) of install.sh.")
PY
