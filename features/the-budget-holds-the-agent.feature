# @claude 2026-11-07, from the go to connect the signal in both stacks; a reading of that task, not words of the owner.
# Each scenario is bound by name to a case in scripts/gates-have-teeth.sh.
Feature: An agent whose error budget is spent waits for a person

  An agent that has used up its error budget has its calls put to a person
  automatically, and goes back to working alone when its budget recovers. Both
  stacks do this out of the box, and it can be narrowed or turned off.

  Scenario: A box where nobody chose anything holds a spent budget
    Given a box installed with nothing said about error budgets
    When an agent's budget is spent
    Then the routine has measured it and written it to its own stream
    And wardryx reads that stream
    And one rule in policy.yaml holds that agent's calls for a person
    # -> gates-have-teeth.sh "slo-signal-is-wired: wardryx is not handed the file"
    # -> gates-have-teeth.sh "slo-signal-is-wired: the rule holds on a broken file"

  Scenario: A hold does not keep itself alive
    Given an agent on hold because its budget is spent
    When its calls are held and it keeps working
    Then the holds do not spend more of its budget
    And it can earn the budget back
    # -> gates-have-teeth.sh "slo-signal-is-wired: a hold spends the budget that caused it"

  Scenario: No other plane can end a hold by writing the file
    Given the file a hold stands on
    Then only the routine can write it
    And no plane can remove it from the bus
    # -> gates-have-teeth.sh "slo-signal-is-wired: the routine shares a uid with another plane"
    # -> gates-have-teeth.sh "slo-signal-is-wired: the file is not pre-created under the routine's uid"

  Scenario: A routine that cannot measure does not look like a healthy fleet
    Given the routine fails to read the traces
    Then the container stops and shows as restarting
    And nothing reports that all is well
    # -> gates-have-teeth.sh "slo-signal-is-wired: a failed measurement is swallowed"

  Scenario: The operator can turn it off and narrow it
    Given SLO_SIGNAL=0
    Then the routine, the path and the rule are all gone
    And the operator's own rules are as they were
    And SLO_HOLD_TARGET narrows the rule to one agent glob, or none measures and holds nobody
    # -> gates-have-teeth.sh "slo-signal-is-wired: the flag off leaves wardryx reading"

  Scenario: A second run leaves the policy where it is
    Given a box with the risk hold and the budget hold in policy.yaml
    When the installer runs again with nothing changed
    Then neither block moves and wardryx is not restarted
    # -> gates-have-teeth.sh "slo-signal-is-wired: the risk block moves on every run"

  Scenario: The quality routines can start
    Given a routine that runs on the console's image
    Then it replaces the image's entrypoint
    And the console server is not handed a shell as an argument
    # -> gates-have-teeth.sh "slo-signal-is-wired: verdryx-drift keeps the console's entrypoint"
