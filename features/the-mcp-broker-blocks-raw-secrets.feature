# @decided 2026-10-17 (paraphrased): close the agent-security findings of the
# 2026-10-17 review, starting with the defaults; here, tokenfuse's MCP broker refuses
# a raw secret in tool arguments, refuses a tool listing its scanner flags, and asks
# the policy plane about every tool call, failing closed. Each scenario is bound by
# name to a case in scripts/gates-have-teeth.sh, and scripts/features-are-bound.sh
# holds the binding both ways.
Feature: the MCP broker blocks raw secrets and asks the policy plane about every tool call

  The broker fronts the typed plane on port 4200. Left to tokenfuse's own defaults it
  forwards a raw secret it finds in tool arguments, passes a tool listing its scanner
  flags with a log line, and never asks wardryx about a tool call, so a tool the
  policy denies is called anyway. On this box it blocks the first two and judges every
  call, and an unreachable policy plane refuses the call. Pinning tool definitions
  needs a lock file somebody approved, and it stays off.

  Scenario: a raw secret in tool arguments is forwarded again
    Given the broker sets TOKENFUSE_MCP_DLP to block
    When compose.yaml sets it to shadow
    Then broker-blocks-raw-secrets.sh fails, because the upstream would receive the secret
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: secrets in tool arguments go back to shadow"

  Scenario: the broker loses its secret scanner setting
    Given the broker sets TOKENFUSE_MCP_DLP
    When compose.yaml stops setting it
    Then broker-blocks-raw-secrets.sh fails, because tokenfuse's own default forwards the secret
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: TOKENFUSE_MCP_DLP goes missing"

  Scenario: a flagged tool listing is passed with a log line
    Given the broker sets TOKENFUSE_MCP_SCAN to block
    When compose.yaml sets it to warn
    Then broker-blocks-raw-secrets.sh fails
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the tool scan only warns"

  Scenario: the broker stops asking the policy plane
    Given the broker's wardryx hook is enforce by default
    When its default becomes off
    Then broker-blocks-raw-secrets.sh fails, because a denied tool would be called
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker's policy hook is off by default"

  Scenario: the broker has no policy plane to ask
    Given the broker's wardryx URL defaults to wardryx
    When its default becomes empty
    Then broker-blocks-raw-secrets.sh fails, because tokenfuse turns the hook off with no URL
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker's policy URL is empty by default"

  Scenario: an unreachable policy plane lets calls through
    Given the broker fails closed
    When its fail mode becomes open
    Then broker-blocks-raw-secrets.sh fails
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker fails open"

  Scenario: the image the broker runs refuses a raw secret and fails closed
    Given the image compose resolves for the broker, with the environment compose resolves for it
    When that image cannot serve the broker at all
    Then broker-blocks-raw-secrets.sh fails, because nothing showed that the running broker blocks
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker image is one that never answers"

  Scenario: a comment is reworded
    Given the gate passes on this tree
    When a comment in the broker's block is reworded
    Then broker-blocks-raw-secrets.sh still passes
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: a comment in the broker's block is reworded"

  Scenario: there is nothing to judge
    Given the gate finds the broker by its image and its mcp-broker command
    When no service runs the broker any more
    Then broker-blocks-raw-secrets.sh says it measured nothing and fails
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: no broker is left to judge"
