# @decided 2026-10-18 (paraphrased, wave 1 of the 2026-10-17 agent-security review): an
# agent presents a short-lived token of its own, not a shared static key, when the operator
# asks for it; the doors that accept that token verify it against vouchryx for their own
# audience, against a revocation list that fails closed. Off by default. Each scenario is
# bound by name to a case in scripts/gates-have-teeth.sh, and scripts/features-are-bound.sh
# holds the binding both ways.
Feature: an agent presents its own token, and the doors check it where it is judged

  A static client key is one secret per namespace. It cannot be stopped for one agent at
  runtime, and nothing outside the gateway can check it. So an agent gets its own credential,
  exchanged for a token that every door verifies offline, and a stop is one revocation that
  every door polls. A box that did not ask for any of this runs what it ran before.

  Scenario: agent tokens are off until the operator asks for them
    Given a box installed with no WITH_AGENT_TOKENS
    When the gateway's switch is read as the default
    Then agent-tokens-are-wired.sh fails, because a default box would start accepting tokens
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the switch is accept by default"

  Scenario: the gateway checks a token only for its own audience
    Given the gateway verifies a token against vouchryx's key set
    When its audience is written empty
    Then agent-tokens-are-wired.sh fails, because an empty audience accepts a token minted for any resource
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the gateway's audience is empty"

  Scenario: a revocation list that cannot be read refuses, it does not honour
    Given a stopped agent's token must be refused while the list cannot be read
    When the list is set to fail open at the gateway or the broker
    Then agent-tokens-are-wired.sh fails, because a stopped agent would keep working during an outage
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the revocation list fails open"

  Scenario: the gateway asks vouchryx for the revocation list
    Given a stop is one revocation at vouchryx
    When the gateway is no longer told where that list is
    Then agent-tokens-are-wired.sh fails, because a stop would reach no door
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the gateway polls no revocation list"

  Scenario: the broker's relayed check has the broker's own key
    Given the broker relays a tool-call check to the gateway with its own key
    When the key file is taken out of its configuration
    Then agent-tokens-are-wired.sh fails, because the relayed check would be refused or sent without a credential
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the broker's taint-gateway key file is gone"

  Scenario: the broker can read its key file
    Given the broker reads its key from a directory mounted read only
    When that mount is taken out
    Then agent-tokens-are-wired.sh fails, because the key file cannot be read
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the broker does not mount its key directory"

  Scenario: vouchryx is never published to the host
    Given vouchryx signs tokens and answers revocations on the compose network only
    When a host port is published for it
    Then agent-tokens-are-wired.sh fails, because a signing service on the host is a second door to a stop
    # -> gates-have-teeth.sh "agent-tokens-are-wired: vouchryx publishes a port"

  Scenario: the enrolment secret never reaches .env
    Given the installer keeps the enrolment secret in a 0600 file and writes only its digest
    When the installer writes the secret into .env
    Then agent-tokens-are-wired.sh fails, because .env is read by every service on the box
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the installer writes the enrolment secret to .env"

  Scenario: a reworded comment is not a fault
    Given the agent-tokens block explains what it does not do
    When a comment is reworded and nothing else changes
    Then agent-tokens-are-wired.sh still passes
    # -> gates-have-teeth.sh "agent-tokens-are-wired: a reworded comment is not a fault"

  Scenario: a stack with no vouchryx is measured as nothing, not as safe
    Given vouchryx is named by its compose service
    When the service is renamed away
    Then agent-tokens-are-wired.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "agent-tokens-are-wired: no vouchryx service left to judge"
