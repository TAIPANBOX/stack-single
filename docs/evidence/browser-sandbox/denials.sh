#!/usr/bin/env bash
# Shows that apparmor/scopyx-browser keeps what docker-default denies, and that the profile is what
# does the denying and not a missing capability. A throwaway as root with CAP_SYS_ADMIN and Docker's
# own seccomp filter, so the capability and the filter would allow each thing, and `unconfined` is
# the control that it is allowed when no profile stops it. Docker's default masks of /proc and
# /sys are off for the run (systempaths=unconfined), which is why the writes below write back the
# value already there and change nothing on the host; sysrq `h` only prints its help.
#
#   ./denials.sh        needs Docker, busybox:1.36 and apparmor/scopyx-browser loaded on this host
#
# Containers are named aamz-denials-<profile> and removed when they end.
set -euo pipefail
for p in scopyx-browser docker-default unconfined; do
  printf '== apparmor=%s\n' "$p"
  docker run --rm --name "aamz-denials-$p" --cap-add SYS_ADMIN --security-opt systempaths=unconfined \
    --security-opt "apparmor=$p" busybox:1.36 sh -c '
      try() { if out="$("$@" 2>&1)"; then echo "   allowed  $*"; else echo "   denied   $* -> ${out##*: }"; fi; }
      mkdir -p /mnt/t
      try mount -t tmpfs none /mnt/t
      try sh -c "cat /proc/sys/vm/swappiness > /proc/sys/vm/swappiness"
      try sh -c "cat /proc/sys/kernel/printk > /proc/sys/kernel/printk"
      try sh -c "echo h > /proc/sysrq-trigger"
    ' || true
done
