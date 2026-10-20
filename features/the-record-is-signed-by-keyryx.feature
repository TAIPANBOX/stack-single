# Provenance: @claude 2026-10-19, from trailryx v1.4.0 (the seal's keyryx signer) and keyryx v0.1.1 (the witness's records). Each scenario is bound to a teeth case by name.
Feature: The record seal signs its roots through the box's keyryx, and the witness attests to them

  Scenario: the seal signs through keyryx with a credential the custody holds only as a digest
    Given the record plane is running on a box with keyryx
    When the seal signs a sealed root
    Then it presents its own credential to keyryx, and keyryx holds only the credential's digest
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the seal does not sign through keyryx"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the credential is readable by every user"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the credential is written with a newline"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the custody holds the socket, not the digest"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the credential is printed when it is minted"

  Scenario: the witness attests to the records, and the seal does not read the attestations yet
    Given keyryx-witness is running beside the seal
    When it reads the records
    Then it writes an attestation per root, and the seal reads none until a keyryx release writes them group-readable
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the witness reads no records"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the seal reads attestations that keyryx writes 0600"

  Scenario: the root pin is not set until trailryx releases it
    Given trailryx has not released its root pin
    When the seal starts
    Then TRAILRYX_KEYRYX_KID is a named TODO and no pin is set
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the root pin is set before it is released"
