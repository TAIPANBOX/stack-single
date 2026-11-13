# Written from the owner's decision of 2026-11-12, paraphrased: containers of another project on
# this box (a lab's gateway, an IdP bridge) stop sitting on the stack's core network beside the
# planes, reach only the services they need, and stop showing as failures in status for good.
# And of the same day, later, paraphrased: no door that holds keys or asks the policy plane shares a network
# with a guest, so a guest that takes a name cannot be handed a call meant for the stack; guests
# reach the doors through a proxy that holds no key, and are called back through another.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and
# scripts/features-are-bound.sh holds the binding both ways. CLAUDE.md invariant 77.
Feature: a guest of another project reaches the doors and nothing else

  The guests network holds guest-door and nothing else of the stack: a proxy that holds no key,
  answers there to the names vouchryx, the gateway and the MCP broker, and forwards only the
  routes an agent uses. A container of another project joins it by name, and the operator names
  it in guests.txt beside compose.yaml. A guest the stack calls back also joins the callbacks
  network, where guest-callback forwards a call from core to it, and the operator names it in
  guest-callbacks.txt. status calls a named guest on its network a note, and calls anything
  else on the stack's networks an unknown container.

  Scenario: no door shares a network with a guest
    Given the stack's compose file
    When the networks are read
    Then the guests network holds exactly guest-door, under the names vouchryx, the gateway and the MCP broker, and has no route out
    And the callbacks network holds exactly guest-callback, and has no route out
    And neither proxy is given an environment or mounts anything but its own configuration, read only
    # -> gates-have-teeth.sh "network-membership: wardryx joins the guests network"
    # -> gates-have-teeth.sh "network-membership: vouchryx joins the guests network again"
    # -> gates-have-teeth.sh "network-membership: guests is not internal"
    # -> gates-have-teeth.sh "network-membership: the broker joins the callbacks network"
    # -> gates-have-teeth.sh "network-membership: callbacks is not internal"
    # -> gates-have-teeth.sh "network-membership: guest-door loses the broker's name"
    # -> gates-have-teeth.sh "network-membership: guest-door is given an environment"
    # -> gates-have-teeth.sh "network-membership: guest-callback mounts the events volume"

  Scenario: guest-door forwards an agent's routes and answers the rest itself
    Given guest-door's configuration
    When it is read
    Then each port forwards to its own door only, on the routes an agent uses: a token, a key set, the server's metadata and a revocation from vouchryx, model calls from the gateway, tool calls from the broker
    And every other route, an administrative one of a door among them, is answered 404 by guest-door itself
    And a request that came back to guest-door is answered before anything is forwarded
    And guest-door runs as nobody, with no admin endpoint and no key in its configuration
    # -> gates-have-teeth.sh "guest-door-routes: the gateway's port gives a guest /v1/runs"
    # -> gates-have-teeth.sh "guest-door-routes: the broker's port matches by prefix"
    # -> gates-have-teeth.sh "guest-door-routes: vouchryx's port gives a guest the lift of a ban"
    # -> gates-have-teeth.sh "guest-door-routes: the gateway's port forwards to vouchryx"
    # -> gates-have-teeth.sh "guest-door-routes: the broker's port forwards every route"
    # -> gates-have-teeth.sh "guest-door-routes: a loop is forwarded before it is answered"
    # -> gates-have-teeth.sh "guest-door-routes: guest-door gets an admin endpoint"
    # -> gates-have-teeth.sh "guest-door-routes: guest-door sends a key from its environment"
    # -> gates-have-teeth.sh "guest-door-routes: guest-door runs as root"
    # -> gates-have-teeth.sh "guest-door-routes: a comment of guest-door/Caddyfile is reworded (must pass)"
    # -> gates-have-teeth.sh "guest-door-routes: guest-door/Caddyfile is gone"

  Scenario: a guest is called back only by a service on core
    Given a guest-callbacks.txt line naming a guest, a name and a port
    When the installer writes guest-callback's configuration
    Then guest-callback forwards that port to that name, for a caller on core's subnets and no other caller
    And a line for a container guests.txt does not name, a port below 1024 or above 65535, or a name or port another line has, stops the install before anything starts
    # -> gates-have-teeth.sh "guest-door-routes: a call back answers every caller"
    # -> gates-have-teeth.sh "guest-door-routes: a call back may take port 1023"
    # -> gates-have-teeth.sh "guest-door-routes: a call back may name a container guests.txt does not"
    # -> gates-have-teeth.sh "guest-door-routes: two lines may share a port"

  Scenario: a fresh box shows a guest reaching the doors through guest-door and nothing else
    Given a box the installer has just installed
    When a container on the guests network calls the stack by name
    Then the gateway and vouchryx answer through guest-door, an administrative route answers 404, and no plane, no database and no address outside answers
    And no door is attached to the guests network, so a name a guest takes there is never asked by a door
    # -> gates-have-teeth.sh "network-membership: install.yml loses the guests probe"
    # -> gates-have-teeth.sh "network-membership: install.yml loses the callbacks probe"

  Scenario: a guest named in guests.txt is a note on the guests network
    Given a container of another project on the guests network, named in guests.txt
    When the operator runs status
    Then its line is a note that names it a guest, and the run does not fail for it
    And a name in guests.txt with no container is shown, and does not fail
    # -> gates-have-teeth.sh "status-reads-what-runs: a name in guests.txt with no container is not shown"
    # -> gates-have-teeth.sh "status-reads-what-runs: the comment above the guest list is reworded (must pass)"

  Scenario: a container on the guests network that nobody named fails status
    Given a container of another project on the guests network, and guests.txt does not name it
    When the operator runs status
    Then its line says unknown container, and the run ends 1
    # -> gates-have-teeth.sh "status-reads-what-runs: any container on the guests network reads as a guest"

  Scenario: a named guest on core fails status
    Given a container guests.txt names, attached to the stack's core network
    When the operator runs status
    Then its line says unknown container on core and that guests.txt lets it onto the guests network only
    # -> gates-have-teeth.sh "status-reads-what-runs: a named guest on core reads as a guest"

  Scenario: a named guest that answers to a name of the stack's own fails status
    Given a container guests.txt names, on the guests network, that answers there to the name wardryx, to a provider's host the stack calls, or by its container name to a stack name
    When the operator runs status
    Then its line says it answers to a name of the stack's own, and the run ends 1
    And the name is compared as DNS compares it, without case and without a final dot, and a name that is no DNS name fails
    And a name it has only on another network is not held against it
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's names are compared with their case"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's name with a final dot passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's name with a space is read as words"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's container name is not held to the stack's"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest that answers to a name of the stack's own passes"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest's names on every network are held to the stack's"

  Scenario: a guests.txt that cannot be read lets nobody in
    Given a guests.txt that cannot be read, or a line in it that is not one container name
    When the operator runs status
    Then status says it could not measure, and every container of another project is an unknown container
    # -> gates-have-teeth.sh "status-reads-what-runs: a guests.txt line of two names is skipped"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guests.txt that cannot be read is no file"

  Scenario: a guest on the callbacks network is held to its line and to every other guest's name
    Given a guest on the callbacks network
    When the operator runs status
    Then it is a note when guest-callbacks.txt names it, and an unknown container when no line does
    And a guest called back that sits on core fails, saying where guests.txt and guest-callbacks.txt let it be
    And a guest that answers there to another guest's call-back name fails, the name compared without case
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest on the callbacks network needs no line of guest-callbacks.txt"
    # -> gates-have-teeth.sh "status-reads-what-runs: another guest's call-back name is not held"
    # -> gates-have-teeth.sh "status-reads-what-runs: call-back names are compared with their case"
    # -> gates-have-teeth.sh "status-reads-what-runs: a guest called back may sit on core"

  Scenario: guest-callback runs the configuration guest-callbacks.txt and core make
    Given a box whose guest-callbacks.txt was edited and not installed, or whose core now has another subnet
    When the operator runs status
    Then guest-callback fails, naming the run of the installer that would put it right
    # -> gates-have-teeth.sh "status-reads-what-runs: guest-callback's configuration is not compared"
    # -> gates-have-teeth.sh "status-reads-what-runs: guest-callback's configuration is read without core's subnets"
