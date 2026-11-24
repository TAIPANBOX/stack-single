# @claude 2026-11-23: the bus layout of invariant 41 is held in compose.yaml by a
# gate; this asks the running box the same question at every install, producer by
# producer, as stack-k8s's security tests ask its cluster. CLAUDE.md invariant 83.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: every producer is asked on the box who can write what on the bus

  Each plane writes one stream of its own and no other. A file that says so is not
  a box that does, so every install runs a throwaway container as each producer and
  asks.

  Scenario: a producer is never asked
    Given the probe works from a table of producers, their uids and groups
    When a stream drops out of the table, or the table names the wrong uid or loses a group
    Then the gate fails, because that producer's reach is never measured
    # -> gates-have-teeth.sh "bus-writers: a stream drops out of the table"
    # -> gates-have-teeth.sh "bus-writers: the table names the wrong uid"
    # -> gates-have-teeth.sh "bus-writers: the probe drops a writer's extra group"

  Scenario: the probe stops asking the question
    Given the probe must try another producer's stream and be refused
    When it stops trying, or runs with a network it does not need
    Then the gate fails
    # -> gates-have-teeth.sh "bus-writers: the probe stops trying another stream"
    # -> gates-have-teeth.sh "bus-writers: the probe gets a network"
    # -> gates-have-teeth.sh "bus-writers: the probe lists the directory instead of naming the streams"
    # -> gates-have-teeth.sh "bus-writers: a producer's missing stream passes"
    # -> gates-have-teeth.sh "bus-writers: an attempt runs outside a subshell"

  Scenario: the probe damages the box it measures
    Given a rename that went through on a broken box must be undone at once
    When it is not put back
    Then the gate fails
    # -> gates-have-teeth.sh "bus-writers: a rename that went through is not put back"

  Scenario: the install stops asking, or the README says the bus is open
    Given the install runs the probe and the README says what it holds
    When the install check is gone, or the README says any writer can append anywhere
    Then the gate fails
    # -> gates-have-teeth.sh "bus-writers: install.sh stops running the probe"
    # -> gates-have-teeth.sh "bus-writers: the README says the bus is open again"

  Scenario: nothing is left to judge
    Given the gate reads the probe's block
    When the block is gone
    Then the gate says it measured nothing
    # -> gates-have-teeth.sh "bus-writers: the block is gone (measured nothing)"

  Scenario: a harmless change is not a fault
    Given comments are prose
    When one is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "bus-writers: a comment is reworded (must pass)"
