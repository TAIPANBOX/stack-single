# Written from the owner's decision of 2026-11-12, paraphrased: containers of another project on
# this box (a lab's gateway, an IdP bridge) stop sitting on the stack's core network beside the
# planes, reach only the services they need, and stop showing as failures in status for good.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways. CLAUDE.md invariant 77.
Feature: a guest of another project reaches the doors and nothing else

  The guests network holds vouchryx, the gateway and the MCP broker, and no plane, no
  database and no key. A container of another project joins it by name, and the operator
  names it in guests.txt beside compose.yaml. status calls a named guest on that network a
  note, and calls anything else on the stack's networks an unknown container.

  Scenario: the guests network holds the doors and no plane
    Given the stack's compose file
    When the networks are read
    Then the guests network holds exactly vouchryx, the gateway and the MCP broker, and has no route out
    # -> gates-have-teeth.sh "network-membership: wardryx joins the guests network"
    # -> gates-have-teeth.sh "network-membership: vouchryx leaves the guests network"
    # -> gates-have-teeth.sh "network-membership: guests is not internal"

  Scenario: a fresh box shows the guests network reaching the doors and nothing else
    Given a box the installer has just installed
    When a container on the guests network calls the stack by name
    Then the gateway and vouchryx answer, and no plane, no database and no address outside answers
    # -> gates-have-teeth.sh "network-membership: install.yml loses the guests probe"

  Scenario: a guest named in guests.txt is a note on the guests network
    Given a container of another project on the guests network, named in guests.txt
    When the operator runs status
    Then its line is a note that names it a guest, and the run does not fail for it
    And a name in guests.txt with no container is shown, and does not fail
    # -> gates-have-teeth.sh "status-reads-what-runs: a name in guests.txt with no container is not shown"
    # -> gates-have-teeth.sh "status-reads-what-runs: the comment above the guest list is reworded (must pass)"

  Scenario: a container on the guests network that nobody named fails status
    Given a container of another project on the guests network, and guests.txt does not name it
    When the operator runs status
    Then its line says unknown container, and the run ends 1
    # -> gates-have-teeth.sh "status-reads-what-runs: any container on the guests network reads as a guest"

  Scenario: a named guest on core fails status
    Given a container guests.txt names, attached to the stack's core network
    When the operator runs status
    Then its line says unknown container on core and that guests.txt lets it onto the guests network only
    # -> gates-have-teeth.sh "status-reads-what-runs: a named guest on core reads as a guest"

  Scenario: a named guest that answers to a name of the stack's own fails status
    Given a container guests.txt names, on the guests network, that answers there to the name wardryx, to a provider's host the stack calls, or by its container name to a stack name
    When the operator runs status
    Then its line says it answers to a name of the stack's own, and the run ends 1
    And the name is compared as DNS compares it, without case and without a final dot, and a name that is no DNS name fails
    And a name it has only on another network is not held against it
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's names are compared with their case"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's name with a final dot passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's name with a space is read as words"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's container name is not held to the stack's"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest that answers to a name of the stack's own passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's names on every network are held to the stack's"

  Scenario: a guests.txt that cannot be read lets nobody in
    Given a guests.txt that cannot be read, or a line in it that is not one container name
    When the operator runs status
    Then status says it could not measure, and every container of another project is an unknown container
    # -> gates-have-teeth.sh "status-reads-what-runs: a guests.txt line of two names is skipped"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guests.txt that cannot be read is no file"
