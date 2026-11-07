# @decided 2026-11-07 (paraphrased): the browser leaves seccomp:unconfined for a versioned profile
# file, Docker's default plus exactly what Chrome's sandbox needs, and it starts on Debian 13 and on
# Ubuntu 24.04 with nothing for the owner to do: the installer picks per host by measuring, or a
# shipped AppArmor profile does it, whichever is smaller. Measured in a project of its own on
# Debian 13 and in CI on Ubuntu, rendering a real page with both sandboxes on.
# @claude 2026-11-07: measuring is the smaller of the two: a shipped profile is a copy of
# docker-default to keep in step, a load into the host's kernel and a file in /etc/apparmor.d that
# outlives the stack, and this is one line in compose.yaml and a throwaway.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways. What ran on a real host is
# docs/evidence/browser-sandbox/lab.sh, and CI's `browser` job.
Feature: the browser keeps both sandboxes, on either host, with nothing to do

  scopyx-browser reads pages written by whoever wrote them, so two things stand between a hostile
  page and the box: Chrome's sandbox around the renderer, and the container's syscall filter
  around Chrome. Until now one was traded for the other, and which AppArmor line let the sandbox
  start was left for the operator to find.

  Scenario: no service runs with its syscall filter off
    Given the resolved configuration of compose.yaml
    When a service says seccomp:unconfined, the browser included
    Then the gate fails, and no exception can excuse it
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the browser goes back to seccomp:unconfined"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a second service is seccomp:unconfined"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a comment says seccomp:unconfined"

  Scenario: the browser has a profile of its own
    Given Docker's default filter refuses what Chrome's sandbox calls
    When the browser falls back to that default, or its profile has no exception
    Then the gate fails, because the browser would answer browse with an error
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the browser falls to Docker's default filter"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a profile has no exception"

  Scenario: the profile is Docker's default plus exactly what Chrome's sandbox needs
    Given chroot, clone into a user, pid and net namespace, and unshare into a user namespace, each measured by taking it out
    When the profile allows a fourth call, a rule loses its mask, or a default rule is widened
    Then the gate fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a profile allows a fourth call"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: clone loses its mask"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a default rule is widened in the profile"

  Scenario: a change to the profile is a new version
    Given Compose hashes the line that names the file and never the file
    When the file changes under the same name, or a new version has no digest
    Then the gate fails, because a running browser would keep the old filter with every check green
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a profile is edited under the same name"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a new version has no digest"

  Scenario: the browser starts on either supported host with nothing for the owner to do
    Given docker-default refuses Chrome's user namespace on Debian 13, and allows it on Ubuntu 24.04
    When the installer asks the host
    Then the narrowest line the sandbox starts under is in .env, and a host that allows both keeps docker-default
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: the wider line is tried first"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: docker-default is never left"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: nothing calls it"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: the block is gone"

  Scenario: a host that cannot answer is not read as a host that refused
    Given a throwaway that does not start says nothing about the sandbox
    When the installer cannot start one, or the host refuses everything
    Then .env keeps what it held, the run says so, and the install goes on
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a throwaway that never started reads as a refusal"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a host that refuses stops the install"
    # -> gates-have-teeth.sh "browser-sandbox-is-measured: a comment in the block is reworded"

  Scenario: the question the installer asks is the browser's own
    Given a throwaway with more than the browser has would answer for something else
    When it keeps a capability, runs as another user, or measures with another profile
    Then the gate fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the installer's throwaway keeps its capabilities"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the installer's throwaway is another user"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the installer measures with another profile"

  Scenario: no AppArmor line is written by hand
    Given the installer measures which line a host needs
    When compose.yaml writes apparmor=unconfined, or loses the line
    Then the gate fails, because that is a wider door on the host that does not need it, or no sandbox on the host that does
    # -> gates-have-teeth.sh "containers-carry-the-baseline: apparmor=unconfined is written out"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the browser has no apparmor line"

  Scenario: what runs holds the profile the file names
    Given an override can turn the filter off and agree with itself
    When status reads a running browser with no profile
    Then it is a FAIL line
    # -> gates-have-teeth.sh "status-reads-what-runs: a browser with its filter off passes"
