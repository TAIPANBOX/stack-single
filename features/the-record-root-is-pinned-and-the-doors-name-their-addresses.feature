# Provenance: @claude 2026-11-05, from trailryx 1.5.0, tokenfuse 1.20.0 and the origin defect measured on forge 2026-10-25. Each scenario is bound to a teeth case by name.
Feature: The record seal pins custody's root at install, and each door names the addresses it is reached at

  Scenario: the record seal pins custody's one ES384 root kid at install
    Given keyryx serves the trailryx-root key set with one ES384 key
    When the installer runs with the record plane on
    Then it writes that kid to .env once and keeps it on a re-run, and it refuses a key set with no ES384 key, or with two
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: the install never pins the root"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: two ES384 keys are accepted"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: a re-run fetches the pin again"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: the key's body leaves the function"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: compose stops reading the pin"

  Scenario: each door accepts a proof for its own addresses, from the bind this box has, and wardryx takes the union
    Given an agent reaches a door at its service name, and a client on the host reaches it at the bind
    When the installer writes the origin lists
    Then the gateway and the broker each list their own two addresses and no other door's, and wardryx lists exactly the union
    # -> gates-have-teeth.sh "door-origins-are-named: the gateway names the broker's origin"
    # -> gates-have-teeth.sh "door-origins-are-named: the broker's list follows GATEWAY_BIND"
    # -> gates-have-teeth.sh "door-origins-are-named: wardryx misses the broker's bind"
    # -> gates-have-teeth.sh "door-origins-are-named: the gateway's origins do not reach it"
    # -> gates-have-teeth.sh "door-origins-are-named: the broker's proof door loses its list"
    # -> gates-have-teeth.sh "door-origins-are-named: compose bakes in a default address"
    # -> gates-have-teeth.sh "door-origins-are-named: agent tokens off leaves the lists"
