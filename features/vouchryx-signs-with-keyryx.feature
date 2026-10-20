# Provenance: @decided 2026-10-19 (paraphrased). Each scenario is bound to a teeth case by name.
Feature: vouchryx signs with a key keyryx certifies, against a root this box pins

  Scenario: a box that names no signer signs with the key keyryx certifies
    Given .env names no VOUCHRYX_SIGNER
    When the resolved configuration is read
    Then vouchryx's signer is keyryx, and vouchryx waits for keyryx to start
    # -> gates-have-teeth.sh "agent-tokens-are-wired: vouchryx's default signer is the file key again"
    # -> gates-have-teeth.sh "agent-tokens-are-wired: vouchryx does not wait for keyryx"

  Scenario: the root pin is taken before vouchryx starts, and only a well-formed key set is kept
    Given keyryx serves its delegation root and .env holds no pin yet
    When install.sh is about to start vouchryx
    Then the pin is the ES384 and ML-DSA-65 kids keyryx serves, and a key set of the wrong shape is refused
    # -> gates-have-teeth.sh "agent-tokens-are-wired: vouchryx is started before its root pin is taken"
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the root pin accepts an ES384 kid of the wrong length"
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the root pin accepts an ML-DSA-65 kid without its prefix"

  Scenario: the file signer keeps the file key and gives vouchryx no keyryx variable
    Given .env says VOUCHRYX_SIGNER=file
    When the resolved configuration is read
    Then no keyryx variable reaches vouchryx, which refuses to start with one under the file signer
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the file signer keeps a keyryx variable"
