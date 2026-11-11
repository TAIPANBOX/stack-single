# @decided 2026-11-11 (paraphrased): the installer does not download the tree of another repository on a run that
# does not build from it. @claude 2026-11-11: the shape on this box (the fetch moved into the build branch, the gate
# listing the two downloads that are allowed and why) is my reading of what that takes here. Each scenario is bound by
# name to a case in scripts/gates-have-teeth.sh, and scripts/features-are-bound.sh holds the binding both ways.
Feature: the installer fetches no tree it does not need, and unpacks nothing it did not check

  The installer runs as root on a machine somebody cares about. It pulled the tarball of stack-k8s's main branch on
  every run and unpacked it there, though every image is pulled ready, signed and pinned, and the tree is read only
  when someone builds from source. A moving branch unpacked as root for a path that run does not take is risk with no
  use, so the fetch belongs to the build path alone.

  Scenario: the tarball comes back on every run
    Given only the build from source reads the stack-k8s tree
    When the installer fetches the tarball outside the build branch again
    Then no-unverified-download-outside-build.sh fails, because a branch of another repository is unpacked as root for nothing
    # -> gates-have-teeth.sh "no-download-outside-build: the stack-k8s tarball is fetched on every run again"

  Scenario: a script is piped into a shell
    Given nothing the installer downloads outside the build is run without a check
    When a download is piped into bash
    Then no-unverified-download-outside-build.sh fails
    # -> gates-have-teeth.sh "no-download-outside-build: a script is piped into bash"

  Scenario: a file is kept with no check
    Given a file is kept only after its hash is checked, or when it is a file of this repository in a piped install
    When a download is written to a file with neither
    Then no-unverified-download-outside-build.sh fails
    # -> gates-have-teeth.sh "no-download-outside-build: a file is downloaded and kept with no check"

  Scenario: a repository is cloned outside the build
    Given a clone brings whatever its branch holds
    When the installer clones a repository outside the build branch
    Then no-unverified-download-outside-build.sh fails
    # -> gates-have-teeth.sh "no-download-outside-build: a repository is cloned outside the build"

  Scenario: cosign is installed without its check
    Given the cosign binary is the one download that is run, so its SHA-256 is checked against the pin before it is moved into place
    When the check is taken out
    Then no-unverified-download-outside-build.sh fails
    # -> gates-have-teeth.sh "no-download-outside-build: cosign is installed without its SHA-256 check"

  Scenario: the ordinary path reads the tree
    Given the ordinary path no longer fetches the stack-k8s tree
    When a statement outside the build branch reads it
    Then no-unverified-download-outside-build.sh fails, because the read would meet a tree that is not there
    # -> gates-have-teeth.sh "no-download-outside-build: the installer reads the stack-k8s tree outside the build"

  Scenario: the unused raw address comes back
    Given nothing reads the raw address of stack-k8s's main branch
    When the variable that names it is defined again
    Then no-unverified-download-outside-build.sh fails
    # -> gates-have-teeth.sh "no-download-outside-build: REPO_RAW comes back"

  Scenario: a piped install fetches its files from somewhere else
    Given a piped install fetches the files of this repository and nothing else
    When it fetches them from another address
    Then no-unverified-download-outside-build.sh fails
    # -> gates-have-teeth.sh "no-download-outside-build: a piped install fetches its files from another URL"

  Scenario: the build branch is not found
    Given the gate judges what lies outside the build branch
    When no build branch can be found
    Then no-unverified-download-outside-build.sh says it measured nothing and fails
    # -> gates-have-teeth.sh "no-download-outside-build: the build block is gone (measured nothing)"

  Scenario: an exception matches nothing
    Given each named exception must match a line of the installer
    When the cosign download is renamed and no line matches
    Then no-unverified-download-outside-build.sh says it measured nothing and fails
    # -> gates-have-teeth.sh "no-download-outside-build: the cosign exception matches nothing (measured nothing)"

  Scenario: a piped install fetches another file of this repository
    Given the files of this repository are one of the two named exceptions
    When a piped install fetches one more file beside compose.yaml
    Then no-unverified-download-outside-build.sh passes
    # -> gates-have-teeth.sh "no-download-outside-build: a piped install fetches another file of this repository (must pass)"

  Scenario: the build branch is reworded
    Given the build path fetches the tree as its first step
    When the text of the step is reworded
    Then no-unverified-download-outside-build.sh passes
    # -> gates-have-teeth.sh "no-download-outside-build: the build block fetches as before (must pass)"
