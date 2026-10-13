# @claude 2026-10-13, written from what the README promises an operator ("It verifies
# itself and tells you what it found"; "A green install with an open plane is the
# outcome worth designing against"), and not from the code that was changed. Two
# things went wrong on one box while it was upgraded in place to v1.1.32, and both
# are about the report being wrong about a box that was fine or, worse, fine about
# a box that was not. @measured: on a Debian 13 box (Docker 26.1.5, Compose 2.26.1),
# `set -o pipefail; docker compose logs tokenfuse-gateway 2>&1 | grep -qF 'client
# auth: ON (3 key(s))'` five times returned 0 255 255 0 255, and without -q 0 five
# times; and a re-run with GATEWAY_BIND only in .env printed `FAIL gateway answers
# on 127.0.0.1:4100` while `curl http://192.168.1.10:4100/healthz` answered 200.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the install reports the box as it is

  An operator runs install.sh, reads its verification, and decides from it whether
  the box is fit to point agents at. A healthy box has to be reported healthy, and a
  refused condition has to be reported refused, however two processes on the box
  happen to be scheduled. On a re-run the report has to look at the bind the box has,
  which is the one in its .env, and not the one the run was started with.

  Scenario: a healthy gateway is reported healthy, however long its log is
    Given a gateway whose log holds the line a check looks for, followed by thousands of other lines
    When the check reads that log and its reader leaves at the first match, as grep -q does
    Then the check says ok, and not FAIL because the command that printed the log was still writing
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: check_log() counts a producer's broken pipe again"

  Scenario: a log that holds a line the install must refuse is never reported as fine
    Given an identity map in which a client key has no binding, and the gateway's log says so
    When the check that every key is bound reads that log and its reader leaves at the first match
    Then the check says FAIL, and not ok because a closed pipe turned its answer around
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: check() counts a producer's broken pipe again"

  Scenario: a service that is up but silent is still a failure
    Given a service that is running and whose log holds nothing of what a check expects
    When the check looks for that line
    Then it says FAIL, and no change to how a closed pipe is counted makes it say ok
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: check() reports ok on anything"
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: check_log() reports ok on anything"

  Scenario: a group of checks is not skipped because a list of services was read too early
    Given a console that is running, listed among many services
    When the installer asks whether the console is there
    Then the answer is yes and the console's checks run, so the run cannot end "every check passed" with them left out
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: compose_has pipes the list into grep again"
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: a service test goes back to the pipe"

  Scenario: a check added later cannot bring the race back unnoticed
    Given a check that reads a log or the list of services through a pipe
    When one is added with no case in the gate, an existing one is renamed, or the helpers are moved out of the part the gate runs
    Then the gate fails and says what it could not judge
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: a log check is added with no case"
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: a log check is renamed"
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: the check helpers have no markers to lift them by"
    # -> gates-have-teeth.sh "checks-survive-a-closed-pipe: compose_has has no markers to lift it by"

  Scenario: a re-run on a box whose bind is only in .env probes that bind
    Given a box installed with GATEWAY_BIND=192.168.1.10 in its .env, and a re-run with nothing in the environment
    When the installer checks that the gateway answers
    Then it probes 192.168.1.10 and not 127.0.0.1, so a healthy box is not reported failed
    # -> gates-have-teeth.sh "bind-is-honoured: the probe is not recomputed after .env is first read"
    # -> gates-have-teeth.sh "bind-is-honoured: the probe is not recomputed after .env is read again"
    # -> gates-have-teeth.sh "bind-is-honoured: the probe is never worked out before .env is read"
    # -> gates-have-teeth.sh "bind-is-honoured: the probe function keeps the first bind it saw"

  Scenario: the address to probe is worked out in one place
    Given 0.0.0.0 means every address, loopback included, and an IPv6 bind needs brackets in a URL
    When a second copy of that mapping appears, the function maps every bind to loopback, or it cannot be found
    Then the gate fails, because two copies are how one of them goes stale
    # -> gates-have-teeth.sh "bind-is-honoured: a second copy of the probe mapping appears"
    # -> gates-have-teeth.sh "bind-is-honoured: the probe function maps every bind to loopback"
    # -> gates-have-teeth.sh "bind-is-honoured: the probe function is renamed away"
    # -> gates-have-teeth.sh "bind-is-honoured: the probe function has no markers to lift it by"

  Scenario: the delegation plane's origin follows the bind of the box as well
    Given the same box, and a re-run that is the first to enable delegation
    When the installer writes the origin the gateway checks a hand-off proof against
    Then that origin names 192.168.1.10, the address the gateway is published on
    # -> gates-have-teeth.sh "delegation-key-reused-on-rerun: the delegation origin is minted from a stale probe"
