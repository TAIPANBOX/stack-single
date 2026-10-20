# Provenance: @claude 2026-10-19, from wardryx 2.4.0 (approver statements) and genaryx #132 (the console signs them). Each scenario is bound to a teeth case by name.
Feature: The console's approver key signs each approval, and a bare key cannot approve

  Scenario: the approver key is minted once, as PKCS#8, and kept
    Given a box with no approver key
    When install.sh runs, and then runs again
    Then the key is PKCS#8 P-256 at mode 0600, the second run keeps its bytes, and nothing prints it
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver key is not PKCS#8"
    # -> gates-have-teeth.sh "approver-key-is-wired: the approver key is left world-readable"
    # -> gates-have-teeth.sh "approver-key-is-wired: a re-run replaces the approver key"

  Scenario: statements are checked only once the console can print its key set
    Given the pinned console image cannot print its approver key set
    When install.sh runs
    Then no key set is written, WARDRYX_APPROVER_JWKS stays unset, and wardryx decides as 2.3.0 did
    # -> gates-have-teeth.sh "approver-key-is-wired: the key set is switched on without a console that can print it"

  Scenario: a bare key is never allowed to approve, and wardryx is the 2.4.0 image
    Given the compose file that the installer writes
    When it is read
    Then WARDRYX_ALLOW_KEY_APPROVALS names nothing, wardryx is pinned to v2.4.0, and the private key reaches the console alone
    # -> gates-have-teeth.sh "approver-key-is-wired: the bare-key switch is set"
    # -> gates-have-teeth.sh "approver-key-is-wired: wardryx is pinned back to 2.3.0"
    # -> gates-have-teeth.sh "approver-key-is-wired: the console loses its key mount"
    # -> gates-have-teeth.sh "approver-key-is-wired: the private key reaches wardryx"
