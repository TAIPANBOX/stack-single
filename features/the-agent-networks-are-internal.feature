# @decided 2026-10-18 (paraphrased, wave 1 of the 2026-10-17 agent-security review, design decision D6 a):
# an agent has no route out of the box except through the doors (the gateways and
# the MCP broker) and scopyx; the planes are not reachable from an agent's network;
# only the services that need the internet are on the one network with a route out;
# the host firewall is not touched. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh, and scripts/features-are-bound.sh holds the binding
# both ways. The live half, a container on the agents network that cannot reach the
# internet but reaches the gateway, is the install workflow's own step.
Feature: an agent has no route out of the box except through the doors

  Every container used to share one network with a route to the internet, so an
  agent that could reach a model provider directly never needed the metered
  gateway. Topology closes that: agent-facing services sit on an internal network
  whose only members are the doors and scopyx, and the services that need the
  internet sit on the one network with a route out. The table in
  scripts/network-membership.sh is the spec, and this gate holds the compose file to it.

  Scenario: a plane service joins the agents network
    Given the table gives the agents network only the gateways, the MCP broker, scopyx and the console
    When idryx is added to the agents network
    Then network-membership.sh fails and names the plane that agents can now reach
    # -> gates-have-teeth.sh "network-membership: idryx joins the agents network"

  Scenario: the browser joins a plane network
    Given scopyx-browser renders pages from the web and must not reach a plane
    When scopyx-browser is added to core
    Then network-membership.sh fails, because a renderer exploit would reach the planes
    # -> gates-have-teeth.sh "network-membership: the browser joins core"

  Scenario: a service that does not need the internet joins edge
    Given only heraldyx, scopyx, the gateways, wg, caddy and the browser need a route out
    When the console is added to edge
    Then network-membership.sh fails and names the console
    # -> gates-have-teeth.sh "network-membership: the console joins edge"

  Scenario: the agents network loses its internal flag
    Given the agents network has no route out
    When the agents network is declared without internal
    Then network-membership.sh fails, because agents would reach the internet
    # -> gates-have-teeth.sh "network-membership: agents is not internal"

  Scenario: the risk-signal network loses its internal flag
    Given the risk-signal network holds the typed risk signal's proxy, the broker and wardryx
    When risk-signal is declared without internal
    Then network-membership.sh fails, because the proxy would be reachable from outside
    # -> gates-have-teeth.sh "network-membership: risk-signal is not internal"

  Scenario: the front network starts to masquerade
    Given front exists so that published ports reach the host without a route out
    When front is declared with masquerade on
    Then network-membership.sh fails, because a container there could use the host as a route out
    # -> gates-have-teeth.sh "network-membership: front masquerades"

  Scenario: a service lands on the default network
    Given every service names its networks and default has a route out
    When wg is put on the default network
    Then network-membership.sh fails and says the service has a route out
    # -> gates-have-teeth.sh "network-membership: wg is on the default network"

  Scenario: a new service is not in the table
    Given a service's networks are decided in the table before it is started
    When a service the table does not name is added to compose.yaml
    Then network-membership.sh fails, because its networks would be unclassified
    # -> gates-have-teeth.sh "network-membership: a service the table does not name"

  Scenario: the typed backend has no route out under the stub
    Given the typed backend joins edge only when its mode needs a provider
    When typryx joins edge under the stub mode
    Then network-membership.sh fails, because a box with no provider would have a route out
    # -> gates-have-teeth.sh "network-membership: typryx gets edge under the stub"

  Scenario: the browser keeps the name scopyx for the agents
    Given agents reach the browser under the name scopyx, as they reach scopyx
    When the alias is removed from the browser's agents network
    Then network-membership.sh fails, because the agents would no longer find it
    # -> gates-have-teeth.sh "network-membership: scopyx-browser loses its agents alias"

  Scenario: the install workflow loses its agents probe
    Given a fresh runner proves the agents network once per install leg
    When the agents probe is removed from install.yml
    Then network-membership.sh fails, because nothing would test the claim on a live engine
    # -> gates-have-teeth.sh "network-membership: install.yml loses the agents probe"

  Scenario: an install check still probes the default network
    Given install.sh probes the planes from agent-stack_core
    When one probe is pointed back at agent-stack_default
    Then network-membership.sh fails, because that network no longer exists as the box's default
    # -> gates-have-teeth.sh "network-membership: install.sh probes the default network"

  Scenario: a reworded comment is not a fault
    Given the gate judges networks, not prose
    When a comment on the browser's networks is reworded
    Then network-membership.sh still passes
    # -> gates-have-teeth.sh "network-membership: a reworded comment is not a fault"

  Scenario: no services resolve, so the gate says so
    Given a gate that passes on nothing is worse than no gate
    When the compose file names no services
    Then network-membership.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "network-membership: no services resolve, so nothing was measured"

  Scenario: a third service joins the browser's policy network
    Given the browser's policy network holds scopyx-browser and wardryx, and nothing else
    When idryx is added to the browser's policy network
    Then network-membership.sh fails, because the browser would reach a plane there
    # -> gates-have-teeth.sh "network-membership: a third member joins the browser's network"

  Scenario: the browser's policy network loses wardryx
    Given the browser must reach wardryx to decide each fetch it makes
    When wardryx is taken off the browser's policy network
    Then network-membership.sh fails, because the browser could no longer be decided
    # -> gates-have-teeth.sh "network-membership: the browser's network loses wardryx"

  Scenario: the browser's policy network has no route out
    Given the browser's policy network carries decisions only
    When browser-policy is declared without internal
    Then network-membership.sh fails, because a route out would reach the internet from there
    # -> gates-have-teeth.sh "network-membership: browser-policy is not internal"
