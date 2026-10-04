# @decided 2026-10-04, from the estate audit (wave 1): the tokenfuse gateway's
# declassify endpoint lifts a run's taint label and its credential is optional,
# so a launcher that sets none leaves the endpoint open to anything that reaches
# the gateway port. Scenarios are bound to cases in scripts/gates-have-teeth.sh
# by name; this repository has no runner and no binding gate, so the binding is
# by eye, as in stack-k8s's features/.
Feature: the gateway's declassify key is minted per install and only the operator holds it

  POST /v1/fuse/declassify takes a run's taint label off after a person reviewed
  it. It is not behind the admin key. Its own key is optional in the gateway, and
  with none set, anything that can reach the gateway port can clear a run, which
  the event records only as "authenticated: false". Nothing in the estate calls
  the endpoint, so a key that only the operator holds closes it and breaks nothing.

  Scenario: the gateway loses its declassify key
    Given the gateway service sets TOKENFUSE_DECLASSIFY_KEY from a secret in .env
    When compose.yaml stops setting it
    Then declassify-is-keyed.sh fails and names the service and the missing variable
    # -> gates-have-teeth.sh "declassify-is-keyed: TOKENFUSE_DECLASSIFY_KEY goes missing"

  Scenario: the key is committed as a literal
    Given the gateway service sets TOKENFUSE_DECLASSIFY_KEY from a secret in .env
    When compose.yaml writes a literal value instead
    Then declassify-is-keyed.sh fails saying a literal is not a required secret interpolation
    # -> gates-have-teeth.sh "declassify-is-keyed: the key becomes a literal"

  Scenario: the key gets an empty default
    Given the gateway service sets TOKENFUSE_DECLASSIFY_KEY from a required variable
    When compose.yaml gives that variable an empty default
    Then declassify-is-keyed.sh fails, because the endpoint would be open on a box whose .env lacks the key
    # -> gates-have-teeth.sh "declassify-is-keyed: the key gets an empty default"

  Scenario: the installer stops minting the key
    Given install.sh mints GATEWAY_DECLASSIFY_KEY with gen
    When that line is removed
    Then declassify-is-keyed.sh fails saying install.sh never mints it
    # -> gates-have-teeth.sh "declassify-is-keyed: install.sh stops minting the key"

  Scenario: the installer mints the same key everywhere
    Given install.sh mints GATEWAY_DECLASSIFY_KEY with gen
    When it mints a fixed string instead
    Then declassify-is-keyed.sh fails saying the key is not random per install
    # -> gates-have-teeth.sh "declassify-is-keyed: install.sh mints a fixed key"

  Scenario: no gateway service left to judge
    Given the gateway service is found by its image and bare command
    When it no longer has that shape
    Then declassify-is-keyed.sh fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "declassify-is-keyed: no gateway service left to judge"

  Scenario: no installer left to read
    Given install.sh is where the key is minted
    When install.sh is not there
    Then declassify-is-keyed.sh fails saying it measured nothing about the mint
    # -> gates-have-teeth.sh "declassify-is-keyed: no install.sh left to read"

  Scenario: the broker and a reworded message are not this gate's business
    Given the MCP broker runs the gateway image on a subcommand and never serves the route
    When the broker's address changes, or the required-variable message is reworded
    Then declassify-is-keyed.sh still passes
    # -> gates-have-teeth.sh "declassify-is-keyed: the mcp broker's configuration changes"
    # -> gates-have-teeth.sh "declassify-is-keyed: the required-variable message is reworded"
