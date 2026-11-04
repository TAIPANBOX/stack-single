# @claude 2026-11-04, from the G2.1 entry of the estate gap list and the task that asked for the wiring:
# an agent's read of the web passes the MCP broker in front of scopyx, so the run is labelled from the act the broker saw and not from a tool name the agent
# reported (G2.1, tokenfuse invariant 143). The key that opens scopyx is in the broker's vault and
# never in the agent's hands. Each scenario is bound by name to a case in scripts/gates-have-teeth.sh,
# and scripts/features-are-bound.sh holds the binding both ways. The label a fetch earns on a running
# stack is held by tokenfuse's own suite (its invariant 143).
Feature: a read of the web passes the broker, which labels the run from the act

  Until tokenfuse 1.21.0 the web label of a run came from a tool name the agent chose, so a fetch
  under a name the policy trusted carried no label. From 1.21.0 the broker reports the act, but only
  if the read cannot go round it. So scopyx is on no network an agent is on, the key that opens it
  is one per agent in the broker's vault, scoped to that agent and to scopyx's two tools, and the
  broker's classification exists only where its taint gateway does.

  Scenario: the broker does not run under the egress profile
    Given a box runs scopyx under the egress profile and no typed plane
    When the broker is left out of the egress profile
    Then scopyx-reads-go-through-the-broker.sh fails, because an agent would have no way to reach scopyx
    # -> gates-have-teeth.sh "scopyx-broker: the broker leaves the egress profile"

  Scenario: the broker does not know scopyx
    Given the broker names its upstreams in TOKENFUSE_MCP_UPSTREAMS
    When scopyx is taken out of that list
    Then scopyx-reads-go-through-the-broker.sh fails and names the upstream address
    # -> gates-have-teeth.sh "scopyx-broker: the broker's upstream list loses scopyx"

  Scenario: a label is written where there is no taint gateway
    Given the broker exits 2 on a classification with no taint gateway, and a box with agent tokens off has none
    When the label is written into compose.yaml as a literal
    Then scopyx-reads-go-through-the-broker.sh fails, because the typed plane would be lost over a label it cannot use
    # -> gates-have-teeth.sh "scopyx-broker: the label is a literal, with or without a taint gateway"

  Scenario: the labels are not forgotten with the taint gateway
    Given install.sh writes the labels beside the taint gateway when agent tokens are on
    When agent tokens are turned off and the labels stay in .env
    Then scopyx-reads-go-through-the-broker.sh fails, because the broker would exit 2
    # -> gates-have-teeth.sh "scopyx-broker: the labels are not forgotten with the taint gateway"

  Scenario: the installer labels scopyx as something other than the web
    Given the label of scopyx's answers is the web
    When install.sh writes another label
    Then scopyx-reads-go-through-the-broker.sh fails and names the expected label
    # -> gates-have-teeth.sh "scopyx-broker: the installer labels scopyx as something else"

  Scenario: scopyx joins a network an agent is on
    Given an agent reaches scopyx only through the broker
    When scopyx is added to the agents network
    Then the key of scopyx can be used without the broker and the gate fails
    # -> gates-have-teeth.sh "scopyx-broker: scopyx joins the agents network"
    # -> gates-have-teeth.sh "network-membership: scopyx joins the agents network"

  Scenario: the browser goes back to the agents network
    Given the browser is reached by the broker on a network of the two of them
    When scopyx-browser is added to the agents network
    Then network-membership.sh fails, because a read through the browser would skip the broker
    # -> gates-have-teeth.sh "network-membership: scopyx-browser goes back to the agents network"

  Scenario: a third service joins the network between the broker and the browser
    Given browser-broker holds the broker and the browser and nothing else
    When another service is added to it
    Then network-membership.sh fails and names the members
    # -> gates-have-teeth.sh "network-membership: a third member joins the broker's network to the browser"

  Scenario: the network between the broker and the browser gains a route out
    Given browser-broker has no route out
    When it is declared without internal
    Then network-membership.sh fails
    # -> gates-have-teeth.sh "network-membership: browser-broker is not internal"

  Scenario: scopyx stops taking the key in the call
    Given the broker hands scopyx its key in params._meta
    When scopyx runs without SCOPYX_ACCEPT_KEY_IN_META
    Then scopyx-reads-go-through-the-broker.sh fails, because every call through the broker is refused
    # -> gates-have-teeth.sh "scopyx-broker: scopyx stops taking the key in the call"
    # -> gates-have-teeth.sh "scopyx-broker: the browser stops taking the key in the call"

  Scenario: egress is asked for with agent tokens off
    Given the broker labels a run through the gateway with its own client key, which exists only with agent tokens
    When WITH_EGRESS or WITH_BROWSER is given with WITH_AGENT_TOKENS=0
    Then install.sh refuses before it installs anything
    # -> gates-have-teeth.sh "scopyx-broker: egress with agent tokens off is allowed"

  Scenario: the key lands in scopyx and not in the vault
    Given one key per agent is in the broker's vault, in its scope rule and in scopyx's key list
    When the vault entry is not written
    Then scopyx-reads-go-through-the-broker.sh fails, because the agent has no handle to resolve
    # -> gates-have-teeth.sh "scopyx-broker: the key is written to scopyx and never to the vault"

  Scenario: the key can be resolved for another agent or another tool
    Given the scope rule of a key names its agent and scopyx's two tools
    When the rule loses the agent or loses the tools
    Then scopyx-reads-go-through-the-broker.sh fails, because the key could be used to fetch as someone else
    # -> gates-have-teeth.sh "scopyx-broker: the scope of the key loses the agent"
    # -> gates-have-teeth.sh "scopyx-broker: the scope of the key loses the tools"

  Scenario: scopyx cannot tell which agent fetched
    Given scopyx derives the agent from the key it is shown
    When its key list does not pair the key with the agent
    Then scopyx-reads-go-through-the-broker.sh fails
    # -> gates-have-teeth.sh "scopyx-broker: scopyx's list does not name the agent of the key"

  Scenario: a second run mints another key
    Given a box that already holds the key of its agent
    When install.sh runs again
    Then .env is byte for byte what it was
    # -> gates-have-teeth.sh "scopyx-broker: a second run mints a new key"
    # -> gates-have-teeth.sh "scopyx-broker: a second run writes the vault entry again"
    # -> gates-have-teeth.sh "scopyx-broker: a key already in the vault is replaced"

  Scenario: the trust domain changes between two runs
    Given the key of the agent is kept across runs
    When the agent's id changes with the trust domain
    Then the scope and the key list follow the new agent and no entry of the old one is left
    # -> gates-have-teeth.sh "scopyx-broker: a changed trust domain leaves the old scope entry"

  Scenario: the installer prints the key
    Given the key is a secret
    When the installer's note names it
    Then scopyx-reads-go-through-the-broker.sh fails
    # -> gates-have-teeth.sh "scopyx-broker: the block prints the key"

  Scenario: agent tokens are off and keys are written anyway
    Given the broker has no key for the gateway when agent tokens are off
    When the key block runs
    Then it writes nothing
    # -> gates-have-teeth.sh "scopyx-broker: agent tokens off, and the block still writes keys"

  Scenario: a vault key that is not a plain secret
    Given the vault holds an entry for the agent that is five characters long
    When install.sh runs
    Then it refuses and writes nothing
    # -> gates-have-teeth.sh "scopyx-broker: a short vault key is accepted"

  Scenario: a box that runs scopyx has no typed plane and turns typed off
    Given scopyx runs under the egress profile and the broker is shared with the typed profile
    When install.sh cleans up the profile that is off
    Then the broker is not removed and is started with the profile that needs it
    # -> gates-have-teeth.sh "profiles-off-are-removed: typed off removes the broker a running scopyx needs"
    # -> gates-have-teeth.sh "profiles-off-are-removed: a running scopyx does not bring the broker up"

  Scenario: the typed plane's broker alone does not keep the egress profile alive
    Given the broker runs for the typed plane and no egress service runs
    When typed is turned off
    Then the broker is removed
    # -> gates-have-teeth.sh "profiles-off-are-removed: the typed plane's broker makes egress live"
