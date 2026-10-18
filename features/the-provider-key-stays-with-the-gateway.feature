# @decided 2026-10-18 (paraphrased): the gateway holds the provider key, so an agent
# never does. Each door reads its provider key from a file the installer writes, mounted
# read only into that door alone, and no service in the stack carries a provider key as
# an environment value. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh, and scripts/features-are-bound.sh holds the binding both ways.
Feature: the provider key stays with the gateway, and no agent holds it

  An agent that holds the provider key can call the model with no gateway in the way, and
  the gateway used to forward whatever key a caller sent. So the key is held by the
  gateway: it is read from a file the installer wrote, mounted read only into the door
  that uses it, and no other service in the stack is given it as a value.

  Scenario: the gateway holds its provider key from a file
    Given the gateway reads the provider key from TOKENFUSE_UPSTREAM_KEY_FILE
    When the gateway's key file is taken out of its configuration
    Then no-provider-key-outside-the-gateway.sh fails, because the gateway would forward the caller's key
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: the gateway loses its key file"

  Scenario: the OpenAI door holds its own key, not the Anthropic one
    Given the OpenAI door reads its key file from its own directory
    When the door is pointed at the gateway's key file
    Then no-provider-key-outside-the-gateway.sh fails, because one door would spend the other's key
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: the OpenAI door reads the Anthropic key file"

  Scenario: no agent-facing service is given the provider key as a value
    Given the console is Felyx's home and an agent-facing service
    When the console is given the provider key as an environment value
    Then no-provider-key-outside-the-gateway.sh fails, naming the console
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: the console gets the provider key back"

  Scenario: no agent-facing service takes its key from the provider key by reference
    Given Felyx authenticates with its own gateway client key
    When Felyx is pointed at the provider key through a reference
    Then no-provider-key-outside-the-gateway.sh fails, naming the reference
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: Felyx reads the provider key by reference"

  Scenario: the key directory is mounted read only
    Given the gateway mounts its key directory
    When the mount becomes writable
    Then no-provider-key-outside-the-gateway.sh fails, because the gateway could rewrite its own key
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: the gateway mounts its key directory read-write"

  Scenario: no other service mounts a provider key directory
    Given only the two doors mount the provider key directories
    When the console also mounts the Anthropic key directory
    Then no-provider-key-outside-the-gateway.sh fails, naming the console
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: the console mounts the Anthropic key directory"

  Scenario: the installer writes the key file for the gateway's own uid, readable by it alone
    Given install.sh writes the provider key into the key directory
    When the installer stops writing it
    Then no-provider-key-outside-the-gateway.sh fails, because no file would hold the key
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: the installer stops writing the key file"

  Scenario: a harmless variable is not a fault
    Given a service carries an ordinary environment value
    When that value is added to the console
    Then no-provider-key-outside-the-gateway.sh still passes
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: a harmless variable is not a fault"

  Scenario: a stack with no gateway is measured as nothing, not as safe
    Given the gateway is recognised by its image and its bare command
    When the command no longer names the gateway binary
    Then no-provider-key-outside-the-gateway.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "no-provider-key-outside-the-gateway: no gateway left to judge"
