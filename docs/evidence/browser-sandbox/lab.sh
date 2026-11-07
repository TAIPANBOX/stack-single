#!/usr/bin/env bash
# The browser's sandbox on this host, in a Compose project of its own: `browserlab`.
#
# The real compose.yaml and the real profile, with one stand-in: wardryx in memory, allowing
# every fetch, because the question here is the sandbox and not the policy. It takes the same
# steps as install.sh for the AppArmor line, then renders a real page, then proves each thing it
# claims by taking it away.
#
#   ./lab.sh <a checkout of this repository> [page]
#
# Needs Docker and python3, and a route to the page. It uses test values only, publishes no port,
# and touches no project but its own. It leaves nothing behind.
set -euo pipefail
tree="$(cd "${1:?a checkout of this repository}" && pwd)"
page="${2:-https://en.wikipedia.org/wiki/Sandbox_(computer_security)}"
here="$(cd "$(dirname "$0")" && pwd)"
project=browserlab
lab="$(mktemp -d /var/tmp/browserlab-run.XXXXXX)"
key=labkey0123456789labkey0123456789
pep=labpep0123456789labpep0123456789
wardryx="$(sed -n 's/^    image: \${WARDRYX_IMAGE:-\(.*\)}$/\1/p' "$tree/compose.yaml")"
cd "$lab"
cp "$tree/compose.yaml" .
cp -R "$tree/seccomp" .
python3 - <<'PY'
import re
src = open("compose.yaml").read()
with open(".env", "w") as f:
    for n in sorted(set(re.findall(r"\$\{([A-Za-z0-9_]+):\?", src))):
        f.write(f"{n}=x\n")
PY
printf -- '- name: lab-allow\n  target: "*"\n' >lab-policy.yaml
dc() { docker compose -p "$project" -f compose.yaml -f lab.override.yaml --profile egress-browser "$@"; }
finish() {
  [ ! -f lab.override.yaml ] || dc down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$lab"
}
trap finish EXIT
up() { # EXTRA-LINES-FOR-THE-BROWSER...
  {
    cat <<YAML
services:
  lab-policy:
    image: $wardryx
    user: "65532:65532"
    command: [serve, -addr, "0.0.0.0:8090", -events, /tmp/e.ndjson, -policy, /etc/wardryx/policy.yaml]
    environment:
      WARDRYX_KEYS: $pep:default:pep
    tmpfs: ["/tmp:size=16m,uid=65532,gid=65532"]
    volumes: ["./lab-policy.yaml:/etc/wardryx/policy.yaml:ro"]
    networks:
      browser-policy:
        aliases: [wardryx]
  scopyx-browser:
    environment:
      SCOPYX_WARDRYX_KEY: $pep
      SCOPYX_KEYS: $key=agent://lab.invalid/agent
YAML
    printf '%s\n' "$@"
  } >lab.override.yaml
  dc up -d --force-recreate lab-policy scopyx-browser >up.log 2>&1 || { tail -5 up.log; return 1; }
  ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${project}_browser-broker\").IPAddress}}" "$project-scopyx-browser-1")"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -m2 -o /dev/null "http://$ip:4300/"; then break; fi
    sleep 1
  done
}
measure() {
  CONTAINER="$project-scopyx-browser-1" DOOR_URL="http://$ip:4300/" DOOR_KEY="$key" PAGE_URL="$page" \
    PROFILE=seccomp/chromium-v1.json "$here/measure.sh"
}
browse_says() { # what one fetch answers, in a line
  curl -s -m 120 -X POST "http://$ip:4300/" -H 'content-type: application/json' -H "X-Scopyx-Key: $key" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browse","arguments":{"url":"'"$page"'"}}}' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or {}; t=" ".join(c.get("text","") for c in r.get("content",[])); print(("refused: "+t[:170]) if r.get("isError") else f"rendered, {len(t)} characters")'
}

# The pick, by the installer's own block.
STACK_DIR="$lab"
note() { printf '   %s\n' "$*"; }
picked=""
env_set_if_changed() { picked="$2"; }
eval "$(grep '^BROWSER_SECCOMP=' "$tree/install.sh")"
eval "$(sed -n '/^# browser-apparmor: begin$/,/^# browser-apparmor: end$/p' "$tree/install.sh")"
printf '%s, Docker %s, Compose %s\n' "$(. /etc/os-release; printf '%s' "$PRETTY_NAME")" "$(docker version --format '{{.Server.Version}}')" "$(docker compose version --short)"
browser_apparmor_apply
[ -n "$picked" ] || { echo "FAIL: the installer's block picked nothing on this host"; exit 1; }
other=unconfined
[ "$picked" = docker-default ] || other=docker-default
printf 'SCOPYX_BROWSER_APPARMOR=%s\n' "$picked" >>.env

echo; echo "== as shipped: the profile, the baseline, the line the installer picked"
up
measure
echo; echo "== the file's refusals, from inside the same container"
for flags in "-Ur" "-Urm" "-Urn" "-Uri" "-Uru"; do
  if docker exec "$project-scopyx-browser-1" unshare "$flags" true >/dev/null 2>&1; then a=allowed; else a=refused; fi
  printf '   unshare %-5s %s\n' "$flags" "$a"
done
echo; echo "== a second run recreates nothing"
before="$(docker inspect -f '{{.Id}}' "$project-scopyx-browser-1")"
dc up -d lab-policy scopyx-browser >/dev/null 2>&1
[ "$before" = "$(docker inspect -f '{{.Id}}' "$project-scopyx-browser-1")" ] && echo "   same container" || echo "   FAIL: recreated"

echo; echo "== control: the other AppArmor line"
sed -i "s/^SCOPYX_BROWSER_APPARMOR=.*/SCOPYX_BROWSER_APPARMOR=$other/" .env
up
printf '   apparmor=%s: %s\n' "$other" "$(browse_says)"
sed -i "s/^SCOPYX_BROWSER_APPARMOR=.*/SCOPYX_BROWSER_APPARMOR=$picked/" .env

echo; echo "== control: Docker's default filter, without the profile"
up "    security_opt: !override" "      - no-new-privileges:true" "      - apparmor=$picked"
printf '   default filter: %s\n' "$(browse_says)"

echo; echo "== control: each rule taken out of the profile"
python3 - <<'PY'
import json
p = json.load(open("seccomp/chromium-v1.json"))
for gone in ("chroot", "clone", "unshare"):
    q = dict(p, syscalls=[r for r in p["syscalls"] if not (str(r.get("comment", "")).startswith("chromium-v1:") and gone in r["names"])])
    json.dump(q, open(f"seccomp/without-{gone}.json", "w"))
PY
for gone in chroot clone unshare; do
  up "    security_opt: !override" "      - seccomp:./seccomp/without-$gone.json" "      - no-new-privileges:true" "      - apparmor=$picked"
  printf '   without %-8s %s\n' "$gone:" "$(browse_says)"
done

echo; echo "== control: Chrome's sandbox off, so measure.sh has to go red"
up '      SCOPYX_CHROMIUM_NO_SANDBOX: "1"'
if measure; then echo "   FAIL: measure.sh passed with Chrome's sandbox off"; exit 1; else echo "   measure.sh went red, as it must"; fi
