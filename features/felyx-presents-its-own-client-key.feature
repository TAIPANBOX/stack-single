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
