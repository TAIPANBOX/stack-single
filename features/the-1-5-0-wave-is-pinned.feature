# Provenance: @claude 2026-10-20, from the W-PINS-NEXT brief (trailryx 1.5.0, keyryx 0.1.2, tokenfuse 1.20.0, genaryx-console 1.6.0). Each scenario is bound to a teeth case by name.
Feature: The 1.5.0 wave runs its released pins, and the record seal pins custody's root at install

  Scenario: the record seal pins custody's one ES384 root kid at install
    Given keyryx serves the trailryx-root key set with one ES384 key
    When the installer runs with the record plane on
    Then it writes that kid to .env once and keeps it on a re-run, and it refuses a key set with no ES384 key, or with two
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: the install never pins the root"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: two ES384 keys are accepted"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: a re-run fetches the pin again"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: the key's body leaves the function"
    # -> gates-have-teeth.sh "trailryx-root-is-pinned: compose stops reading the pin"

  Scenario: the stack runs the released digests, and the gateway and the broker name their origins
    Given the 1.5.0 wave is released as keyryx 0.1.2, trailryx-node 1.5.0, tokenfuse 1.20.0 and genaryx-console 1.6.0
    When the stack is rendered with the typed profile
    Then every pin is the released digest, and the gateway and the broker name each address they are reached at
    # -> gates-have-teeth.sh "wave3-pins-are-released: keyryx is back on v0.1.1"
    # -> gates-have-teeth.sh "wave3-pins-are-released: components.json keeps the old console"
    # -> gates-have-teeth.sh "wave3-pins-are-released: the gateway loses its service-name origin"
    # -> gates-have-teeth.sh "wave3-pins-are-released: the broker's proof origins are dropped"
