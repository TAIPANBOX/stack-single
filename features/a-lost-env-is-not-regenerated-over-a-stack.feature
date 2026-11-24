# @claude 2026-11-23, from stack-single#62: a box that loses .env and is installed
# again must not be handed a new Postgres password its database does not know.
# CLAUDE.md invariant 81. Scenarios are bound to cases in scripts/gates-have-teeth.sh
# by name, and scripts/features-are-bound.sh holds the binding both ways.
Feature: a lost .env is not regenerated over a stack

  .env holds every secret this box has, and the policy database knows only the
  password it was created with. A re-run that writes a fresh .env over the old
  volumes stops wardryx, and both doors fail closed.

  Scenario: the stack's volumes are on the box and .env is gone
    Given this project's volumes are on the box
    When a run finds no .env and goes on to write one
    Then the gate fails, because the database would not know the new password
    # -> gates-have-teeth.sh "env-guard: volumes on the box do not stop a fresh .env"
    # -> gates-have-teeth.sh "env-guard: only labelled volumes are looked for"

  Scenario: another project's volume stops a fresh box
    Given Docker's name filter matches anywhere in a volume's name
    When a volume of another project, named foo-agent-stack_data, is taken for this stack's
    Then the gate fails, because a clean box would be refused
    # -> gates-have-teeth.sh "env-guard: another project's volume stops a fresh box"
    # -> gates-have-teeth.sh "env-guard: a fresh box with no volumes stops the run"

  Scenario: Docker cannot say what the box holds
    Given Docker is installed and does not answer
    When the run reads that as an empty box
    Then the gate fails
    # -> gates-have-teeth.sh "env-guard: a Docker that does not answer is read as an empty box"

  Scenario: an empty .env is taken for a real one
    Given a .env of zero bytes holds no secret
    When the run treats it as present
    Then the gate fails
    # -> gates-have-teeth.sh "env-guard: an empty .env counts as one"

  Scenario: the operator is not told the way through
    Given a refusal is right only if the operator can act on it
    When it stops naming FRESH_ENV=1
    Then the gate fails
    # -> gates-have-teeth.sh "env-guard: the refusal stops naming the way through"

  Scenario: the refusal comes after the box was changed
    Given a refusal must come before anything is installed
    When the check moves after the first package install
    Then the gate fails
    # -> gates-have-teeth.sh "env-guard: the check moves after the first package install"

  Scenario: the README stops saying what to back up
    Given .env is the one file the volumes cannot be used without
    When the README loses its backup section
    Then the gate fails
    # -> gates-have-teeth.sh "env-guard: the README loses the backup section"

  Scenario: nothing is left to judge
    Given the gate reads the env-guard block
    When the block is gone
    Then the gate says it measured nothing
    # -> gates-have-teeth.sh "env-guard: the block is gone (measured nothing)"

  Scenario: a harmless change is not a fault
    Given comments are prose
    When a comment in the block is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "env-guard: a comment in the block is reworded (must pass)"
