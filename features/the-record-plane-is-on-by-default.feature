# @decided 2026-10-19 (paraphrased, the 1.4.0 wave, CLAUDE.md invariant 51): the record plane is a core
# control, on by default from the pinned image, and WITH_RECORD=0 is the explicit way off. Each scenario is
# bound by name to a case in scripts/gates-have-teeth.sh.
Feature: the record plane runs unless the operator turns it off

  Before 1.4.0 an install without WITH_RECORD had no record plane, and WITH_RECORD=1 built trailryx from
  source. A core control should not depend on the operator knowing to ask for it.

  Scenario: an install that says nothing runs the record plane
    Given an install with no WITH_RECORD in its environment
    When the installer decides its profiles
    Then record-plane-is-on-by-default.sh fails if the record profile is not named
    # -> gates-have-teeth.sh "record-plane-is-on-by-default: an unset WITH_RECORD turns the record plane off again"

  Scenario: the up names the record profile, and WITH_RECORD builds nothing
    Given an install that names no profile of its own
    When the installer starts the stack
    Then record-plane-is-on-by-default.sh fails if the up never names the record profile, or if WITH_RECORD builds trailryx
    # -> gates-have-teeth.sh "record-plane-is-on-by-default: the up list never names the record profile"
    # -> gates-have-teeth.sh "record-plane-is-on-by-default: WITH_RECORD builds trailryx from source again"
