# Written from what an operator of a box wants to know about each container: that it cannot
# write to its image, holds no capability it does not need, cannot gain one, cannot fork the
# box to death and leaves no core dump with a key in it; and, where one of those does not
# hold, which line says so and why. Measured in a compose project of its own on Compose
# 2.26.1, with the live stack untouched.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: every container carries the baseline, or names why not

  compose.yaml gives every service the same baseline through one anchor, and a process
  limit of its own. What a service does not take is a named line in
  hardening-exceptions.json, with a reason, and until when.

  Scenario: every service runs with a read-only root, no capabilities and no new privileges, or names why not
    Given the resolved configuration of compose.yaml, every profile on
    When the gate reads each service
    Then each has read_only, cap_drop ALL and no-new-privileges, or an exception that says why
    # -> gates-have-teeth.sh "containers-carry-the-baseline: wardryx turns read_only off"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the anchor loses cap_drop"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: no-new-privileges is written false"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a service is privileged"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a service joins the host's namespace"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a service runs as root"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a tmpfs has no size"

  Scenario: a new service with no baseline fails the gate
    Given a service added with none of the lines
    When the gate reads it
    Then it fails naming that service, because nobody had to list it
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a new service has no baseline"

  Scenario: an exception with no reason fails the gate
    Given an exception with a field missing, a reason that says nothing, a key outside the list or a service that is not there
    When the gate reads it
    Then it fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: an exception has no reason"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a reason says nothing"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: an exception names a key outside the list"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: an exception names no such service"

  Scenario: an exception that excuses nothing fails the gate
    Given a service that took the baseline and kept its exception
    When the gate reads it
    Then it fails, so whoever fixes a service takes its line out
    # -> gates-have-teeth.sh "containers-carry-the-baseline: an exception excuses nothing"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: vouchryx takes the anchor and keeps its exception"

  Scenario: a capability added back is named and limited to its service
    Given a cap_add in compose.yaml
    When it is wider or narrower than its exception, or has none, or is ALL
    Then the gate fails, and the installer's own override may not take the baseline back either
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a capability has no exception"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a capability is wider than its exception"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: an exception is wider than its capability"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the installer's override takes the baseline back"

  Scenario: a process limit is set and is not unlimited
    Given a pids_limit
    When it is missing, zero, negative or above the ceiling
    Then the gate fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a service has no process limit"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a process limit is minus one"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a process limit is above the ceiling"

  Scenario: core dumps are off for every service
    Given the anchor
    When core is anything but 0
    Then the gate fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: core dumps are on"

  Scenario: the browser keeps Chrome's sandbox and reaps its children
    Given scopyx-browser, where a zombie counts against the process limit
    When the gate reads it
    Then it has init, its shared memory and its memory limit beside pids_limit, and it alone may be seccomp:unconfined
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the browser loses init"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a second service is seccomp:unconfined"

  Scenario: the three services a certified key hangs on stay as they were, by name
    Given init-volumes, keyryx and vouchryx
    When the gate reads the exceptions
    Then each is excused until G3.11, and an exception pointing elsewhere fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: keyryx's exception points nowhere"

  Scenario: the running containers match the file, not only the file
    Given a running container without what compose.yaml gives it, even with an override that agrees
    When the operator runs status
    Then its line says what it lacks, and the run ends 1
    # -> gates-have-teeth.sh "status-reads-what-runs: a container that lost its baseline passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: the override is read as the file"

  Scenario: rewording around the baseline changes no verdict
    Given a comment with the word privileged in it, or a reason reworded
    When the gate runs
    Then it still passes
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a comment says privileged"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: a reason is reworded"

  Scenario: the gate does not report OK on nothing
    Given no compose.yaml, an empty one, one with no services, or no exceptions file
    When the gate runs
    Then it says it measured nothing and fails
    # -> gates-have-teeth.sh "containers-carry-the-baseline: compose.yaml is empty"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: compose.yaml has no services"
    # -> gates-have-teeth.sh "containers-carry-the-baseline: the exceptions file is gone"
