# @decided 2026-10-13 (paraphrased): the launcher runs the gateway's agent firewall in
# enforce by default, shipped as its own change after a test stack, and an operator keeps
# one switch to run it in shadow or off. @claude 2026-10-13: tokenfuse ignores a mode it
# does not know and runs shadow, which refuses nothing, so the switch is validated and the
# default is held by a gate. Scenarios are bound to cases in scripts/gates-have-teeth.sh by
# name, and scripts/features-are-bound.sh holds the binding both ways.
Feature: the gateway runs its agent firewall in enforce, and one switch moves it

  The agent firewall judges what a run may do after it has read untrusted input.
  Shadow records what it would refuse and refuses nothing, so a box left on shadow
  looks protected and is not. Enforce is the default on every box. One installer
  variable, TOKENFUSE_FIREWALL, is the only way back, and a value tokenfuse would
  silently ignore is refused before anything is installed.

  Scenario: a box that sets nothing runs the firewall in enforce
    Given every gateway definition defaults TOKENFUSE_FIREWALL to enforce
    When compose.yaml stops setting it, or defaults it to shadow or off
    Then firewall-is-enforce.sh fails and names the gateway
    # -> gates-have-teeth.sh "firewall-is-enforce: the gateway loses its firewall setting"
    # -> gates-have-teeth.sh "firewall-is-enforce: the default becomes shadow"
    # -> gates-have-teeth.sh "firewall-is-enforce: the default becomes off"

  Scenario: the switch cannot be replaced by a literal or by another variable
    Given the one switch is TOKENFUSE_FIREWALL, set through install.sh or .env
    When compose.yaml writes a literal mode, or reads another variable
    Then firewall-is-enforce.sh fails, because the installer switch would do nothing
    # -> gates-have-teeth.sh "firewall-is-enforce: the setting becomes a literal"
    # -> gates-have-teeth.sh "firewall-is-enforce: the setting reads another variable"

  Scenario: a gateway service added later is judged as well
    Given the gateways are read from compose.yaml, not named in the gate
    When a second gateway service defaults to shadow
    Then firewall-is-enforce.sh fails and names that service
    # -> gates-have-teeth.sh "firewall-is-enforce: a second gateway start defaults to shadow"

  Scenario: the gate never reports OK on nothing
    Given the gate judges the gateway services it finds
    When the gateway's command no longer matches the shape it looks for
    Then firewall-is-enforce.sh says it measured nothing, and does not report OK
    # -> gates-have-teeth.sh "firewall-is-enforce: no gateway service left to judge"

  Scenario: the installer refuses a value tokenfuse would ignore
    Given tokenfuse runs its default on any value other than enforce, shadow or off
    When install.sh accepts any value, or keeps a bad one left in .env
    Then firewall-is-enforce.sh fails, because a misspelling would run shadow unnoticed
    # -> gates-have-teeth.sh "firewall-is-enforce: the installer accepts a value tokenfuse ignores"
    # -> gates-have-teeth.sh "firewall-is-enforce: a bad mode left in .env is accepted"

  Scenario: a later choice replaces the earlier one
    Given an operator may change the mode after a first install
    When install.sh appends a second line instead of replacing the first
    Then firewall-is-enforce.sh fails, because the gateway would read whichever line came first
    # -> gates-have-teeth.sh "firewall-is-enforce: the installer writes a second line instead of replacing"

  Scenario: the refusal does not repeat what it was given
    Given a refused value may be a secret pasted in the wrong place
    When install.sh names the value in its refusal
    Then firewall-is-enforce.sh fails
    # -> gates-have-teeth.sh "firewall-is-enforce: the refusal echoes the value"

  Scenario: the installer's half cannot go dead
    Given install.sh holds the validation and the write in one block
    When the block is renamed, or the write step is no longer called
    Then firewall-is-enforce.sh fails, because the installer's half is then dead text
    # -> gates-have-teeth.sh "firewall-is-enforce: the installer block is gone"
    # -> gates-have-teeth.sh "firewall-is-enforce: the installer never writes the mode"

  Scenario: a comment that names a mode is not the setting
    Given reviewers write comments about the switch next to the gateway's block
    When a comment inside that block names TOKENFUSE_FIREWALL and shadow
    Then firewall-is-enforce.sh still passes
    # -> gates-have-teeth.sh "firewall-is-enforce: a comment that names shadow is not the setting"
