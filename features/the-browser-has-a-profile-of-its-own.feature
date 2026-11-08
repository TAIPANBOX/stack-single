# @decided 2026-11-08 (paraphrased): the browser gets an AppArmor profile of its own, so that on
# Debian 13 the installer stops choosing apparmor=unconfined. It is Docker's default profile plus
# what Chrome's sandbox needs, measured on the Debian 13 box, and nothing is added without a measurement.
# @claude 2026-11-08: the one rule measured is `userns,`. The installer keeps the file in
# /etc/apparmor.d, because Docker restarts the container at boot and a profile only the installer
# loaded would be gone by then, and the browser would not start.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways. What ran on a real host is
# docs/evidence/browser-sandbox/lab.sh, and CI's `browser` job.
Feature: the browser has a profile of its own, and the installer stops choosing unconfined

  scopyx-browser reads pages written by whoever wrote them. On Debian 13 Docker's default profile
  refuses the user namespace Chrome's sandbox starts in, so the installer used to fall back to no
  profile at all, which also drops every denial the default profile has.

  Scenario: the profile is Docker's default plus the one rule Chrome's sandbox needs
    Given docker-default denies writes under /proc/sys, mount, and the paths of /sys and /proc the kernel keeps for itself
    When the profile loses a denial, gains a rule docker-default does not have, or loses userns
    Then the gate fails, because that is a wider door than the one it replaced or a browser with no sandbox
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: a rule is added after a denial"
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: deny mount is dropped"
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: a write under /proc/sys is allowed"
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: a denial loses a letter"
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: the userns rule is dropped"
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: the profile is renamed under its file"

  Scenario: a host that can load the profile offers it first
    Given AppArmor is on and apparmor_parser is there
    When the installer asks the host which line Chrome's sandbox starts under
    Then scopyx-browser is asked before docker-default and unconfined, and it is what reaches .env
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: the profile of our own is offered last"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the installer stops offering the profile of our own"
    # -> gates-have-teeth.sh "browser-profile-is-docker-default-plus-userns: the installer stops offering it"

  Scenario: a second run loads nothing again, and an edited profile is loaded
    Given the profile is in place and the kernel holds it
    When install.sh runs again, or the file in the repository changed between two runs
    Then the first loads nothing and the second loads the new file
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: the profile is loaded again on every run"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: an edited profile is never loaded again"

  Scenario: the profile is still there after a reboot
    Given Docker restarts the browser at boot, before anyone runs the installer
    When the installer loads the profile
    Then it keeps the file in /etc/apparmor.d, where the host loads it again
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a loaded profile is kept nowhere for the next boot"

  Scenario: a host that cannot load the profile behaves as it did
    Given AppArmor is off in the kernel, or there is no parser, or the parser refuses the file
    When the installer runs
    Then nothing is loaded and nothing is left in /etc/apparmor.d, and docker-default and unconfined are asked as before
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a parser that refuses the file is read as a load"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a kernel with no AppArmor is asked to load it"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a comment in the profile loader is reworded"

  Scenario: status says what confines the running browser, and can be red
    Given the browser runs under unconfined, or under a profile the host's copy no longer matches, or under a line .env does not name
    When status reads the running container
    Then that line is a FAIL, and a status that never reads it is a gate failure
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: status passes an unconfined browser where ours could be loaded"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: status passes a host copy that is not the stack's"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: status passes a browser that is not under what .env names"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: status never reads the browser's profile"
