# @claude 2026-10-04, from the estate audit's launcher spec (wave 1): a run's budget must not
# be whatever the agent says it is. tokenfuse 1.5.0 can clamp the budget a
# caller declares; this launcher sets that ceiling on every gateway, from one
# installer variable, at tokenfuse's own default so an ordinary run is
# unchanged. Scenarios are bound to cases in scripts/gates-have-teeth.sh by
# name, and scripts/features-are-bound.sh holds the binding both ways.
Feature: the gateway clamps a run's budget to a ceiling the operator sets

  A run's budget used to come from the header the agent sends, and its next call
  could widen it. The ceiling, TOKENFUSE_MAX_RUN_BUDGET_USD, is off unless set,
  so a launcher that does not set it is exactly as unbounded as before and
  nothing says so. A budget set in the Cloud is the operator's own word and is
  never clamped.

  Scenario: the gateway loses its ceiling
    Given every gateway definition sets TOKENFUSE_MAX_RUN_BUDGET_USD
    When compose.yaml stops setting it
    Then run-budget-ceiling.sh fails and names the gateway and the missing variable
    # -> gates-have-teeth.sh "run-budget-ceiling: the gateway loses its ceiling"

  Scenario: the ceiling cannot be moved by the installer variable
    Given the ceiling is read from RUN_BUDGET_CEILING_USD with a default of 5.00
    When compose.yaml writes a literal figure, or reads another variable
    Then run-budget-ceiling.sh fails, because the one installer variable would do nothing
    # -> gates-have-teeth.sh "run-budget-ceiling: the ceiling becomes a literal"
    # -> gates-have-teeth.sh "run-budget-ceiling: the ceiling reads a variable the installer does not set"

  Scenario: the default stops being tokenfuse's own
    Given the default ceiling is 5.00, the default run budget of tokenfuse
    When the default becomes another figure, or zero
    Then run-budget-ceiling.sh fails, because an ordinary run would no longer be unchanged
    # -> gates-have-teeth.sh "run-budget-ceiling: the default ceiling drifts"
    # -> gates-have-teeth.sh "run-budget-ceiling: the default ceiling is zero"

  Scenario: the installer accepts a figure the gateway would refuse to start on
    Given tokenfuse exits 2 on zero, a sign, an exponent or a seventh decimal
    When install.sh accepts zero, or an exponent
    Then run-budget-ceiling.sh fails, because the box would install and then not come up
    # -> gates-have-teeth.sh "run-budget-ceiling: the installer accepts zero"
    # -> gates-have-teeth.sh "run-budget-ceiling: the installer accepts an exponent"

  Scenario: a refusal repeats what it was given
    Given a refused value is never echoed
    When the refusal message includes the value
    Then run-budget-ceiling.sh fails
    # -> gates-have-teeth.sh "run-budget-ceiling: the refusal echoes the value"

  Scenario: a second figure is added beside the first
    Given a run that sets the ceiling replaces the line in .env
    When it appends a second line instead
    Then run-budget-ceiling.sh fails, because the first line would win or lose by accident
    # -> gates-have-teeth.sh "run-budget-ceiling: a second figure is appended instead of replacing the first"

  Scenario: a bad figure left in .env by hand
    Given the gateway would exit on it at every start
    When install.sh accepts it
    Then run-budget-ceiling.sh fails
    # -> gates-have-teeth.sh "run-budget-ceiling: a bad ceiling left in .env is accepted"

  Scenario: the installer never writes the figure it was given
    Given the installer writes RUN_BUDGET_CEILING_USD into .env when a run sets it
    When the call that writes it is gone
    Then run-budget-ceiling.sh fails saying the block is dead text
    # -> gates-have-teeth.sh "run-budget-ceiling: the installer never writes the figure"

  Scenario: no gateway or no installer block left to judge
    Given the gateway is found by its image and bare command
    When it no longer has that shape, or the installer's block is gone
    Then run-budget-ceiling.sh says it measured nothing, never OK
    # -> gates-have-teeth.sh "run-budget-ceiling: no gateway service left to judge"
    # -> gates-have-teeth.sh "run-budget-ceiling: the installer block is gone"

  Scenario: a reworded refusal and a changed broker are not this gate's business
    Given the gate judges the figure and the variable, not the prose or the broker
    When the refusal is reworded, or the MCP broker's address changes
    Then run-budget-ceiling.sh still passes
    # -> gates-have-teeth.sh "run-budget-ceiling: the refusal is reworded"
    # -> gates-have-teeth.sh "run-budget-ceiling: the broker's configuration changes"
