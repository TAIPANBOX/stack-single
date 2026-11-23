# @decided 2026-11-23 (paraphrased): curl | bash installs the latest release tag,
# the fetched tree is checked against a cosign-signed bundle, and main only with an
# explicit flag. CLAUDE.md invariant 84. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name, and scripts/features-are-bound.sh holds the
# binding both ways.
Feature: a piped install takes a signed release

  A script piped into a root shell decides what runs on somebody's box. It runs one
  tree, the latest release's, and only once that tree's signature from this
  repository's release workflow on that tag has checked.

  Scenario: the tree is used before its signature checks
    Given cosign checks the tarball against its bundle
    When the tree is unpacked or run before that check
    Then the gates fail
    # -> gates-have-teeth.sh "piped-tree: the signature is checked after the tree is unpacked"
    # -> gates-have-teeth.sh "no-download-outside-build: the release tree is unpacked before its signature"

  Scenario: a signature from somebody else is accepted
    Given the identity is this repository's release workflow on the tag being installed
    When it is widened to any repository
    Then the gate fails
    # -> gates-have-teeth.sh "piped-tree: the identity is widened to any repository"

  Scenario: main is reached for when a release fails
    Given main is unsigned and runs only by name
    When a failed check fetches main instead, or main is fetched outside its flag
    Then the gates fail
    # -> gates-have-teeth.sh "piped-tree: a failed check falls back to main"
    # -> gates-have-teeth.sh "no-download-outside-build: main is fetched outside its flag"

  Scenario: the tree is not the release it claims, or reaches outside itself
    Given the tarball holds one tree of the tag's version
    When a tree of another version is accepted, or a member that climbs out is unpacked
    Then the gate fails
    # -> gates-have-teeth.sh "piped-tree: a tree of another version is accepted"
    # -> gates-have-teeth.sh "piped-tree: a member that climbs out of the tarball is unpacked"

  Scenario: whoever serves the releases names an older one as the latest
    Given the server of the releases also answers which one is the latest
    When it names a signed release older than the script, and nobody asked for it by name
    Then the gate fails, because a mirror could roll a box back
    # -> gates-have-teeth.sh "piped-tree: a server can name an older release as the latest"

  Scenario: the files come from main again
    Given a piped install reads nothing from main's raw files
    When one is fetched again outside the bootstrap, or the README points back at main
    Then the gates fail
    # -> gates-have-teeth.sh "no-download-outside-build: a file of main is fetched outside the bootstrap again"
    # -> gates-have-teeth.sh "piped-tree: the README points back at main"

  Scenario: the release stops carrying a signature
    Given the release workflow signs the tarball on the tag
    When it stops signing
    Then the gate fails, because every new release would be refused
    # -> gates-have-teeth.sh "piped-tree: the release workflow stops signing"

  Scenario: nothing is left to judge
    Given the gate runs the bootstrap block
    When the block is gone
    Then the gate says it measured nothing
    # -> gates-have-teeth.sh "piped-tree: the block is gone (measured nothing)"

  Scenario: harmless changes are not faults
    Given messages are prose and the release may carry more of its own assets
    When a refusal is reworded, or the tree fetches one more asset of the release
    Then the gates still pass
    # -> gates-have-teeth.sh "piped-tree: a refusal is reworded (must pass)"
    # -> gates-have-teeth.sh "no-download-outside-build: the release tree fetches one more of its assets (must pass)"
