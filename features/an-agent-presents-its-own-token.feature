# @decided 2026-10-18 (paraphrased, wave 1 of the 2026-10-17 agent-security review): an
# agent presents a short-lived token of its own, not a shared static key, when the operator
# asks for it; the doors that accept that token verify it against vouchryx for their own
# audience, against a revocation list that fails closed. Required by default since
# 2026-10-19 (CLAUDE.md invariant 47); off only when WITH_AGENT_TOKENS=0. Each scenario is
# bound by name to a case in scripts/gates-have-teeth.sh, and scripts/features-are-bound.sh
# holds the binding both ways.
Feature: an agent presents its own token, and the doors check it where it is judged

  A static client key is one secret per namespace. It cannot be stopped for one agent at
  runtime, and nothing outside the gateway can check it. So an agent gets its own credential,
  exchanged for a token that every door verifies offline, and a stop is one revocation that
  every door polls. A box that did not ask for any of this runs what it ran before.

  Scenario: agent tokens are required by default, and off only when the operator asks
    Given a box installed with no WITH_AGENT_TOKENS
    When the gateway's switch is read as the default
    Then agent-tokens-are-wired.sh fails, because a default box would admit a static key without a token
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the switch is off by default"

  Scenario: a static key is admitted only when its key id is named
    Given the gateway runs require with an allow-list of key ids
    When the allow-list is not written to the gateway
    Then agent-tokens-are-wired.sh fails, because require would admit no static key by name
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the gateway names no static-key list"

  Scenario: the broker's static-key list is written as well
    Given the MCP broker runs require with its own allow-list
    When the broker's allow-list is not written to it
    Then agent-tokens-are-wired.sh fails, because the broker would admit no static key by name
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the broker names no static-key list"

  Scenario: wardryx verifies the token itself, for the doors' audience
    Given wardryx decides a call that carries an agent token
    When the audience it verifies for is not the doors' audience
    Then agent-tokens-are-wired.sh fails, because the decision would verify a token for another resource
    # -> gates-have-teeth.sh "agent-tokens-are-wired: wardryx names another audience"

  Scenario: a stopped agent is refused at the decision too
    Given wardryx polls the revocation list at vouchryx
    When that list is removed from what the installer writes
    Then agent-tokens-are-wired.sh fails, because a revoked token would still pass the decision
    # -> gates-have-teeth.sh "agent-tokens-are-wired: wardryx polls no revocation list"

  Scenario: a proof addressed to a door is checked against that door's origin
    Given the agent sends its proof to the gateway or the broker by its address
    When wardryx's door origins leave the broker out
    Then agent-tokens-are-wired.sh fails, because a proof sent to the broker would be refused
    # -> gates-have-teeth.sh "agent-tokens-are-wired: wardryx does not name the broker's door"

  Scenario: the off path clears the static-key lists
    Given tokenfuse 1.19.0 refuses a static-key list under any mode but require
    When WITH_AGENT_TOKENS=0 leaves a list behind in .env
    Then agent-tokens-are-wired.sh fails, because the gateway would refuse to start
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the off path keeps its static-key list"

  Scenario: the allow-list holds felyx, which cannot sign a proof
    Given the console's copilot presents its own static key
    When the installer's allow-list leaves felyx out
    Then the installer's check fails, because the console would be refused 401 on a fresh box
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the allow-list drops felyx"

  Scenario: a re-run keeps every key id it already had on the allow-list
    Given a box that already had a static key before this run
    When a re-run builds the allow-list without that key id
    Then the installer's check fails, because a key that worked yesterday would stop working
    # -> gates-have-teeth.sh "agent-tokens-are-wired: a re-run drops an existing key id"

  Scenario: the allow-list names only keys the box holds
    Given a key id a box does not hold
    When the installer builds the allow-list
    Then the installer's check fails, because tokenfuse refuses to start on a listed id it does not hold
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the allow-list lists a key the box does not hold"

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
