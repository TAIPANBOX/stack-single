# @decided 2026-11-11 (paraphrased): the MCP broker's tool-call check is closed when the gateway gives no answer, so a
# tool call nothing judged is refused instead of passed. @claude 2026-11-11: the shape on this box (the failmode as a
# literal, every static key the broker admits also a gateway key of the same id and secret, bound to the one agent it
# speaks as, written by the installer for the keys it mints and checked for a box with its own keys file) is my reading
# of what that takes here. Each scenario is bound by name to a case in scripts/gates-have-teeth.sh, and
# scripts/features-are-bound.sh holds the binding both ways. The closed check and the stopped gateway on a real box are
# CI's typed-risk install leg (.github/workflows/install.yml).
Feature: the broker's tool-call check fails closed, for every caller it admits

  Before every tool call the broker asks the gateway whether the run may use the tool. A caller with a static key is
  asked with its own key, and the gateway answers only a key it holds. A broker that reads "no answer" as "allowed"
  forwarded the call with nothing judging it. The broker now refuses it, so each static key the broker admits has to be
  a key the gateway holds, or that caller would be refused every time.

  Scenario: the failmode is a word nobody can switch
    Given the broker reads TOKENFUSE_MCP_TAINT_FAILMODE and treats only the word closed as closed
    When compose.yaml leaves the setting out, so tokenfuse reads open
    Then broker-callers-are-gateway-keys.sh fails, because the broker would forward a call nothing judged
    # -> gates-have-teeth.sh "broker-callers: the closed word is taken out"

  Scenario: the failmode is set to open
    Given the broker is meant to refuse a call the gateway cannot answer
    When compose.yaml sets the failmode to open
    Then broker-callers-are-gateway-keys.sh fails and says the literal closed is what it wants
    # -> gates-have-teeth.sh "broker-callers: the failmode reads open"

  Scenario: an operator switch is not a literal
    Given the setting is written out as a literal on purpose, with no switch to turn it open by accident
    When compose.yaml reads it from a variable that defaults to closed
    Then broker-callers-are-gateway-keys.sh fails
    # -> gates-have-teeth.sh "broker-callers: the failmode becomes an operator switch"

  Scenario: a key only the broker holds
    Given the installer's own check calls the broker with the key stack-single, and the gateway answers only keys it holds
    When the installer writes the key to the broker and not to the gateway
    Then broker-callers-are-gateway-keys.sh fails and says the gateway holds no key of that id
    # -> gates-have-teeth.sh "broker-callers: the broker admits a key only it holds"

  Scenario: a key the map does not bind
    Given the gateway runs its identity map strict, and refuses a key the map does not bind
    When the minted map binds none of the broker's callers
    Then broker-callers-are-gateway-keys.sh fails and names the missing binding
    # -> gates-have-teeth.sh "broker-callers: the map binds none of the broker's callers"

  Scenario: a key the gateway's list leaves out
    Given under require the gateway answers a static key only when its static list names it
    When the installer leaves the broker's callers off the gateway's list
    Then broker-callers-are-gateway-keys.sh fails, because the check would be refused 401 and the call blocked
    # -> gates-have-teeth.sh "broker-callers: the gateway's static list leaves them out"

  Scenario: the installer's check key speaks as the operator's agents
    Given the installer's key is bound to the one id its own check names, agent://local.invalid/install-check
    When the minted map lets it speak as the operator's agents
    Then broker-callers-are-gateway-keys.sh fails, because a key held for one check must not reach further
    # -> gates-have-teeth.sh "broker-callers: the installer's check key may speak as the operator's agents"

  Scenario: the two doors hold one secret
    Given the broker asks the gateway with the caller's own key, so a different secret is a key the gateway does not know
    When the gateway's copy of a key has another secret than the broker's
    Then broker-callers-are-gateway-keys.sh fails
    # -> gates-have-teeth.sh "broker-callers: the gateway's key has another secret than the broker's"

  Scenario: a broker key nobody minted
    Given a minted box cannot say which agents a key of someone else's may speak as
    When the broker lists a static key the installer did not mint and the run goes on
    Then broker-callers-are-gateway-keys.sh fails, and the installer's own run stops naming the id
    # -> gates-have-teeth.sh "broker-callers: a broker key nobody minted is listed with no gateway key"

  Scenario: a box with its own keys file is checked, not rewritten
    Given the installer never edits a keys file it did not write, except when told ADD_BROKER_KEY=1
    When the order of the installer no longer checks the box's own keys file for the broker's callers
    Then broker-callers-are-gateway-keys.sh fails, because the closed check would refuse their calls
    # -> gates-have-teeth.sh "broker-callers: a box's own keys file is never checked"

  Scenario: the callers' lines reach the checks the map is held to
    Given ADD_BROKER_KEY=1 appends the callers' lines to the operator's file
    When the lines are appended but never reach the keys the gateway image checks against the map
    Then broker-key-is-the-keys-file-line.sh fails
    # -> gates-have-teeth.sh "broker-key-line: the callers lines are appended but never reach the checks"

  Scenario: a map that binds none of the callers
    Given the operator's identity map is theirs, and the installer cannot bind a key in it
    When the map names no binding for a caller the broker admits
    Then broker-key-is-the-keys-file-line.sh fails, because the run would append to the file and then be refused
    # -> gates-have-teeth.sh "broker-key-line: a map that binds none of the callers is not noticed"

  Scenario: a line with another secret
    Given the broker's secret and the operator's line must be one secret
    When the operator's line for a caller holds another secret and the run goes on
    Then broker-key-is-the-keys-file-line.sh fails, because neither side may be rewritten under whoever holds it
    # -> gates-have-teeth.sh "broker-key-line: a callers line with another secret is accepted"

  Scenario: status reads the callers
    Given status says what runs and what the box holds
    When status stops reading whether the gateway holds each key the broker admits
    Then broker-callers-are-gateway-keys.sh fails
    # -> gates-have-teeth.sh "broker-callers: status stops reading the callers"
