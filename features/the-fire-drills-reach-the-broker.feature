# @decided 2026-11-08, paraphrased: the fire drills get a key of their own for the MCP broker in both stacks, and the
# broker drills run against the stack's own broker. @claude 2026-11-08: the shape on this box (a service a person runs,
# the key id drills-broker, the key on the broker's static list, the image checked at install) is my reading of what
# that takes here. Each scenario is bound by name to a case in scripts/gates-have-teeth.sh, and
# scripts/features-are-bound.sh holds the binding both ways. The drills passing against a running broker is CI's
# typed-risk install leg (.github/workflows/install.yml).
Feature: the fire drills reach this box's MCP broker with a key of its own

  mockryx's broker drills rehearse three guardrails of the MCP broker: a raw secret in tool arguments, personal data
  in tool arguments, and the hold on a tool call nothing grants. A broker that requires a key refused every one of
  them, because mockryx sent the broker no key. mockryx 0.5.0 sends a key of the broker's own, never the gateway's,
  and this box mints that key, lists it, and gives a person one command that runs the drills.

  Scenario: an install starts the drills
    Given the drills are run by a person, with docker compose run --rm mockryx-drill
    When the drill service leaves the manual profile, so an ordinary up starts it
    Then drills-reach-the-broker.sh fails, because an install would start a drill nobody asked for
    # -> gates-have-teeth.sh "drills-broker: the drill leaves the manual profile"

  Scenario: the drill is given the gateway's key
    Given the drills' key at the broker is not the gateway's client key, and mockryx refuses to send that one to the broker
    When the drill service is handed the gateway's client key
    Then drills-reach-the-broker.sh fails and says it takes the broker's key from its file alone
    # -> gates-have-teeth.sh "drills-broker: the drill is handed the gateway's client key"

  Scenario: the drill runs the gateway drills too
    Given the gateway admits the drills' gateway key only through a token, which mockryx cannot sign
    When the drill service is pointed at the gateway drills
    Then drills-reach-the-broker.sh fails, because every one of those drills would be refused at the gateway's door
    # -> gates-have-teeth.sh "drills-broker: the drill runs the gateway drills too"

  Scenario: the drill pins a mockryx that sends the broker no key
    Given mockryx sends the broker a key of its own from v0.5.0
    When the drill service pins v0.4.0
    Then drills-reach-the-broker.sh fails and names v0.5.0
    # -> gates-have-teeth.sh "drills-broker: the drill pins a mockryx that sends the broker no key"

  Scenario: a newer mockryx is not refused
    Given the floor is v0.5.0
    When the drill service pins v0.6.0
    Then drills-reach-the-broker.sh passes
    # -> gates-have-teeth.sh "drills-broker: a newer mockryx pin still passes"

  Scenario: the drill's image is pulled unchecked
    Given every image of ours is checked before it is pulled
    When install.sh resolves the drill's image and pulls it without checking its signature
    Then drills-reach-the-broker.sh fails
    # -> gates-have-teeth.sh "drills-broker: the drill's image is pulled unchecked"

  Scenario: the broker refuses the drills' key
    Given under require the broker admits a static key only when its static list names it
    When install.sh leaves drills-broker off the broker's list
    Then drills-reach-the-broker.sh fails, because every drill would be refused 401
    # -> gates-have-teeth.sh "drills-broker: the key is not on the broker's list"

  Scenario: a re-run mints the key again
    Given a box already holds the drills' key at the broker
    When install.sh runs again
    Then the key, the broker's list and the file stay as they were
    # -> gates-have-teeth.sh "drills-broker: a re-run mints the key again"

  Scenario: another user can read the key
    Given the key file is the drill's alone
    When install.sh leaves it readable by others
    Then drills-reach-the-broker.sh fails
    # -> gates-have-teeth.sh "drills-broker: the key file is left readable"

  Scenario: the installer prints the key
    Given no secret is printed
    When install.sh prints the drills' key
    Then drills-reach-the-broker.sh fails
    # -> gates-have-teeth.sh "drills-broker: the secret is printed"

  Scenario: the drills' key is a key the gateway holds
    Given mockryx refuses to send the gateway's client key to the broker
    When the drills' key at the broker is also a gateway client key
    Then install.sh refuses before anything starts, and the gate fails when it does not
    # -> gates-have-teeth.sh "drills-broker: a secret the gateway holds is accepted"

  Scenario: there is nothing to measure
    Given the gate reads the drill service and the installer's key block
    When either is gone
    Then drills-reach-the-broker.sh says it measured nothing, rather than OK
    # -> gates-have-teeth.sh "drills-broker: the drill service is gone"
    # -> gates-have-teeth.sh "drills-broker: the key block is gone"
