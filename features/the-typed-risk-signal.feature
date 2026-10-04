# @claude 2026-10-04, from the estate audit's launcher spec (wave 1), whose J2
# design records as decided that a typed risk signal may hold a tool call for a
# person and never deny it: this launcher offers it off by default, only with
# typed answers on and one more word from the operator, and points only the MCP
# broker at it. Scenarios are bound by name to cases in scripts/gates-have-teeth.sh.
Feature: a typed risk signal can hold a tool call, and only when the operator asked

  wardryx 1.2.0 reads a signal about a pending tool call and can hold it for a
  person. typryx 0.4.0 ships the proxy that adds the signal. The proxy cannot be
  given a credential by the one caller it has, so the network it sits on is its
  protection, and nothing here writes the policy that reads the signal.

  Scenario: nobody asked
    Given typed answers are on and TYPED_RISK_SIGNAL is not set
    When the installer resolves what to run
    Then no proxy is started and no TYPED_RISK_ line is written, whatever the typed mode
    # -> gates-have-teeth.sh "typed-risk-signal: the signal is on when nobody asked"

  Scenario: the flag with typed answers off
    Given there is no typryx to ask
    When TYPED_RISK_SIGNAL=1 is given with typed answers off
    Then the installer refuses before touching the box, naming WITH_TYPED=1 and TYPED_MODE
    # -> gates-have-teeth.sh "typed-risk-signal: the flag is accepted with typed answers off"

  Scenario: a value that is not a switch
    Given the flag is 1 or 0
    When it is anything else
    Then the installer refuses instead of believing it
    # -> gates-have-teeth.sh "typed-risk-signal: a value that is not a switch is believed"

  Scenario: the operator turns it off, or changes mode
    Given the signal is the operator's own choice, independent of the mode
    When TYPED_RISK_SIGNAL=0 is given, or the mode changes
    Then exactly its three .env lines go on 0 and stay on a mode change
    # -> gates-have-teeth.sh "typed-risk-signal: TYPED_RISK_SIGNAL=0 does not turn it off"
    # -> gates-have-teeth.sh "typed-risk-signal: switching mode drops the signal"

  Scenario: only the MCP broker is pointed at the proxy
    Given the LLM gateway keeps asking wardryx directly, for its 250 ms deadline
    When the broker is pointed past the proxy, or the gateway or another service is pointed at it
    Then typed-risk-signal.sh fails
    # -> gates-have-teeth.sh "typed-risk-signal: the broker is pointed past the proxy"
    # -> gates-have-teeth.sh "typed-risk-signal: the LLM gateway is pointed at the proxy"
    # -> gates-have-teeth.sh "typed-risk-signal: another service is pointed at the proxy"

  Scenario: the proxy leaves its own network
    Given the proxy runs without a credential and the network is what holds it
    When it joins the default network, publishes a port, is given a key, or a fourth service joins its network
    Then typed-risk-signal.sh fails, because every container on the box could spend the ask budget
    # -> gates-have-teeth.sh "typed-risk-signal: the proxy joins the default network"
    # -> gates-have-teeth.sh "typed-risk-signal: the proxy publishes a port"
    # -> gates-have-teeth.sh "typed-risk-signal: the proxy is given a key"
    # -> gates-have-teeth.sh "typed-risk-signal: a fourth service joins the proxy's network"

  Scenario: the broker's policy client is loose
    Given the broker fails closed and waits longer than the proxy's longest ask
    When it fails open, or its deadline is shorter than the proxy's ask
    Then typed-risk-signal.sh fails
    # -> gates-have-teeth.sh "typed-risk-signal: the broker fails open"
    # -> gates-have-teeth.sh "typed-risk-signal: the broker's decide deadline is shorter than the proxy's ask"

  Scenario: a policy that holds is shipped
    Given nothing holds a call until the operator writes the rule
    When the installer seeds a hold_if_signal policy, or the README stops showing one
    Then typed-risk-signal.sh fails
    # -> gates-have-teeth.sh "typed-risk-signal: a hold_if_signal policy is seeded"
    # -> gates-have-teeth.sh "typed-risk-signal: the README loses its example policy"

  Scenario: the pins that give the signal an effect move back
    Given the signal needs typryx 0.4.0, wardryx 1.2.0 and tokenfuse 1.5.0
    When any of the three is pinned older
    Then typed-risk-signal.sh fails, because an older pin adds no signal and says nothing
    # -> gates-have-teeth.sh "typed-risk-signal: typryx is pinned before the proxy existed"
    # -> gates-have-teeth.sh "typed-risk-signal: wardryx is pinned before it read signals"
    # -> gates-have-teeth.sh "typed-risk-signal: tokenfuse is pinned before it sent the tool call"

  Scenario: the profile is started without the operator asking
    Given install.sh passes the proxy's profile only when typed answers are on and the signal is
    When it passes it unconditionally
    Then typed-risk-signal.sh fails
    # -> gates-have-teeth.sh "typed-risk-signal: install.sh starts the proxy profile unconditionally"

  Scenario: nothing left to judge
    Given the proxy is found in the resolved configuration and the flag in the typed block
    When the proxy service, or the flag, is gone
    Then typed-risk-signal.sh says it measured nothing, never OK
    # -> gates-have-teeth.sh "typed-risk-signal: no proxy service left to judge"
    # -> gates-have-teeth.sh "typed-risk-signal: the typed-mode block never reads the flag"

  Scenario: a longer deadline is not this gate's business
    Given the gate judges the wiring, not the numbers above their floors
    When the broker's deadline is raised, or the proxy's default ask deadline moves
    Then typed-risk-signal.sh still passes
    # -> gates-have-teeth.sh "typed-risk-signal: the broker's deadline is raised"
    # -> gates-have-teeth.sh "typed-risk-signal: the proxy's ask deadline default moves"
