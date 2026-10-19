# @decided 2026-10-19 (paraphrased, the 1.4.0 wave): a re-run keeps exactly the static allow-list the
# last run wrote, and never adds a key the installer minted for the agents or the fire drills (CLAUDE.md
# invariant 53). Each scenario is bound by name to a case in scripts/gates-have-teeth.sh.
Feature: a re-run keeps the static allow-list it had and widens nothing

  On forge, the second run of the installer admitted the agents' and the fire drills' keys without a token,
  because the allow-list was built from every key the box held. The first run had named only felyx and
  the broker, by design.

  Scenario: a second run writes the list the first run wrote
    Given a box whose first run named felyx and broker and minted keys for agents and drills
    When the installer runs again on the same .env
    Then agent-tokens-are-wired.sh fails if the second run names agents or drills
    # -> gates-have-teeth.sh "agent-tokens-are-wired: a re-run widens the static list again (the minted agents and drills join it)"

  Scenario: a fresh box names felyx and broker, and not the agents key
    Given a fresh box, with no allow-list in .env
    When the installer writes the allow-list
    Then agent-tokens-are-wired.sh fails if the agents key is named by the first run
    # -> gates-have-teeth.sh "agent-tokens-are-wired: the agents key joins the list on the first run"
