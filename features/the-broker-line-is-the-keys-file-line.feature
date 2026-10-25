# @decided 2026-10-19 (paraphrased, the 1.4.0 wave on the forge upgrade): a box given its own client keys
# file must carry the MCP broker's key in that file, in the one format the installer reads. Each scenario
# is bound by name to a case in scripts/gates-have-teeth.sh; scripts/features-are-bound.sh holds the binding.
Feature: a box with its own keys file takes the broker's line, or adds it on request

  The README used to ask for `broker:<secret>`, while the installer reads `<secret>:broker`, so an
  operator who followed the README was refused again. The keys file is the operator's, so the installer
  adds a line to it only when asked to.

  Scenario: a keys file that holds its broker line is accepted
    Given a box given its own keys file with a `<secret>:broker` line and agent tokens on
    When the installer resolves its keys
    Then broker-key-is-the-keys-file-line.sh fails if the box is refused for want of that line
    # -> gates-have-teeth.sh "broker-key: the installer refuses a keys file that holds its broker line"

  Scenario: the README names the form the installer reads
    Given the operator reads the README on how to add the broker's line
    When the README gives the form of the line
    Then broker-key-is-the-keys-file-line.sh fails if the README says broker:<secret>
    # -> gates-have-teeth.sh "broker-key: the README asks for broker:<secret> again"

  Scenario: ADD_BROKER_KEY=1 appends the line only after the identity map binds broker
    Given a keys file with no broker line and an identity map that does not bind broker
    When the operator asks for ADD_BROKER_KEY=1
    Then the installer refuses before it writes the keys file
    # -> gates-have-teeth.sh "broker-key: ADD_BROKER_KEY=1 appends without checking the identity map"

  Scenario: a re-run whose keys are kept in .env is refused by name, not by a shell error
    Given a box whose keys an earlier run took from its keys file and keeps in .env
    When it re-runs with agent tokens on and no keys file named
    Then the installer refuses before it writes anything, saying the keys are kept in .env and naming the keys file and WITH_AGENT_TOKENS=0 as the ways out
    # -> gates-have-teeth.sh "broker-key: a re-run whose keys are kept in .env reads an unset CLIENT_KEYS_FILE"
