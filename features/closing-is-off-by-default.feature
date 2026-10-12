# @decided 2026-10-11 (paraphrased, recorded in tokenfuse): a retained
# reservation is closed by a person after a passkey assertion in the console,
# which mints a short-lived token the gateway verifies; both are keyed by one
# shared secret. @claude 2026-10-12: on this box that secret is the operator's
# choice and is off by default. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name, and scripts/features-are-bound.sh holds
# the binding both ways.
Feature: closing a retained reservation is off by default

  A default install carries no closure secret, so the gateway's closure routes
  and the console's close command are both off. WITH_CLOSURE=1 turns it on with
  one secret, written so the gateway and the console hold the same bytes.

  Scenario: a default install would carry a closure setting
    Given compose.yaml hands the gateway TOKENFUSE_CLOSURE_SECRET and the console GENARYX_CLOSURE_SECRET_FILE
    When either value is a required form or a literal instead of an empty default
    Then closure-off-by-default.sh fails and names the variable
    # -> gates-have-teeth.sh "closure-off-by-default: the gateway's secret gets a required form"
    # -> gates-have-teeth.sh "closure-off-by-default: the console's file gets a literal"

  Scenario: the secret is minted without being asked for
    Given install.sh writes CLOSURE_SECRET into .env
    When that write is not inside a WITH_CLOSURE guard
    Then closure-off-by-default.sh fails and names the line
    # -> gates-have-teeth.sh "closure-off-by-default: install.sh mints the secret unconditionally"

  Scenario: the console's copy of the secret differs from the gateway's
    Given install.sh writes the secret to ./closure/secret for the console
    When it writes it with a trailing newline
    Then closure-off-by-default.sh fails, because the console trims the file and the gateway reads its variable as given
    # -> gates-have-teeth.sh "closure-off-by-default: the console's copy gets a trailing newline"

  Scenario: the secret reaches a printed line
    Given install.sh holds the secret in a shell variable
    When a line other than its length check and its write to the file expands it
    Then closure-off-by-default.sh fails and names the line
    # -> gates-have-teeth.sh "closure-off-by-default: the secret is printed"

  Scenario: a comment near the closure block is reworded
    Given the closure block in install.sh
    When only a comment changes
    Then closure-off-by-default.sh still passes
    # -> gates-have-teeth.sh "closure-off-by-default: a comment near it is reworded"

  Scenario: the gate has nothing to judge
    Given compose.yaml with no closure variable on the console
    When closure-off-by-default.sh runs
    Then it fails and says it measured nothing
    # -> gates-have-teeth.sh "closure-off-by-default: no console variable left to judge"
