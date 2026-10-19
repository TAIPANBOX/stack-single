# CLAUDE.md invariant 44. @decided 2026-10-18 (paraphrased): every image the
# launcher runs is pinned by digest, and every image this project publishes is
# checked against its keyless signature before the stack starts. Third-party
# images are pinned, not signature-checked.
Feature: Images are pinned by digest, and ours are verified before anything starts

  Scenario: Every image compose runs is pinned by digest
    Given compose.yaml names an image for every service
    When the digest gate reads each image reference
    Then every reference carries a sha256 digest after its tag
    # -> gates-have-teeth.sh "images-are-digest-pinned: a published image loses its digest"

  Scenario: A digest shorter than a full sha256 is refused
    Given a reference whose digest has fewer than 64 hex characters
    When the digest gate reads it
    Then the gate reports it as not pinned
    # -> gates-have-teeth.sh "images-are-digest-pinned: a digest is cut short"

  Scenario: The image a stock box starts for a third party is pinned too
    Given the third-party images busybox and postgres
    When the digest gate reads compose.yaml
    Then each of them carries a digest after its tag
    # -> gates-have-teeth.sh "images-are-digest-pinned: the third-party postgres loses its digest"

  Scenario: An image the installer names itself is pinned to the same digest as compose
    Given install.sh names the vouchryx image for its demo key
    When the digest gate compares it with compose.yaml
    Then the two references carry the same digest
    # -> gates-have-teeth.sh "images-are-digest-pinned: the installer names a digest compose does not run"

  Scenario: The digest gate measures nothing when compose names no image
    Given a compose.yaml with no image line
    When the digest gate runs
    Then it refuses to report OK
    # -> gates-have-teeth.sh "images-are-digest-pinned: no image line left to judge"

  Scenario: Every TAIPANBOX image is checked with cosign before it is pulled
    Given a compose file that runs TAIPANBOX images
    When the installer resolves the images to pull
    Then cosign verifies each TAIPANBOX image before docker pull names it
    # -> gates-have-teeth.sh "images-are-verified: the pull comes before the check"

  Scenario: A TAIPANBOX image that does not verify stops the install before anything starts
    Given cosign refuses the signature of one TAIPANBOX image
    When the installer runs the check
    Then it stops before that image is pulled and before docker compose up
    # -> gates-have-teeth.sh "images-are-verified: a refused signature does not stop the install"

  Scenario: The signer must be a TAIPANBOX GitHub workflow on a release tag
    Given the keyless identity the installer accepts
    When the verify gate reads it
    Then it names the TAIPANBOX workflows, the GitHub issuer and a release tag, and nothing wider
    # -> gates-have-teeth.sh "images-are-verified: the signer accepts any identity"

  Scenario: The verify call cannot skip the transparency log or the certificate checks
    Given the cosign verify call the installer makes
    When the verify gate reads it
    Then it carries no flag that skips the transparency log, the SCT or the identity
    # -> gates-have-teeth.sh "images-are-verified: the verify call skips the transparency log"

  Scenario: The cosign binary is never run unless its SHA-256 matches the pin
    Given a cosign download whose bytes differ from the pinned SHA-256
    When the installer fetches it
    Then the installer refuses it and never installs it
    # -> gates-have-teeth.sh "images-are-verified: a cosign binary with the wrong bytes is installed"

  Scenario: A third-party image is never sent to cosign
    Given an image from Docker Hub in the list of images to pull
    When the installer checks signatures
    Then cosign is not asked about it
    # -> gates-have-teeth.sh "images-are-verified: a third-party image goes to cosign"

  Scenario: The verify gate measures nothing when the installer has no check
    Given an install.sh with no image-verify block
    When the verify gate runs
    Then it refuses to report OK
    # -> gates-have-teeth.sh "images-are-verified: no image-verify block left to judge"
