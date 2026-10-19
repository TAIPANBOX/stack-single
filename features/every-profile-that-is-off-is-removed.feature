# @decided 2026-10-19 (paraphrased, the 1.4.0 wave, CLAUDE.md invariant 50): a compose profile this run
# does not name is stopped and its containers removed, and a profile it names keeps its containers. Each
# scenario is bound by name to a case in scripts/gates-have-teeth.sh.
Feature: a profile that is off has no container left from an earlier install

  After the 1.1.35 to 1.3.1 upgrade on forge, the costcrew container of profile finops still ran image
  v0.6.0, because up --remove-orphans does not remove a container whose profile the run does not name.

  Scenario: every profile this run does not name has its containers removed
    Given a compose file with several profiles, and a run that names only two
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if a profile it does not name keeps a container
    # -> gates-have-teeth.sh "profiles-off-are-removed: the cleanup names the off profiles by hand and misses finops"

  Scenario: a profile this run names is never removed
    Given a service of a profile this run names
    When the installer cleans up after its up
    Then profiles-off-are-removed.sh fails if the cleanup removes it
    # -> gates-have-teeth.sh "profiles-off-are-removed: the cleanup removes the containers of a profile this run names, with no shared-service guard"
