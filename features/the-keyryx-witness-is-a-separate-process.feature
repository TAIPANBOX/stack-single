# @decided 2026-10-18 (paraphrased, wave 2, design section 3.4): the Keyryx witness is a
# process apart from custody. It runs under its own uid, with its own data volume and its
# own root key, and with no network. Custody that signs and the witness that notices a
# rewrite must not be the same thing. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh.
Feature: the Keyryx witness is a separate process from custody

  If one compromised process could both sign and witness, the witness would prove
  nothing. So the two are two services, and nothing one holds, the other can reach.

  Scenario: the witness runs under custody's uid
    Given custody runs under uid 20101 and the witness under uid 20100
    When the witness is given custody's uid
    Then the gate fails, because the two would share every file custody can read
    # -> gates-have-teeth.sh "witness-is-separate: the witness runs under custody's uid"

  Scenario: the witness mounts custody's state
    Given custody and the witness each have their own state volume
    When the witness also mounts custody's state volume
    Then the gate fails and names the shared state
    # -> gates-have-teeth.sh "witness-is-separate: the witness mounts custody's state"

  Scenario: the witness has a network
    Given the witness has no network, so it has nothing to call and nothing to serve
    When the witness is put on the core network
    Then the gate fails, because a witness with a route can be reached or can reach out
    # -> gates-have-teeth.sh "witness-is-separate: the witness has a network"

  Scenario: a reworded comment in the witness block is not a fault
    Given the gate judges the resolved configuration
    When a comment in the witness block is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "witness-is-separate: a reworded comment in the witness block is not a fault"

  Scenario: the witness service is gone
    Given the gate judges the two services by their names
    When the witness service is renamed away
    Then the gate reports that it measured nothing, and does not pass
    # -> gates-have-teeth.sh "witness-is-separate: no keyryx service left to judge"
