# @claude 2026-11-25: keyryx 0.2.0 serves rotation and revocation only on its
# admin socket and announces each change on the bus; it refuses to start without
# a stream of its own and with any network admin key. CLAUDE.md invariant 86.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: Keyryx custody announces every key change on a stream of its own

  A person rotates or revokes a key with custody's own command line on the box,
  and the change is announced where the notifier reads it. No network key can
  do either.

  Scenario: custody has nowhere to announce
    Given custody is keyryx 0.2.0, which refuses to start without KEYRYX_EVENTS
    When its stream is unset, inside its data directory, or the witness's file
    Then the gate fails
    # -> gates-have-teeth.sh "keyryx-custody: custody loses its stream"
    # -> gates-have-teeth.sh "keyryx-custody: the stream moves inside KEYRYX_DATA"
    # -> gates-have-teeth.sh "keyryx-custody: custody writes the witness's file"

  Scenario: custody cannot write its own stream
    Given the bus directory is root's and custody writes only a file it owns
    When the bus is mounted read only, or the file is not made, or made for another uid
    Then the gate fails
    # -> gates-have-teeth.sh "keyryx-custody: custody mounts the bus read only"
    # -> gates-have-teeth.sh "keyryx-custody: init-volumes stops making the stream"
    # -> gates-have-teeth.sh "keyryx-custody: init-volumes gives the stream to the witness's uid"

  Scenario: a network admin key comes back
    Given rotation and revocation are served only on the admin socket
    When compose.yaml or install.sh hands custody KEYRYX_ADMIN_KEYS
    Then the gate fails
    # -> gates-have-teeth.sh "keyryx-custody: custody is handed a network admin key"
    # -> gates-have-teeth.sh "keyryx-custody: install.sh writes an admin key"

  Scenario: an older custody or an older reader
    Given keyryx 0.2.0 and heraldyx 0.10.0 are the first that write and read the stream
    When either pin goes back
    Then the gate fails, because the announcements would not be written or would be refused
    # -> gates-have-teeth.sh "keyryx-custody: keyryx is pinned back to v0.1.5"
    # -> gates-have-teeth.sh "keyryx-custody: heraldyx is pinned below 0.10.0"
    # -> gates-have-teeth.sh "bus-names: the heraldyx pin goes back before custody's stream"

  Scenario: the operator is not told how to rotate
    Given the README is where an operator learns the admin commands
    When it stops naming them
    Then the gate fails
    # -> gates-have-teeth.sh "keyryx-custody: the README loses the admin commands"

  Scenario: there is nothing to judge, or nothing wrong
    Given the gate reads custody's own service
    When no service runs custody, it says it measured nothing; when only a comment changes, it passes
    Then neither verdict is given on nothing
    # -> gates-have-teeth.sh "keyryx-custody: no custody service (measured nothing)"
    # -> gates-have-teeth.sh "keyryx-custody: the comment on custody's stream is reworded (must pass)"
