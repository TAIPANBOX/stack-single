# @claude 2026-11-23: one service of thirty-one had a memory limit; a runaway
# plane could take the box's memory and the kernel would stop anything. Every
# service now carries a ceiling of its own. CLAUDE.md invariant 85. Scenarios are
# bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: every service carries a memory limit of its own

  A ceiling per container makes a runaway the one container stopped, instead of
  whatever the kernel picks on a box out of memory.

  Scenario: a service has no ceiling
    Given every service names its own memory limit beside its process limit
    When one loses it, or an anchor hands every service the same number
    Then the gate fails
    # -> gates-have-teeth.sh "mem-limit: a service loses its limit"
    # -> gates-have-teeth.sh "mem-limit: the anchor carries one limit for all"

  Scenario: a ceiling that is wrong in size
    Given a limit is a number of bytes compose resolves
    When it is a typo in kilobytes, or so large it limits nothing
    Then the gate fails
    # -> gates-have-teeth.sh "mem-limit: a typo leaves a limit in kilobytes"
    # -> gates-have-teeth.sh "mem-limit: a limit that limits nothing"

  Scenario: a heavy service is squeezed below its work
    Given the console runs a query engine over the whole trace and the policy archive
    When its limit falls below 1 GiB
    Then the gate fails, because its own work would be killed
    # -> gates-have-teeth.sh "mem-limit: the console is squeezed below its work"

  Scenario: nothing is left to judge
    Given the gate reads the resolved services
    When there are none
    Then the gate fails rather than reporting OK
    # -> gates-have-teeth.sh "mem-limit: the services are gone (measured nothing)"

  Scenario: more room is not a fault
    Given a ceiling may be raised for a box that needs it
    When one plane is given more
    Then the gate still passes
    # -> gates-have-teeth.sh "mem-limit: one plane is given more room (must pass)"
