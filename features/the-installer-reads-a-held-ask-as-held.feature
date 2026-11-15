# @claude 2026-11-15, from a forge install (it records no decision of the owner): with the typed risk signal on, a
# classifier that misses its deadline gets the installer's own ask held for a person, and the check read that as a
# failure of the box. Each scenario is bound by name to a case in scripts/gates-have-teeth.sh, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the installer reads its own held ask as held, asks again a bounded number of times, and fails at once on anything else

  The installer proves the typed plane by sending one ask through the MCP broker. With the typed risk signal on,
  a call that arrives without a signal is held for a person, which is the secure answer and stays. A slow first
  call to a hosted classifier is not a broken box, so the check asks the same call again before it says FAIL.

  Scenario: a held ask is asked again
    Given the classifier missed its deadline and the ask came back held
    When the check is changed to read a held answer as a failure at once
    Then broker-ask-retries-a-held-call.sh fails
    # -> gates-have-teeth.sh "broker-ask-retries: a held ask is not asked again"

  Scenario: the retry has a bound
    Given a classifier that stays down holds every ask
    When the check is allowed to ask many more times
    Then broker-ask-retries-a-held-call.sh fails, because a run must still end in a FAIL within seconds
    # -> gates-have-teeth.sh "broker-ask-retries: the retry is unbounded"

  Scenario: a real fault is not retried
    Given typryx answered with an error that is not a hold
    When the check is changed to ask again on any error
    Then broker-ask-retries-a-held-call.sh fails
    # -> gates-have-teeth.sh "broker-ask-retries: an error that is not a hold is asked again"

  Scenario: the check is gone
    Given the gate reads the check between its markers
    When the markers are gone
    Then broker-ask-retries-a-held-call.sh says it measured nothing and fails
    # -> gates-have-teeth.sh "broker-ask-retries: the block is gone (measured nothing)"

  Scenario: a different pause is not a fault
    Given the pause between tries is a choice
    When it is changed
    Then broker-ask-retries-a-held-call.sh passes
    # -> gates-have-teeth.sh "broker-ask-retries: a longer pause between tries (must pass)"
