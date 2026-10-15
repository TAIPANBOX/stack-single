# Written from what an operator needs after the install: to check the same things
# again, later, on the box that is running, without installing, changing or restarting
# anything. The verification list is the one section 8 of install.sh runs; status runs
# that list too, and this file says what it may and may not do.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: status checks an installed stack and changes nothing

  An operator who has installed the stack runs `./install.sh status` to see whether
  it still holds together. The checks are the install's own, one line each, and the
  run ends 0 when they all pass and 1 when one does not.

  Scenario: status runs the checks the install runs, one line each, and says how it ended
    Given an installed stack in its directory
    When the operator runs status
    Then each check the install runs is printed on its own line, and the run ends with a verdict line
    # -> gates-have-teeth.sh "status-is-read-only: the status entry point is gone"
    # -> gates-have-teeth.sh "status-is-read-only: the verdict line is reworded"

  Scenario: status changes nothing on the box
    Given an installed stack that is running
    When the operator runs status
    Then no service is started, stopped, restarted or removed, no image is pulled, no package is installed, and no first device is issued
    # -> gates-have-teeth.sh "status-is-read-only: status brings the stack up first"
    # -> gates-have-teeth.sh "status-is-read-only: status runs the package step"
    # -> gates-have-teeth.sh "status-is-read-only: status issues the first device"

  Scenario: status never writes into the event bus or sends a request the stack records
    Given an installed stack with client keys and an identity map
    When the operator runs status
    Then the checks that would write to the bus, or send a call the gateway records, are printed as skipped and not run
    # -> gates-have-teeth.sh "status-is-read-only: a write probe runs in status"
    # -> gates-have-teeth.sh "status-is-read-only: a refused metered call is sent by status"

  Scenario: status on a box with nothing installed refuses and says so
    Given a directory with no .env in it
    When the operator runs status there
    Then status ends 1, says that nothing is installed, and calls no tool at all
    # -> gates-have-teeth.sh "status-is-read-only: status runs on a directory with no .env"

  Scenario: rewording a comment does not change what status is allowed to do
    Given the status code with a comment reworded
    When the read-only gate runs
    Then it still passes
    # -> gates-have-teeth.sh "status-is-read-only: a comment in the status block is reworded"
    # -> gates-have-teeth.sh "status-is-read-only: a comment in the shared check list is reworded"
