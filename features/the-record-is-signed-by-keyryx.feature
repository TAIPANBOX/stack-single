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

  Scenario: the witness attests to the records, and the seal reads the attestations through a read-only folder
    Given keyryx-witness is running beside the seal
    When it reads the records
    Then it writes an attestation per root, and the seal reads them through its own read-only attestations folder and nothing else of the witness's
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the witness reads no records"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the seal mounts the attestations folder read-write"
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the seal reads the witness's whole volume"

  Scenario: the seal starts with the root pin the installer took from custody
    Given trailryx 1.5.0 refuses to start under the keyryx signer with no root pin
    When the seal starts
    Then TRAILRYX_KEYRYX_KID is read from .env, where the installer wrote it once
    # -> gates-have-teeth.sh "record-is-signed-by-keyryx: the seal starts with no root pin"
