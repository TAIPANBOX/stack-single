# @decided 2026-10-17 (paraphrased): close the agent-security findings of the
# 2026-10-17 review, starting with the defaults; here, the gateway on every box
# authenticates its callers and binds each key to the agent ids it may speak as,
# with keys the installer mints itself when the operator gives none. Each scenario
# is bound by name to a case in scripts/gates-have-teeth.sh, and
# scripts/features-are-bound.sh holds the binding both ways.
Feature: the metered doors need a key, and the installer mints one when nobody gave it any

  The gateway is the door every metered call goes through. Without client keys it
  answers anyone who can reach it, and the agent id on a call is whatever the caller
  wrote, so one agent can speak as another and its spend and its policy follow the
  name it chose. So the gateway refuses to start without keys, its identity map is
  strict, and an install that was given no keys file mints one key for the console's
  copilot and one for the operator's agents, each bound to its own agent ids.

  Scenario: the gateway's client keys get an empty default
    Given compose.yaml requires GATEWAY_CLIENT_KEYS for the gateway
    When the requirement becomes an empty default
    Then metered-doors-require-keys.sh fails, because a box whose .env lacks keys would answer anyone
    # -> gates-have-teeth.sh "metered-doors-require-keys: the gateway's client keys get an empty default"

  Scenario: the gateway stops reading client keys at all
    Given the gateway reads TOKENFUSE_CLIENT_KEYS
    When compose.yaml stops setting it
    Then metered-doors-require-keys.sh fails and names the gateway
    # -> gates-have-teeth.sh "metered-doors-require-keys: TOKENFUSE_CLIENT_KEYS goes missing"

  Scenario: the identity map stops being strict
    Given every gateway sets TOKENFUSE_IDENTITY_STRICT to enforce
    When one of them sets warn instead
    Then metered-doors-require-keys.sh fails, because a key speaking as another agent would only be noted
    # -> gates-have-teeth.sh "metered-doors-require-keys: a gateway's identity map is only warned about"

  Scenario: an install that was given no files gets keys anyway
    Given a box with no keys file, no map and nothing in .env
    When the installer stops minting the agents' key
    Then metered-doors-require-keys.sh fails, because the gateway would start with nothing for agents to present
    # -> gates-have-teeth.sh "metered-doors-require-keys: the installer stops minting the agents' key"

  Scenario: a re-run never rewrites a minted key
    Given a box whose keys the installer minted on its first run
    When a re-run mints a new secret over the one in .env
    Then metered-doors-require-keys.sh fails, because every agent holding the old key would be refused
    # -> gates-have-teeth.sh "metered-doors-require-keys: a re-run mints a new secret over the kept one"

  Scenario: the operator's own keys are left alone
    Given a box whose .env holds keys the operator gave in a keys file
    When the installer mints keys over them
    Then metered-doors-require-keys.sh fails, because the operator's agents would be refused
    # -> gates-have-teeth.sh "metered-doors-require-keys: a box with the operator's own keys gets minted keys"

  Scenario: the agents' key cannot speak as the console's copilot
    Given the identity map binds the agents' key to the agents namespace
    When it is bound to every id in the trust domain
    Then metered-doors-require-keys.sh fails, because an agent could present the copilot's id
    # -> gates-have-teeth.sh "metered-doors-require-keys: the agents' key may speak as Felyx"

  Scenario: the agents' key file is the operator's alone
    Given the installer writes the agents' key to a file for the operator
    When that file is left readable by other accounts
    Then metered-doors-require-keys.sh fails, naming the file's mode
    # -> gates-have-teeth.sh "metered-doors-require-keys: the agent key file is readable by others"

  Scenario: the closing report names the file, never the key
    Given the closing report tells the operator where the agents' key is
    When it prints the key itself
    Then metered-doors-require-keys.sh fails, because a terminal log is not a place for a secret
    # -> gates-have-teeth.sh "metered-doors-require-keys: the closing report prints the agents' key"

  Scenario: the closing report says agents now need the key
    Given the closing report tells the operator where the agents' key is
    When it stops naming the file
    Then metered-doors-require-keys.sh fails, because an operator would learn of the change from refused calls
    # -> gates-have-teeth.sh "metered-doors-require-keys: the closing report stops naming the agents' key file"

  Scenario: a map with no keys is refused on a box that has none
    Given a box with no client keys
    When the operator gives an identity map and no keys file
    Then the installer refuses before anything is installed, and metered-doors-require-keys.sh holds that refusal
    # -> gates-have-teeth.sh "metered-doors-require-keys: a map without keys is accepted"

  Scenario: the minted pair is one the gateway itself accepts
    Given the installer minted two keys and a map
    When the pinned gateway image reads them before anything restarts
    Then it holds two keys and the map, and a map naming a key id the installer never minted is refused
    # -> gates-have-teeth.sh "metered-doors-require-keys: the minted map binds a key id nobody minted"

  Scenario: a comment is reworded
    Given the gate passes on this tree
    When a comment in the gateway's block is reworded
    Then metered-doors-require-keys.sh still passes
    # -> gates-have-teeth.sh "metered-doors-require-keys: a comment beside the client keys is reworded"

  Scenario: there is nothing to judge
    Given the gate derives the gateways from compose.yaml's image and command lines
    When no service runs the gateway any more
    Then metered-doors-require-keys.sh says it measured nothing and fails
    # -> gates-have-teeth.sh "metered-doors-require-keys: no gateway is left to judge"
    # -> gates-have-teeth.sh "metered-doors-require-keys: the installer's mint block is gone"
