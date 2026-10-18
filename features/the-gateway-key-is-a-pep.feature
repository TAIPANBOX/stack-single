# @decided 2026-10-18 (paraphrased): wardryx 2.0.0 refuses a viewer key on the two
# routes the gateway, the MCP broker and scopyx call on every governed request, so
# the policy-plane key those callers present is an enforcement point's role, pep. A
# box installed before that release keeps its viewer entry in .env, which a re-run
# leaves as is, so the re-run rewrites that one entry before the stack comes up.
# Each scenario is bound by name to a case in scripts/gates-have-teeth.sh, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the gateway's policy-plane key is a pep, on a new box and on a box re-run

  The gateway, the MCP broker and scopyx present one policy-plane key on every
  governed call, and with failmode closed a refused decision refuses the call. wardryx
  2.0.0 refuses a viewer on the decide and filter routes, so a viewer key left in .env
  turns every governed call into a refused one. The installer mints the key as pep for
  a new box, and a re-run rewrites the one viewer entry of an old .env, role only.

  Scenario: a new box mints the gateway's policy-plane key as a pep
    Given install.sh writes the .env of a new box
    When the gateway's entry is minted as viewer again
    Then wardryx-gateway-key-is-pep.sh fails, because the gateway's calls would be refused
    # -> gates-have-teeth.sh "wardryx-key-is-pep: a fresh .env mints the gateway's key as viewer again"

  Scenario: a re-run never calls the migration, so an old viewer entry is kept
    Given a .env minted before this release still gives the gateway a viewer entry
    When install.sh stops calling the migration on a re-run
    Then wardryx-gateway-key-is-pep.sh fails and names the missing call
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the re-run never calls the migration"

  Scenario: the migration runs after the stack has come up
    Given the new wardryx would refuse the old viewer key the moment it starts
    When the migration is moved after the first up in install.sh
    Then wardryx-gateway-key-is-pep.sh fails, because the stack would take traffic with the old key
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration is called after the stack comes up"

  Scenario: the migration does nothing at all
    Given a .env with a viewer entry for the gateway
    When the migration returns before it changes anything
    Then wardryx-gateway-key-is-pep.sh fails on the entry it should have rewritten
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration is switched off"

  Scenario: the migration rewrites a key that is not the gateway's
    Given an operator's own viewer key sits beside the gateway's in .env
    When the migration stops checking which key an entry belongs to
    Then wardryx-gateway-key-is-pep.sh fails, because another principal's role would change
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration rewrites a key that is not the gateway's"

  Scenario: the migration changes the gateway's secret
    Given the gateway's secret is what the gateway, the broker and scopyx present
    When the migration writes a different secret into the entry
    Then wardryx-gateway-key-is-pep.sh fails, because every caller would be refused
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration changes the gateway's secret"

  Scenario: the migration drops an agent list the operator wrote
    Given an operator limited the gateway's key to some agents
    When the migration rewrites the role and forgets the list
    Then wardryx-gateway-key-is-pep.sh fails, because the operator's limit would be widened
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration drops an agent list the operator wrote"

  Scenario: the gate measures nothing when the migration has no block
    Given the migration lives in a block the gate lifts out of install.sh
    When the block's begin marker is taken away
    Then wardryx-gateway-key-is-pep.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration block is not there"

  Scenario: a reworded note about the migration is not a fault
    Given the migration prints a note for the operator
    When the note is reworded and its meaning kept
    Then wardryx-gateway-key-is-pep.sh still passes
    # -> gates-have-teeth.sh "wardryx-key-is-pep: a reworded note is not a fault"
