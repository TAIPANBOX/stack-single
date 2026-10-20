# Provenance: @claude 2026-10-19, from a defect a forge run found: the crew could not spend at all, and its ceiling was undocumented.
# Each scenario is bound to a teeth case by name.
Feature: CostCrew's runner spends only through the gateway, under a ceiling an operator chose

  Scenario: the runner is started by a person, and only under the console's cadence switch
    Given the add-on is started with its profile
    When the runner is not named in the start command
    Then it is not running, and install.sh never starts it
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the runner starts with the add-on's profile"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the runner runs live"

  Scenario: the crew's model calls leave through the gateway with the crew's own key, and nothing else
    Given the runner is started by hand under the crew profile
    When it calls a model
    Then the call goes to the gateway with the crew's client key, and the runner has no route to a provider
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the runner loses its gateway"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the runner joins the edge network"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the runner holds a provider key"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the crew's key is not minted"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the crew's key is bound to every agent"

  Scenario: a box that names no ceiling spends nothing, holds no crew key, and a ceiling must be a decimal dollar figure
    Given COSTCREW_CEILING is not set, or is 0
    When install.sh runs
    Then the runner's ceiling is 0, no crew key is minted or kept, and a figure with a sign, an exponent or a third decimal is refused before anything is installed
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the default ceiling spends"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the ceiling accepts a sign"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the crew's key is minted on a zero ceiling"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the crew's key is kept on a zero ceiling"
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the ceiling test accepts zero"

  Scenario: the console still cannot spend
    Given the console is started with the add-on
    When its command is read
    Then it names no gateway, so it has no model path of its own
    # -> gates-have-teeth.sh "costcrew-runner-spends-through-the-gateway: the console is given a gateway"
