# Written from what an operator needs when the wrong tree is about to run on a box: a stale
# clone, the wrong tag, an old path in a script. This is a guard against that mistake and
# nothing more. The check lives inside the tree it checks and the tree is not signed, so an
# older tree does not have it, and the feature says so as firmly as it says the rest.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the box does not go backwards by accident

  Each run of the installer writes to a journal on the box. A plain integer in the tree,
  the rollback index, goes up only when an older tree has become unsafe. A tree below what
  the box has run is refused before anything changes, and a written reason is the way
  through.

  Scenario: a tree below the box's rollback index is refused before anything changes
    Given a box whose last good run was at a higher index than this tree
    When the operator runs the installer
    Then it stops in the preflight, no tool runs, and no file of the box changes
    # -> gates-have-teeth.sh "rollback-floor: a tree below the floor passes"
    # -> gates-have-teeth.sh "rollback-floor: the check stands after the package step"
    # -> gates-have-teeth.sh "rollback-floor: the journal is written before the refusal"

  Scenario: the refusal says the exact way through
    Given a tree below the floor
    When the installer refuses it
    Then the refusal names the tree's index, the box's floor, the command that goes on and that nothing was changed
    # -> gates-have-teeth.sh "rollback-floor: the refusal drops the way through"

  Scenario: going below it needs a reason, and the reason is kept
    Given a tree below the floor
    When the operator sets ALLOW_ROLLBACK=1
    Then it goes on only with a written reason, and the reason is in the journal
    # -> gates-have-teeth.sh "rollback-floor: the override needs no reason"
    # -> gates-have-teeth.sh "rollback-floor: the reason is not kept"
    # -> gates-have-teeth.sh "rollback-floor: a flag other than 1 opens the way"

  Scenario: a reason is one line of the journal and cannot forge another
    Given a reason with a new line, a control character or a quote in it
    When the operator goes on with it
    Then it is refused, and a reason in another alphabet is kept as written
    # -> gates-have-teeth.sh "rollback-floor: a reason can forge a run"

  Scenario: a tree of the same index installs, so an ordinary rollback still works
    Given a tree at the box's floor, or above it
    When the operator runs the installer
    Then it goes on, whatever the versions are, and 10 is above 9
    # -> gates-have-teeth.sh "rollback-floor: the same index is refused"
    # -> gates-have-teeth.sh "rollback-floor: the indices are compared as strings"
    # -> gates-have-teeth.sh "rollback-floor: the floor is taken as a string"

  Scenario: the floor moves only after every check passed
    Given a run that reaches its end with no failed check
    When the journal is read again
    Then its index is the floor, and neither an attempt nor an override moved it
    # -> gates-have-teeth.sh "rollback-floor: the floor moves from an attempt"
    # -> gates-have-teeth.sh "rollback-floor: a good run writes no good line"

  Scenario: a failed upgrade leaves the floor where it was
    Given a run that ends with a failed check
    When the journal is read again
    Then its result is recorded and the floor did not move, so going back needs no override
    # -> gates-have-teeth.sh "rollback-floor: a failed run writes a good line"
    # -> gates-have-teeth.sh "rollback-floor: the end of the run is written before the checks"

  Scenario: a box from before this release is upgraded without a refusal
    Given a box with no journal, with or without a .env
    When the operator runs the installer
    Then nothing is refused, and a box that had a .env says the journal started there
    # -> gates-have-teeth.sh "rollback-floor: a box with no journal is refused"
    # -> gates-have-teeth.sh "rollback-floor: first seen is not written"

  Scenario: a line of the journal that cannot be read stops the run and names the line
    Given a journal with a line of noise, a half-written line or an index that is no number
    When the operator runs the installer
    Then it stops and names the line, because a skipped line can be the one that held the floor
    # -> gates-have-teeth.sh "rollback-floor: a line that cannot be read is skipped"

  Scenario: a piped install whose compose file is not its own version is refused
    Given install.sh and compose.yaml fetched in two requests, from two commits
    When the versions differ
    Then the run stops, and the box's own compose.yaml and journal are as they were
    # -> gates-have-teeth.sh "rollback-floor: the version of the compose file is not compared"
    # -> gates-have-teeth.sh "rollback-floor: the fetch writes over the box's file"

  Scenario: a tree that carries a journal of its own leaves the box's in place
    Given a tree copied from a box, with that box's journal inside it
    When the installer copies the tree over the stack
    Then the box keeps its own journal and its own floor
    # -> gates-have-teeth.sh "rollback-floor: the tree's journal replaces the box's"

  Scenario: status names the last good install and the last override
    Given a box with a journal
    When the operator runs status
    Then one line gives the last good install, its index and the last override, and the journal is not written
    # -> gates-have-teeth.sh "status-is-read-only: status prints no line from the journal"
    # -> gates-have-teeth.sh "rollback-floor: status drops the index"
    # -> gates-have-teeth.sh "rollback-floor: status drops the override"
    # -> gates-have-teeth.sh "rollback-floor: status writes the journal"

  Scenario: the decision reads an integer, raised only with a release note
    Given the tree
    When the gate reads it
    Then the block compares no version, the index is a plain number no environment can set, and a raise names itself in the notes
    # -> gates-have-teeth.sh "rollback-floor: the block compares versions"
    # -> gates-have-teeth.sh "rollback-floor: the index comes from the environment"
    # -> gates-have-teeth.sh "rollback-floor: the index is raised with no release note"
    # -> gates-have-teeth.sh "rollback-floor: the index is raised with its release note"

  Scenario: the tree says one version everywhere
    Given install.sh, compose.yaml, the newest release notes and a tag
    When the gate reads them
    Then they are one number, and the newest notes are found as numbers and not as text
    # -> gates-have-teeth.sh "version-is-one-number: compose.yaml says another number"
    # -> gates-have-teeth.sh "version-is-one-number: install.sh says another number"
    # -> gates-have-teeth.sh "version-is-one-number: install.sh says it twice"
    # -> gates-have-teeth.sh "version-is-one-number: release notes arrive with no bump"
    # -> gates-have-teeth.sh "version-is-one-number: the newest notes are found as numbers"
    # -> gates-have-teeth.sh "version-is-one-number: a tag of another number"

  Scenario: the docs say what this is and what it is not
    Given the README
    When the gate reads it
    Then it says this is a guard against mistakes and not protection against an attacker, that the check lives inside an unsigned tree, that an older tree has no check, and it names .env images and a direct compose up as outside it
    And no sentence says the stack cannot be rolled back
    # -> gates-have-teeth.sh "rollback-floor: the README says the stack cannot be rolled back"
    # -> gates-have-teeth.sh "rollback-floor: the README stops saying it guards against mistakes"
    # -> gates-have-teeth.sh "rollback-floor: the README stops naming the attacker"
    # -> gates-have-teeth.sh "rollback-floor: the README stops saying the tree is not signed"
    # -> gates-have-teeth.sh "rollback-floor: the README stops saying where the check lives"
    # -> gates-have-teeth.sh "rollback-floor: the README stops saying an older tree has no check"
    # -> gates-have-teeth.sh "rollback-floor: the README drops the image overrides"
    # -> gates-have-teeth.sh "rollback-floor: the README drops a direct compose up"

  Scenario: rewording the code around it changes no verdict
    Given a comment reworded, or a sentence of the refusal
    When the gates run
    Then they still pass
    # -> gates-have-teeth.sh "rollback-floor: a comment in the block is reworded"
    # -> gates-have-teeth.sh "rollback-floor: a sentence of the refusal is reworded"
    # -> gates-have-teeth.sh "version-is-one-number: a comment beside the version is reworded"

  Scenario: the gates do not report OK on nothing
    Given no block, no function, no call in section 1, no README section, no constant or no notes
    When the gates run
    Then each says it measured nothing and fails
    # -> gates-have-teeth.sh "rollback-floor: the block is gone"
    # -> gates-have-teeth.sh "rollback-floor: the function is gone"
    # -> gates-have-teeth.sh "rollback-floor: section 1 calls nothing"
    # -> gates-have-teeth.sh "rollback-floor: the README section is gone"
    # -> gates-have-teeth.sh "version-is-one-number: install.sh has no version"
    # -> gates-have-teeth.sh "version-is-one-number: compose.yaml has no version"
    # -> gates-have-teeth.sh "version-is-one-number: there are no release notes"
