#!/usr/bin/env bash
# Renders a real page through scopyx-browser and shows both sandboxes were on while it did.
#
# Both, because either alone is a thing a person could mistake for the pair: the container's
# filter is on whether or not Chrome started its sandbox, and Chrome's sandbox can start in a
# container whose filter is off. So it reads the two from different places, during the render:
#
#   the container's filter  the profile text Docker holds for the container, byte for byte the
#                           file, and Seccomp: 2 on PID 1.
#   Chrome's sandbox        a renderer in a PID namespace of its own (NSpid has a second column),
#                           in a user namespace of its own (a uid_map of one line for one id),
#                           and under a second seccomp filter, Chrome's own, on top of Docker's.
#
# With --no-sandbox a renderer has none of those three, which is how this was seen to go red.
#
#   CONTAINER=name DOOR_URL=http://ip:4300/ DOOR_KEY=key PAGE_URL=https://... \
#   PROFILE=seccomp/chromium-v1.json ./measure.sh
#
# Reads only. It starts nothing and stops nothing.
set -euo pipefail
: "${CONTAINER:?the browser container}" "${DOOR_URL:?the door of scopyx}" "${DOOR_KEY:?a key of SCOPYX_KEYS}"
: "${PAGE_URL:?a real page}" "${PROFILE:?the profile file compose.yaml names}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
say() { printf '%-5s %s\n' "$1" "$2"; [ "$1" != FAIL ] || fail=1; }

docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$CONTAINER" >"$work/secopt.json"
python3 - "$work/secopt.json" "$PROFILE" <<'PY' || fail=1
import json, sys
opts = json.load(open(sys.argv[1]))
want = json.dumps(json.load(open(sys.argv[2])), separators=(",", ":"))
held = [o[len("seccomp="):] for o in opts if o.startswith("seccomp=")]
if held and json.dumps(json.loads(held[0]), separators=(",", ":")) == want:
    print("PASS  Docker holds the profile file for this container, byte for byte")
else:
    print("FAIL  what Docker holds is not the profile file: " + " ".join(o[:40] for o in opts))
    sys.exit(1)
print("      options: " + " ".join(o if not o.startswith("seccomp=") else "seccomp=<the file>" for o in opts))
PY
printf '      AppArmor: %s\n' "$(docker inspect --format '{{.AppArmorProfile}}' "$CONTAINER")"
pid1="$(docker exec "$CONTAINER" sh -c 'grep -E "^(Seccomp|NoNewPrivs):" /proc/1/status | tr -s "\t " " " | tr "\n" " "')"
case "$pid1" in
  *"Seccomp: 2"*) say PASS "the container's filter is on: $pid1" ;;
  *) say FAIL "the container's filter is not on: $pid1" ;;
esac

# The renderer lives for a second or two, so it is watched from before the page is asked for.
# Its own filter comes up a moment after it starts, which is why this waits for the second one.
docker exec "$CONTAINER" sh -c '
  i=0; seen=""
  while [ "$i" -lt 600 ]; do
    for p in /proc/[0-9]*; do
      { tr "\000" " " <"$p/cmdline"; } 2>/dev/null | grep -q -- "--type=renderer" || continue
      s="$(grep -E "^(Seccomp|Seccomp_filters|NSpid):" "$p/status" 2>/dev/null | tr -s "\t " " " | tr "\n" ";")"
      m="$(tr -s " " <"$p/uid_map" 2>/dev/null | tr "\n" ";")"
      [ -n "$s" ] || continue
      seen="$s uid_map:$m"
      case "$s" in *"Seccomp_filters: 1;"*) ;; *) echo "$seen"; exit 0 ;; esac
    done
    i=$((i + 1)); sleep 0.1
  done
  echo "$seen"' >"$work/renderer" 2>/dev/null &
watcher=$!
sleep 0.3
# The key goes on curl's stdin, never on an argument list.
code="$(printf 'header = "content-type: application/json"\nheader = "X-Scopyx-Key: %s"\n' "$DOOR_KEY" \
  | curl -s -m 120 -K - -o "$work/browse.json" -w '%{http_code}' -X POST "$DOOR_URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browse","arguments":{"url":"'"$PAGE_URL"'"}}}')"
python3 - "$work/browse.json" "$code" "$PAGE_URL" <<'PY' || fail=1
import json, sys
path, code, url = sys.argv[1:4]
try:
    d = json.load(open(path))
except ValueError:
    print(f"FAIL  browse answered HTTP {code}, and not JSON")
    sys.exit(1)
r = d.get("result") or {}
text = " ".join(c.get("text", "") for c in r.get("content", []))
if d.get("error") or r.get("isError") or "<html" not in text.lower():
    print("FAIL  browse did not render " + url + ": " + (text or json.dumps(d))[:400])
    sys.exit(1)
print(f"PASS  browse rendered {url}: {len(text)} characters of HTML")
PY
wait "$watcher" || true
renderer="$(cat "$work/renderer")"
printf '      renderer: %s\n' "${renderer:-none seen}"
[ -n "$renderer" ] || say FAIL "no renderer was seen, so Chrome's sandbox was not read"
if [[ "$renderer" =~ NSpid:\ [0-9]+\ [0-9]+ ]]; then
  say PASS "the renderer is in a PID namespace of its own"
else
  say FAIL "the renderer is in the container's PID namespace"
fi
case "$renderer" in
  *"Seccomp: 2;"*"Seccomp_filters: 1;"*) say FAIL "the renderer has one seccomp filter, Docker's: Chrome's own is not on" ;;
  *"Seccomp: 2;"*) say PASS "the renderer runs under Chrome's own filter on top of Docker's" ;;
  *) say FAIL "the renderer has no seccomp filter" ;;
esac
case "$renderer" in
  *"uid_map: 4294967295"*|*" 0 4294967295;"*) say FAIL "the renderer is in the container's user namespace" ;;
  *"uid_map:"*" 1;"*) say PASS "the renderer is in a user namespace of its own" ;;
  *) say FAIL "the renderer's uid_map was not read" ;;
esac
exit "$fail"
