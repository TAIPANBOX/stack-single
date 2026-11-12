# Provenance: @claude 2026-10-19, from wardryx 2.4.0 (approver statements) and genaryx #132 (the console signs them). Each scenario is bound to a teeth case by name.
Feature: The console's approver key signs each approval, and a bare key cannot approve

  Scenario: the approver key is minted once, as PKCS#8, and kept
    Given a box with no approver key
    When install.sh runs, and then runs again
    Then the key is PKCS#8 P-256 at mode 0600, the second run keeps its bytes, and nothing prints it
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver key is not PKCS#8"
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver key is left world-readable"
    # -> gates-have-teeth.sh "approver-key-is-wired: a re-run replaces the approver key"

  Scenario: a pinned console that cannot print its key set stops the install, and an operator's older console turns the check off out loud
    Given the console image cannot print its approver key set
    When install.sh runs
    Then the pinned image stops the install before anything starts, and a console the operator named writes no key set, drops WARDRYX_APPROVER_JWKS and says so
    # -> gates-have-teeth.sh "approver-key-is-wired: the key set is switched on without a console that can print it"
    # -> gates-have-teeth.sh "approver-key-is-wired: a pinned console that cannot print turns the check off quietly"
    # -> gates-have-teeth.sh "approver-key-is-wired: an older console keeps the key set"

  Scenario: a bare key is never allowed to approve, and wardryx reads statements
    Given the compose file that the installer writes
    When it is read
    Then WARDRYX_ALLOW_KEY_APPROVALS names nothing, wardryx is at least the 2.4.0 image, and the private key reaches the console alone
    # -> gates-have-teeth.sh "approver-key-is-wired: the bare-key switch is set"
    # -> gates-have-teeth.sh "approver-key-is-wired: wardryx is pinned back to 2.3.0"
    # -> gates-have-teeth.sh "approver-key-is-wired: the console loses its key mount"
    # -> gates-have-teeth.sh "approver-key-is-wired: the private key reaches wardryx"

  # @claude 2026-11-12: found when a person's first passkey grant of a held call on a live box was
  # refused, and went through only after two fixes by hand; these hold that a fresh install needs neither.
  Scenario: the console reaches its approver key whatever the umask of the shell that ran the installer
    Given install.sh runs from a root shell whose umask is 077, or 022
    When it makes the directory that holds the approver key
    Then the directory is root's, its group the console's, mode 0710: the console passes through it to its key, and no other account can enter or list it
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver directory is left to the umask"
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver directory is listable by others"
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver directory is not given the console's group"
    # -> gates-have-teeth.sh "approver-key-is-wired: a reworded comment on the approver directory is not a fault"

  Scenario: the key and its directory belong to the user the console runs as
    Given compose.yaml pins the console's user, and install.sh gives the key and the directory to it
    When the pin is removed, or names a uid the key is not given to
    Then the gate fails
    # -> gates-have-teeth.sh "approver-key-is-wired: the console's user is no longer pinned"
    # -> gates-have-teeth.sh "approver-key-is-wired: the console runs as a uid the key is not given to"
