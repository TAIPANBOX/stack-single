# @decided 2026-10-13 (paraphrased): the console gains an optional setting naming a gateway
# client key that Felyx, its copilot, sends as x-fuse-key (genaryx invariant 24); this
# launcher passes that setting through to the console, and the operator gives Felyx its own
# line in the keys file and, when a map is used, a binding whose agents include Felyx's
# agent id. @claude 2026-10-13: the setting is a reference, GENARYX_COPILOT_FUSE_KEY_REF,
# pointing at GENARYX_COPILOT_FUSE_KEY in .env, the same shape as the provider key's.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the console is handed Felyx's own gateway client key, read from .env

  With client keys on, the gateway refuses 401 every call that carries no key it holds,
  and Felyx's calls go through that same gateway. A console that reads
  GENARYX_COPILOT_FUSE_KEY_REF sends the key it points at as x-fuse-key. compose.yaml
  passes the reference and the key, the key read from .env and empty unless an operator
  gives one.

  Scenario: compose.yaml hands the console the reference to Felyx's key
    Given a console that reads GENARYX_COPILOT_FUSE_KEY_REF
    When compose.yaml stops passing it, or points it anywhere but GENARYX_COPILOT_FUSE_KEY
    Then felyx-through-the-gateway.sh fails, because Felyx would present no key of its own
    # -> gates-have-teeth.sh "felyx-through-the-gateway: Felyx's client key reference is dropped"

  Scenario: a box that gives Felyx no key runs exactly as before, and no key lives in git
    Given an operator who never sets GENARYX_COPILOT_FUSE_KEY in .env
    When compose.yaml writes a key in place of ${GENARYX_COPILOT_FUSE_KEY:-}, or makes it required
    Then felyx-through-the-gateway.sh fails without printing the value it found
    # -> gates-have-teeth.sh "felyx-through-the-gateway: Felyx's client key is written into compose.yaml"
    # -> gates-have-teeth.sh "felyx-through-the-gateway: Felyx's client key becomes required"

  Scenario: an operator who gave Felyx a key is told Felyx presents it
    Given client keys are on, GENARYX_COPILOT_KEY is set and GENARYX_COPILOT_FUSE_KEY holds a key
    When the closing report says Felyx sends no x-fuse-key, or that its calls are refused 401
    Then felyx-through-the-gateway.sh fails, because the report would contradict the box it describes
    # -> gates-have-teeth.sh "felyx-through-the-gateway: the closing report says Felyx sends no key though it has one"

  Scenario: an operator who gave Felyx no key is told its calls are refused, and how to give it one
    Given client keys are on, GENARYX_COPILOT_KEY is set and GENARYX_COPILOT_FUSE_KEY is empty
    When the closing report stops saying Felyx's calls are refused 401
    Then felyx-through-the-gateway.sh fails, because a refusal the operator was not told about is a Felyx that quietly does not answer
    # -> gates-have-teeth.sh "felyx-through-the-gateway: the closing report stops saying a keyless Felyx is refused"

  Scenario: the report never prints Felyx's key, and says nothing when there is nothing to refuse
    Given Felyx has a gateway key, or has no provider key and so makes no call
    When the closing report prints the key's value, or speaks of Felyx's calls with no provider key set
    Then felyx-through-the-gateway.sh fails
    # -> gates-have-teeth.sh "felyx-through-the-gateway: the closing report prints Felyx's key"
    # -> gates-have-teeth.sh "felyx-through-the-gateway: the closing report speaks of Felyx though it has no provider key"

  Scenario: the note about Felyx is part of the closing report
    Given an operator who reads the report at the end of a run
    When install.sh stops adding the note about Felyx to it
    Then felyx-through-the-gateway.sh fails, because the function would be text nobody reads
    # -> gates-have-teeth.sh "felyx-through-the-gateway: the closing report never calls the note"
