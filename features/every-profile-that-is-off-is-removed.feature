# @decided 2026-10-19 (paraphrased, the 1.4.0 wave, CLAUDE.md invariant 50, revised after the supervisor review of
# f39c64b): every compose profile is installer-managed or operator-started, and each kind has its own rule.
# Installer-managed profiles that a run turns off lose their containers. Operator-started profiles keep theirs,
# and a running one is re-upped at this run's pinned image. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh.
Feature: a profile that is off has no container left from an earlier install, and an operator's profile is never removed

  After the 1.1.35 to 1.3.1 upgrade on forge, the costcrew container of profile finops still ran image v0.6.0.
  The first fix removed every profile a run did not name, which also removed what the README tells an operator
  to start by hand. Each kind of profile now has its own rule.

  Scenario: an installer-managed profile this run turns off has its containers removed
    Given a compose file with installer-managed profiles, and a run that turns two of them off
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if a profile it turned off keeps a container
    # -> gates-have-teeth.sh "profiles-off-are-removed: the cleanup names the off profiles by hand and misses finops"

  Scenario: a profile this run names is never removed
    Given a service of a profile this run names
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if the cleanup removes it
    # -> gates-have-teeth.sh "profiles-off-are-removed: the cleanup removes the containers of a profile this run names, with no shared-service guard"

  Scenario: a running operator-started container is kept, not removed
    Given the FinOps console is running under profile finops, which this run does not name
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if the installer removes it
    # -> gates-have-teeth.sh "profiles-off-are-removed: a running operator-started container is removed, not kept"

  Scenario: a running operator-started container is started again at this run's pinned image
    Given the FinOps console is running on an image from an earlier release
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if the console is not started again at this run's pins
    # -> gates-have-teeth.sh "profiles-off-are-removed: a running operator-started container is not re-upped at this run's pins"

  Scenario: a profile that the two lists leave out is refused
    Given a profile in compose.yaml that install.sh does not list as installer-managed or operator-started
    When the gate reads the profile table
    Then profiles-off-are-removed.sh fails, so a new profile cannot fall through either rule
    # -> gates-have-teeth.sh "profiles-off-are-removed: a profile the two lists leave out is refused"

  Scenario: the record plane is removed when WITH_RECORD=0 turns it off
    Given a box whose record plane runs, and a run that names only the delegation profile
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if record-seal keeps running
    # -> gates-have-teeth.sh "profiles-off-are-removed: the record plane left out of the installer list keeps record-seal under WITH_RECORD=0"
