# @claude 2026-11-23: the console's own revoke button, wired here as stack-k8s and
# stack-up wire it, with a key of its own only the console holds. CLAUDE.md
# invariant 82. Scenarios are bound to cases in scripts/gates-have-teeth.sh by
# name, and scripts/features-are-bound.sh holds the binding both ways.
Feature: the console can revoke a delegation

  Cutting a compromised agent off is a revocation at vouchryx. A person does it
  from the console, behind a passkey, with a key that belongs to the console and to
  nothing else, so the console's can be taken away without touching the operator's.

  Scenario: the console is not told where vouchryx is, or which key to use
    Given the console's revoke command reads vouchryx's address and a key file
    When either is gone from its settings
    Then the gate fails, because the button would refuse every revocation
    # -> gates-have-teeth.sh "console-revoke: the console loses vouchryx's address"
    # -> gates-have-teeth.sh "console-revoke: the console loses its key file"

  Scenario: vouchryx does not hold the console's key
    Given vouchryx accepts the keys VOUCHRYX_REVOKE_KEYS lists
    When the console's key is not among them
    Then the gate fails, because every revocation from the console would be refused 401
    # -> gates-have-teeth.sh "console-revoke: vouchryx does not take the console's key"

  Scenario: somebody else can read or change the console's key
    Given the key is a file only the console mounts, read only, mode 0400
    When it is mounted read-write, mounted by another service, or readable by its group
    Then the gate fails
    # -> gates-have-teeth.sh "console-revoke: the key is mounted read-write"
    # -> gates-have-teeth.sh "console-revoke: another service mounts the console's key"
    # -> gates-have-teeth.sh "console-revoke: the key file is readable by its group"

  Scenario: the key file does not hold the key
    Given the console trims nothing it was not told to, and vouchryx compares the key exactly
    When the file gets a newline, or a link planted at its name is followed
    Then the gate fails
    # -> gates-have-teeth.sh "console-revoke: the key file gets a newline"
    # -> gates-have-teeth.sh "console-revoke: a link at the key's name is followed"

  Scenario: the install stops asking vouchryx about the key
    Given the install checks that vouchryx takes the console's key and refuses one it does not hold
    When that check is gone
    Then the gate fails
    # -> gates-have-teeth.sh "console-revoke: install.sh stops asking vouchryx about the key"

  Scenario: nothing is left to judge
    Given the gate runs the installer's key block
    When the block is gone
    Then the gate says it measured nothing
    # -> gates-have-teeth.sh "console-revoke: the block is gone (measured nothing)"

  Scenario: a harmless change is not a fault
    Given a note is prose
    When it is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "console-revoke: a note is reworded (must pass)"
