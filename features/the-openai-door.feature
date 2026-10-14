# @decided 2026-10-13 (paraphrased): an opt-in second gateway on this box serves the
# OpenAI wire on port 4110, in front of an OpenAI-compatible upstream the operator
# names, and carries every hardened setting the first gateway carries; the notifier
# and the identity plane read its stream as tokenfuse through a row each of them
# ships, so no stream declaration is set on the box; and the door takes a keys file
# and an identity map of its own rather than the gateway's, because a unit's month
# counter lives in one gateway process. @claude 2026-10-14: the shape in CLAUDE.md
# invariant 32. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name,
# and scripts/features-are-bound.sh holds the binding both ways.
Feature: an opt-in second door for agents that speak the OpenAI wire

  The gateway serves one wire, Anthropic's. An agent whose SDK speaks OpenAI's needs
  a second gateway in front of an upstream that speaks it. That door hands each
  caller's own provider key to the upstream, so it is never opened to callers it
  cannot name, it never starts on a box that did not ask for it, and it is held to
  everything the first gateway is held to.

  Scenario: a box that never asked for the door never runs it
    Given the door sits behind its own profile, which only OPENAI_DOOR=1 starts
    When compose.yaml drops the profile, or install.sh passes it on a line the door switch does not decide
    Then openai-door.sh fails, because the door would start on every box
    # -> gates-have-teeth.sh "openai-door: the door loses its profile"
    # -> gates-have-teeth.sh "openai-door: the door's profile is passed whatever DOOR_ON says"

  Scenario: the door is a gateway like the first in every hardened setting
    Given the door runs the gateway's own image and command, its settings written out in full
    When the door loses a hardened setting, weakens one, or takes its settings through a YAML anchor
    Then openai-door.sh fails and names the setting
    # -> gates-have-teeth.sh "openai-door: the door loses its policy plane fail mode"
    # -> gates-have-teeth.sh "openai-door: the door's policy plane runs in shadow"
    # -> gates-have-teeth.sh "openai-door: the door loses its admin key"
    # -> gates-have-teeth.sh "openai-door: the door's environment comes through a YAML anchor"

  Scenario: the door serves the OpenAI wire and carries no delegation or closure
    Given the door's whole reason is the OpenAI wire, and delegation and closure belong to the first gateway
    When the door serves the Anthropic wire, or sets a delegation variable
    Then openai-door.sh fails
    # -> gates-have-teeth.sh "openai-door: the door serves the Anthropic wire"
    # -> gates-have-teeth.sh "openai-door: the door carries delegation"

  Scenario: the door never opens without its own keys and map
    Given the door forwards each caller's provider key to the upstream
    When its upstream gets a default, or stops waiting for the keys and the map
    Then openai-door.sh fails, because a door started by hand would forward callers nobody named
    # -> gates-have-teeth.sh "openai-door: the door's upstream gets a default"
    # -> gates-have-teeth.sh "openai-door: the door's upstream no longer waits for its keys"

  Scenario: the door is on the operator's own bind
    Given the gateway's 4100 is published on GATEWAY_BIND, loopback unless the operator widens it
    When the door's port line names its own address
    Then openai-door.sh fails, because the door would be wider than the operator decided
    # -> gates-have-teeth.sh "openai-door: the door is published on every address"

  Scenario: the door keeps a stream, a data directory and a map of its own
    Given two gateways on one chained file fork the chain, and two in one data directory share one journal
    When the door writes the gateway's stream, keeps the gateway's data directory, or reads the gateway's map
    Then openai-door.sh fails
    # -> gates-have-teeth.sh "openai-door: the door writes the gateway's stream"
    # -> gates-have-teeth.sh "openai-door: the door shares the gateway's data directory"
    # -> gates-have-teeth.sh "openai-door: the door reads the gateway's map"

  Scenario: the door's stream is written, read and accepted
    Given the identity plane loads every gateway's file and the readers accept the door's as tokenfuse
    When the identity plane stops loading it, the door writes the gateway's file, nothing pre-creates it, or a reader is pinned before its row
    Then bus-has-a-writer.sh or bus-names-match-their-source.sh fails
    # -> gates-have-teeth.sh "bus-has-a-writer: idryx stops loading the OpenAI door's file"
    # -> gates-have-teeth.sh "bus-has-a-writer: the OpenAI door writes the gateway's file"
    # -> gates-have-teeth.sh "bus-has-a-writer: the OpenAI door's file is not pre-created"
    # -> gates-have-teeth.sh "bus-names: the idryx pin goes back before the OpenAI door's row"
    # -> gates-have-teeth.sh "bus-names: the heraldyx pin goes back before the OpenAI door's row"

  Scenario: the installer refuses the door without an upstream, keys and a map, before it installs anything
    Given OPENAI_DOOR=1 needs an upstream, a keys file and an identity map, given now or kept from an earlier run
    When install.sh accepts the door without one, or checks after a package is installed
    Then openai-door.sh fails, because the refusal has to come before the box is touched
    # -> gates-have-teeth.sh "openai-door: install.sh opens the door with no keys file"
    # -> gates-have-teeth.sh "openai-door: install.sh opens the door with no upstream"
    # -> gates-have-teeth.sh "openai-door: the door's refusals come after a package install"

  Scenario: the upstream is a full endpoint, and a refused one is never repeated
    Given an upstream may carry a credential somebody pasted by mistake
    When install.sh takes a base URL as the endpoint, or repeats the value it refuses
    Then openai-door.sh fails
    # -> gates-have-teeth.sh "openai-door: install.sh takes a base URL as the upstream"
    # -> gates-have-teeth.sh "openai-door: a refusal echoes the upstream"

  Scenario: two maps that share a unit are refused, and so are two that cannot be compared
    Given a unit's month counter lives in one gateway process
    When install.sh accepts a door map that declares a unit the gateway's map declares, or writes two maps it could not compare
    Then openai-door.sh fails, because that unit would get its cap once on each door
    # -> gates-have-teeth.sh "openai-door: two maps sharing a unit are accepted"
    # -> gates-have-teeth.sh "openai-door: two maps that cannot be compared are let through"

  Scenario: the door's files are read by the gateway image on the door's own wire, and the doors keep apart
    Given the identity block runs once for each door by name
    When the door's check starts on the other wire, switching doors loses one door's state, an unknown door is taken, a gateway is named by no door, or the door is handed the gateway's keys
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the OpenAI door's check runs on the Anthropic wire"
    # -> gates-have-teeth.sh "identity-files: an unknown door is taken quietly"
    # -> gates-have-teeth.sh "identity-files: switching doors loses the first door's state"
    # -> gates-have-teeth.sh "identity-files: a gateway that no door names"
    # -> gates-have-teeth.sh "identity-files: the door is handed the gateway's client keys"

  Scenario: every gate that reads a gateway's resolved settings reads the door's too
    Given the firewall, PII and run-budget gates read the resolved configuration with the door's profile on
    When the door moves to a profile that read does not enable
    Then each of those gates fails, rather than judging one gateway and calling it all of them
    # -> gates-have-teeth.sh "firewall-is-enforce: the resolved read misses the OpenAI door"
    # -> gates-have-teeth.sh "pii-is-shadow: the resolved read misses the OpenAI door"
    # -> gates-have-teeth.sh "run-budget-ceiling: the resolved read misses the OpenAI door"

  Scenario: off removes the door, a new map restarts it, and the running door is asked
    Given a profile's container survives an `up` that does not name the profile
    When install.sh stops removing the door when it is off, stops restarting it for a new map, or stops asking it for 401 in section 8
    Then openai-door.sh fails
    # -> gates-have-teeth.sh "openai-door: the door is left running when it is turned off"
    # -> gates-have-teeth.sh "openai-door: a new door map does not restart the door"
    # -> gates-have-teeth.sh "openai-door: section 8 stops asking the door for a key"

  Scenario: the end of the run says who pays
    Given a metered upstream bills whoever's key the caller sends
    When the closing report stops saying so
    Then openai-door.sh fails
    # -> gates-have-teeth.sh "openai-door: the closing report stops saying who pays"

  Scenario: the gate never reports OK on nothing
    Given the gate judges the door service and the installer block it finds
    When the door service or the block is gone
    Then openai-door.sh says it measured nothing, and does not report OK
    # -> gates-have-teeth.sh "openai-door: no door service left to judge"
    # -> gates-have-teeth.sh "openai-door: the installer block is gone"

  Scenario: a comment or a reworded refusal is not a fault
    Given reviewers write comments beside the settings and edit the wording of refusals
    When a comment names another form of the upstream, or a refusal is reworded
    Then openai-door.sh still passes
    # -> gates-have-teeth.sh "openai-door: a comment beside the door's upstream is not a setting"
    # -> gates-have-teeth.sh "openai-door: a reworded refusal still refuses"
